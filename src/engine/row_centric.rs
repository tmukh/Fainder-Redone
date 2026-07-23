use crate::index::FainderIndex;
#[cfg(not(feature = "aos"))]
use crate::index::SubIndex;
use rayon::prelude::*;
use super::types::{Comparison, IndexMode, TypedQuery};
#[cfg(not(any(feature = "aos", feature = "f16", feature = "pgm")))]
use super::search::{do_partition_lt, do_partition_le};
#[cfg(all(feature = "f16", not(feature = "aos")))]
use super::search::{f16_partition_lt, f16_partition_le};

#[cfg(not(feature = "aos"))]
#[inline]
fn ids_to_vec(sub: &SubIndex, bin_idx: usize, n_hists: usize, start: usize, end: usize) -> Vec<u32> {
    let mut v = Vec::with_capacity(end - start);
    sub.extend_ids(&mut v, bin_idx, n_hists, start, end);
    v
}

// ── Row-centric engine (original): par_iter over queries, serial cluster loop.
// Access pattern: each query sweeps all clusters independently — no column reuse.
//
// Output strategy:
//   default:           per-cluster `Vec<u32>` allocations + outer flat_map+collect
//                      (perf reveals ~30% of cycles in FlatMap::next + 7% in
//                       Vec::from_iter for this pattern at eval_medium t=1)
//   --features pooled: single pre-allocated Vec<u32> per query, extend_from_slice
//                      directly from column ID slices. Avoids 57 small heap
//                      allocations and the outer Vec::from_iter
pub(super) fn execute_row_centric(
    typed_queries: &[TypedQuery],
    index: &FainderIndex,
    index_mode: IndexMode,
    is_conversion: bool,
    pool: &rayon::ThreadPool,
) -> Vec<Vec<u32>> {
    let n_clusters = index.n_clusters();

    pool.install(|| {
        typed_queries.par_iter().map(|q| {
            let (eff_percentile, is_gt) = match q.comparison {
                Comparison::Gt | Comparison::Ge => (1.0 - q.percentile, true),
                _ => (q.percentile, false),
            };
            let condition = (is_gt && index_mode == IndexMode::Precision)
                         || (!is_gt && index_mode == IndexMode::Recall);
            let bin_mode  = if condition && !is_conversion { 1 } else { 0 };
            let pctl_mode = if condition &&  is_conversion { 1 } else { 0 };
            let ref_val   = q.reference;
            let target    = eff_percentile;

            // ── Pooled output path: build one Vec<u32> per query directly ─────
            #[cfg(all(feature = "pooled", not(feature = "cluster-par")))]
            {
                // Capacity heuristic: start small, let amortised-doubling grow as
                // needed. Over-allocating to (n_clusters * 1024) caused 13% regression
                // at t=32 due to LLC pressure from per-thread speculative buffers.
                // Empirically, starting at 4 KiB worth of u32s amortises growth cost
                // for typical queries without dominating L3 capacity at high t.
                let mut out: Vec<u32> = Vec::with_capacity(1024);

                // --features cluster-prefetch: software-pipelined prefetch of
                // cluster c+LOOKAHEAD's bin-edges and column-base while we are
                // processing cluster c. The 57-cluster outer loop has no
                // hardware-prefetcher-friendly stride between clusters, so the
                // L2/L3 fill latency on the cluster-transition shows up in
                // perf as missed lines on the first access. AMAC-style group
                // prefetching (Kocberber et al. 2015) hides this latency.
                #[cfg(feature = "cluster-prefetch")]
                const LOOKAHEAD: usize = 1;

                for c in 0..n_clusters {
                    #[cfg(all(feature = "cluster-prefetch", target_arch = "x86_64"))]
                    {
                        let next_c = c + LOOKAHEAD;
                        if next_c < n_clusters {
                            let next_bins = index.get_bins(next_c);
                            unsafe {
                                std::arch::x86_64::_mm_prefetch(
                                    next_bins.as_ptr() as *const i8,
                                    std::arch::x86_64::_MM_HINT_T0,
                                );
                            }
                            if let Some(next_sub) = index.get_subindex(next_c, pctl_mode) {
                                if !next_sub.values.is_empty() {
                                    unsafe {
                                        std::arch::x86_64::_mm_prefetch(
                                            next_sub.values.as_ptr() as *const i8,
                                            std::arch::x86_64::_MM_HINT_T0,
                                        );
                                        // Also prefetch the indices base — it is on the
                                        // critical path for the trivially-all and the
                                        // post-search ID emit in this same iteration.
                                        #[cfg(not(any(feature = "packed-ids", feature = "local-ids", feature = "local-ids-bench", feature = "local-ids-noalloc")))]
                                        std::arch::x86_64::_mm_prefetch(
                                            next_sub.indices.as_ptr() as *const i8,
                                            std::arch::x86_64::_MM_HINT_T0,
                                        );
                                        #[cfg(any(feature = "packed-ids", feature = "local-ids", feature = "local-ids-bench", feature = "local-ids-noalloc"))]
                                        std::arch::x86_64::_mm_prefetch(
                                            next_sub.packed_ids.as_ptr() as *const i8,
                                            std::arch::x86_64::_MM_HINT_T0,
                                        );
                                    }
                                }
                            }
                        }
                    }

                    let bins = index.get_bins(c);
                    if bins.len() < 2 { continue; }

                    if ref_val < bins[0] || ref_val > bins[bins.len() - 1] {
                        let trivially_all = (ref_val < bins[0] && is_gt)
                                         || (ref_val > bins[bins.len() - 1] && !is_gt);
                        if !trivially_all { continue; }
                        let sub = match index.get_subindex(c, pctl_mode) { Some(s) => s, None => continue };
                        let n_hists = index.get_cluster_size(c);
                        if n_hists > sub.len() { continue; }
                        #[cfg(not(feature = "aos"))]
                        sub.extend_ids(&mut out, 0, n_hists, 0, n_hists);
                        #[cfg(feature = "aos")]
                        out.extend(sub.entries[..n_hists].iter().map(|e| e.1));
                        continue;
                    }

                    let pp      = bins.partition_point(|&x| x < ref_val);
                    let raw_idx = if pp == 0 { 0 } else { pp - 1 };
                    let bin_idx = (raw_idx + bin_mode).min(bins.len() - 1);

                    let sub = match index.get_subindex(c, pctl_mode) { Some(s) => s, None => continue };
                    let n_hists    = index.get_cluster_size(c);
                    let idx_offset = bin_idx * sub.stride();
                    if idx_offset + n_hists > sub.len() { continue; }

                    #[cfg(not(any(feature = "aos", feature = "f16")))]
                    {
                        let col_vals = &sub.values[idx_offset..idx_offset + n_hists];
                        // PGM-accelerated path: see comments at non-pooled call site.
                        #[cfg(feature = "pgm")]
                        {
                            let approx = sub.pgm_per_bin[bin_idx].search(target);
                            let lo = approx.lo.min(n_hists);
                            let hi = approx.hi.min(n_hists);
                            let local = &col_vals[lo..hi];
                            if !is_gt {
                                let h = lo + local.partition_point(|&x| x < target);
                                if h < n_hists { sub.extend_ids(&mut out, bin_idx, n_hists, h, n_hists); }
                            } else {
                                let mut h = lo + local.partition_point(|&x| x <= target);
                                while h < n_hists && col_vals[h] <= target { h += 1; }
                                if h > 0 { sub.extend_ids(&mut out, bin_idx, n_hists, 0, h); }
                            }
                        }
                        #[cfg(not(feature = "pgm"))]
                        if !is_gt {
                            let h = do_partition_lt(col_vals, target);
                            if h < n_hists { sub.extend_ids(&mut out, bin_idx, n_hists, h, n_hists); }
                        } else {
                            let h = do_partition_le(col_vals, target);
                            if h > 0 { sub.extend_ids(&mut out, bin_idx, n_hists, 0, h); }
                        }
                    }

                    #[cfg(all(feature = "f16", not(feature = "aos")))]
                    {
                        let col_vals = &sub.values[idx_offset..idx_offset + n_hists];
                        let target_h = half::f16::from_f32(target);
                        if !is_gt {
                            let h = f16_partition_lt(col_vals, target_h);
                            if h < n_hists { sub.extend_ids(&mut out, bin_idx, n_hists, h, n_hists); }
                        } else {
                            let h = f16_partition_le(col_vals, target_h);
                            if h > 0 { sub.extend_ids(&mut out, bin_idx, n_hists, 0, h); }
                        }
                    }

                    #[cfg(feature = "aos")]
                    {
                        let col = &sub.entries[idx_offset..idx_offset + n_hists];
                        if !is_gt {
                            let h = col.partition_point(|e| e.0 < target);
                            if h < n_hists { out.extend(col[h..].iter().map(|e| e.1)); }
                        } else {
                            let h = col.partition_point(|e| e.0 <= target);
                            if h > 0 { out.extend(col[..h].iter().map(|e| e.1)); }
                        }
                    }

                }
                return out;
            }

            // ── Default path: per-cluster Vec + flat_map + collect ────────────
            #[cfg(any(not(feature = "pooled"), feature = "cluster-par"))]
            let process_cluster = |c: usize| -> Vec<u32> {
                let bins = index.get_bins(c);
                if bins.len() < 2 { return vec![]; }

                if ref_val < bins[0] || ref_val > bins[bins.len() - 1] {
                    let trivially_all = (ref_val < bins[0] && is_gt)
                                     || (ref_val > bins[bins.len() - 1] && !is_gt);
                    if !trivially_all { return vec![]; }
                    let sub = match index.get_subindex(c, pctl_mode) { Some(s) => s, None => return vec![] };
                    let n_hists = index.get_cluster_size(c);
                    if n_hists > sub.len() { return vec![]; }
                    #[cfg(not(feature = "aos"))]
                    return ids_to_vec(sub, 0, n_hists, 0, n_hists);
                    #[cfg(feature = "aos")]
                    return sub.entries[..n_hists].iter().map(|e| e.1).collect();
                }

                let pp      = bins.partition_point(|&x| x < ref_val);
                let raw_idx = if pp == 0 { 0 } else { pp - 1 };
                let bin_idx = (raw_idx + bin_mode).min(bins.len() - 1);

                let sub = match index.get_subindex(c, pctl_mode) { Some(s) => s, None => return vec![] };
                let n_hists    = index.get_cluster_size(c);
                let idx_offset = bin_idx * sub.stride();
                if idx_offset + n_hists > sub.len() { return vec![]; }

                #[cfg(not(any(feature = "aos", feature = "f16")))]
                {
                    let col_vals = &sub.values[idx_offset..idx_offset + n_hists];

                    // PGM-accelerated path: model lookup + local scan, with the
                    // caveat that PGM's window guarantees contain *lower_bound*
                    // of `target`. For upper_bound (is_gt=true), runs of duplicate
                    // target values can extend past the window. After the local
                    // partition_point, we extend forward through any duplicates
                    // that lie beyond `hi` to recover the true upper_bound.
                    #[cfg(feature = "pgm")]
                    {
                        let approx = sub.pgm_per_bin[bin_idx].search(target);
                        let lo = approx.lo.min(n_hists);
                        let hi = approx.hi.min(n_hists);
                        let local = &col_vals[lo..hi];
                        if !is_gt {
                            // lower_bound — PGM's contract guarantees window contains it
                            let h = lo + local.partition_point(|&x| x < target);
                            if h < n_hists { ids_to_vec(sub, bin_idx, n_hists, h, n_hists) } else { vec![] }
                        } else {
                            // upper_bound — extend forward through any duplicate target values
                            let mut h = lo + local.partition_point(|&x| x <= target);
                            while h < n_hists && col_vals[h] <= target { h += 1; }
                            if h > 0 { ids_to_vec(sub, bin_idx, n_hists, 0, h) } else { vec![] }
                        }
                    }

                    #[cfg(not(feature = "pgm"))]
                    if !is_gt {
                        let h = do_partition_lt(col_vals, target);
                        if h < n_hists { ids_to_vec(sub, bin_idx, n_hists, h, n_hists) } else { vec![] }
                    } else {
                        let h = do_partition_le(col_vals, target);
                        if h > 0 { ids_to_vec(sub, bin_idx, n_hists, 0, h) } else { vec![] }
                    }
                }

                #[cfg(all(feature = "f16", not(feature = "aos")))]
                {
                    let col_vals = &sub.values[idx_offset..idx_offset + n_hists];
                    let target_h = half::f16::from_f32(target);
                    if !is_gt {
                        let h = f16_partition_lt(col_vals, target_h);
                        if h < n_hists { ids_to_vec(sub, bin_idx, n_hists, h, n_hists) } else { vec![] }
                    } else {
                        let h = f16_partition_le(col_vals, target_h);
                        if h > 0 { ids_to_vec(sub, bin_idx, n_hists, 0, h) } else { vec![] }
                    }
                }

                #[cfg(feature = "aos")]
                {
                    let col = &sub.entries[idx_offset..idx_offset + n_hists];
                    if !is_gt {
                        let h = col.partition_point(|e| e.0 < target);
                        if h < n_hists { col[h..].iter().map(|e| e.1).collect() } else { vec![] }
                    } else {
                        let h = col.partition_point(|e| e.0 <= target);
                        if h > 0 { col[..h].iter().map(|e| e.1).collect() } else { vec![] }
                    }
                }

            };

            #[cfg(all(not(feature = "cluster-par"), not(feature = "pooled")))]
            { (0..n_clusters).flat_map(process_cluster).collect() }
            #[cfg(feature = "cluster-par")]
            {
                use rayon::prelude::*;
                (0..n_clusters).into_par_iter().flat_map(|c| process_cluster(c)).collect()
            }
        }).collect()
    })
}
