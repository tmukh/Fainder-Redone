use crate::index::FainderIndex;
use rayon::prelude::*;
use super::types::{IndexMode, TypedQuery};
use super::routing::{Route, compute_route};
#[cfg(all(not(any(feature = "batch-search", feature = "horizontal-simd")), not(feature = "pgm"), not(feature = "f16")))]
use super::search::{do_partition_lt, do_partition_le};
#[cfg(all(feature = "horizontal-simd", target_arch = "x86_64"))]
use super::search::{do_partition_lt, do_partition_le};
#[cfg(feature = "batch-search")]
use super::search::{BATCH, batch_partition_point_8};
#[cfg(all(feature = "batch-search", feature = "f16", not(feature = "aos")))]
use super::search::batch_partition_point_8_f16;
#[cfg(all(feature = "f16", not(any(feature = "aos", feature = "batch-search"))))]
use super::search::{f16_partition_lt, f16_partition_le};

// ── Column-centric engine: par_iter over clusters, sequential query loop.
//
// Access pattern flip vs row-centric:
//   Row-centric:    query_0 → [c0, c1, ..., c56]   query_1 → [c0, c1, ..., c56]
//   Column-centric: cluster_0 → [q0, q1, ..., q9999]   cluster_1 → [q0, q1, ...]
//
// Why this is faster:
//   Each cluster owns a thread. While that thread processes all 10k queries, the
//   cluster's column data (14 KB per bin) stays in L2/L3 cache. The top levels of
//   the binary search tree — always accessed first — become cache hits after the
//   first query warms them up.
//
//   Within each cluster, queries are grouped by (pctl_mode, bin_idx): all queries
//   that search the same column run consecutively while that column is in cache.
//
// Parallelism: 57 cluster tasks (eval_medium) vs 10k query tasks. Fewer tasks but
// each is larger — Rayon work-stealing still load-balances across cores.
#[cfg(not(any(feature = "aos", feature = "f16")))]
pub(super) fn execute_columnar(
    typed_queries: &[TypedQuery],
    index: &FainderIndex,
    index_mode: IndexMode,
    is_conversion: bool,
    pool: &rayon::ThreadPool,
    suppress_results: bool,
) -> Vec<Vec<u32>> {
    let n_q       = typed_queries.len();
    let n_c       = index.n_clusters();

    // Precompute routing for all (query, cluster) pairs in parallel on the
    // configured pool. Cheap per item (one partition_point on the small
    // `bins` array), but with n_q * n_c ~= 570K on eval_medium it's a
    // ~25-50 ms wholly-serial phase if left on the calling thread.
    // Laid out as route[q * n_c + c] for sequential access per cluster task.
    let routes: Vec<Route> = pool.install(|| {
        (0..n_q * n_c)
            .into_par_iter()
            .map(|i| {
                let q = i / n_c;
                let c = i % n_c;
                compute_route(&typed_queries[q], index, c, index_mode, is_conversion)
            })
            .collect()
    });

    // Per-cluster task: group queries by (pctl_mode, bin_idx), then run all
    // binary searches for each group while the column is hot in cache.
    //
    // Each task returns a flat (buf, offsets) pair instead of Vec<(usize, Vec<u32>)>.
    // This eliminates per-match heap allocations: each cluster makes ONE large Vec<u32>
    // allocation (amortised growth) rather than N_matches small ones. This matters
    // because small Vecs allocated on Rayon worker threads must be freed cross-thread
    // in the merge phase, which requires a glibc arena lock per free (~50µs each).
    // With ~285k such frees the lock contention dominates (~14s serial overhead).
    // Flat buffers reduce cross-thread frees from 285k to 57 (one large free per cluster).
    let cluster_results: Vec<(Vec<u32>, Vec<(usize, usize, usize)>)> = pool.install(|| {
        (0..n_c).into_par_iter().map(|c| {
            let n_hists = index.get_cluster_size(c);
            // Flat buffer: all matching IDs for this cluster concatenated.
            let mut buf:     Vec<u32>                  = Vec::new();
            // Offset index: (q_idx, start, end) into buf.
            let mut offsets: Vec<(usize, usize, usize)> = Vec::new();

            // Groups keyed by (pctl_mode, bin_idx): direct 2D index avoids linear scan.
            // n_bins per cluster is bounded; allocate groups[pctl_mode][bin_idx].
            let n_bins = index.get_bins(c).len().saturating_sub(1).max(1);
            let mut groups: Vec<Vec<Vec<(usize, f32, bool)>>> =
                vec![vec![vec![]; n_bins + 1]; 2];
            let mut trivial_all: Vec<(usize, usize)> = Vec::new();

            for q in 0..n_q {
                match routes[q * n_c + c] {
                    Route::Pruned => {}
                    Route::TriviallyAll { pctl_mode } => {
                        trivial_all.push((q, pctl_mode));
                    }
                    Route::Search { pctl_mode, bin_idx, target, is_gt } => {
                        let bi = bin_idx.min(n_bins);
                        groups[pctl_mode][bi].push((q, target, is_gt));
                    }
                }
            }

            // TriviallyAll: append all IDs from column 0 of the cluster.
            for (q_idx, pctl_mode) in trivial_all {
                if let Some(sub) = index.get_subindex(c, pctl_mode) {
                    if n_hists <= sub.len() {
                        let start = buf.len();
                        sub.extend_ids(&mut buf, 0, n_hists, 0, n_hists);
                        offsets.push((q_idx, start, buf.len()));
                    }
                }
            }

            // Search groups: load column once, binary-search all queries in group.
            for pctl_mode in 0..2usize {
                for bin_idx in 0..=n_bins {
                    let group = &groups[pctl_mode][bin_idx];
                    if group.is_empty() { continue; }
                    let sub = match index.get_subindex(c, pctl_mode) { Some(s) => s, None => continue };
                    let idx_offset = bin_idx * sub.stride();
                    if idx_offset + n_hists > sub.len() { continue; }

                    let col_vals = &sub.values[idx_offset..idx_offset + n_hists];

                    #[cfg(feature = "batch-search")]
                    for chunk in group.chunks(BATCH) {
                        let hs = batch_partition_point_8(col_vals, chunk);
                        for (i, &(q_idx, _, is_gt)) in chunk.iter().enumerate() {
                            let h = hs[i];
                            if !is_gt {
                                if h < n_hists {
                                    let start = buf.len();
                                    sub.extend_ids(&mut buf, bin_idx, n_hists, h, n_hists);
                                    offsets.push((q_idx, start, buf.len()));
                                }
                            } else if h > 0 {
                                let start = buf.len();
                                sub.extend_ids(&mut buf, bin_idx, n_hists, 0, h);
                                offsets.push((q_idx, start, buf.len()));
                            }
                        }
                    }
                    #[cfg(all(not(feature = "batch-search"), not(feature = "horizontal-simd")))]
                    for &(q_idx, target, is_gt) in group {
                        // PGM-accelerated path (column-centric scalar fallback).
                        // For is_gt=true, extend forward through duplicate target
                        // values that PGM's window may not have captured.
                        #[cfg(feature = "pgm")]
                        let (h, take_tail) = {
                            let approx = sub.pgm_per_bin[bin_idx].search(target);
                            let lo = approx.lo.min(n_hists);
                            let hi = approx.hi.min(n_hists);
                            let local = &col_vals[lo..hi];
                            if !is_gt {
                                (lo + local.partition_point(|&x| x < target), true)
                            } else {
                                let mut h = lo + local.partition_point(|&x| x <= target);
                                while h < n_hists && col_vals[h] <= target { h += 1; }
                                (h, false)
                            }
                        };
                        #[cfg(not(feature = "pgm"))]
                        let (h, take_tail) = if !is_gt {
                            (do_partition_lt(col_vals, target), true)
                        } else {
                            (do_partition_le(col_vals, target), false)
                        };
                        if take_tail {
                            if h < n_hists {
                                let start = buf.len();
                                sub.extend_ids(&mut buf, bin_idx, n_hists, h, n_hists);
                                offsets.push((q_idx, start, buf.len()));
                            }
                        } else if h > 0 {
                            let start = buf.len();
                            sub.extend_ids(&mut buf, bin_idx, n_hists, 0, h);
                            offsets.push((q_idx, start, buf.len()));
                        }
                    }

                    // Horizontal AVX-512 SIMD: 16 queries in lockstep through bisection.
                    // Splits group by is_gt (lt vs le semantics differ at the leaf).
                    #[cfg(all(feature = "horizontal-simd", target_arch = "x86_64"))]
                    {
                        // Split: lt-queries (take col_ids[h..]) vs gt-queries (take col_ids[..h])
                        let lt_queries: Vec<(usize, f32)> = group.iter()
                            .filter(|q| !q.2).map(|q| (q.0, q.1)).collect();
                        let gt_queries: Vec<(usize, f32)> = group.iter()
                            .filter(|q| q.2).map(|q| (q.0, q.1)).collect();

                        // Process LT chunks
                        for chunk in lt_queries.chunks(16) {
                            let mut targets = [0f32; 16];
                            for (i, &(_, t)) in chunk.iter().enumerate() { targets[i] = t; }
                            let hs = if is_x86_feature_detected!("avx512f") {
                                unsafe { crate::horizontal_simd::batch_partition_lt_avx512(col_vals, &targets, chunk.len()) }
                            } else {
                                let mut out = [0usize; 16];
                                for (i, &(_, t)) in chunk.iter().enumerate() {
                                    out[i] = do_partition_lt(col_vals, t);
                                }
                                out
                            };
                            for (i, &(q_idx, _)) in chunk.iter().enumerate() {
                                let h = hs[i];
                                if h < n_hists {
                                    let start = buf.len();
                                    sub.extend_ids(&mut buf, bin_idx, n_hists, h, n_hists);
                                    offsets.push((q_idx, start, buf.len()));
                                }
                            }
                        }

                        // Process GT chunks (le semantics)
                        for chunk in gt_queries.chunks(16) {
                            let mut targets = [0f32; 16];
                            for (i, &(_, t)) in chunk.iter().enumerate() { targets[i] = t; }
                            let hs = if is_x86_feature_detected!("avx512f") {
                                unsafe { crate::horizontal_simd::batch_partition_le_avx512(col_vals, &targets, chunk.len()) }
                            } else {
                                let mut out = [0usize; 16];
                                for (i, &(_, t)) in chunk.iter().enumerate() {
                                    out[i] = do_partition_le(col_vals, t);
                                }
                                out
                            };
                            for (i, &(q_idx, _)) in chunk.iter().enumerate() {
                                let h = hs[i];
                                if h > 0 {
                                    let start = buf.len();
                                    sub.extend_ids(&mut buf, bin_idx, n_hists, 0, h);
                                    offsets.push((q_idx, start, buf.len()));
                                }
                            }
                        }
                    }
                }
            }

            (buf, offsets)
        }).collect()
    });

    // When suppress_results=true (benchmark mode), skip the scatter-merge.
    // The parallel phase above already measured the binary search work; the
    // merge is pure memory movement that the Python CLI discards anyway.
    if suppress_results {
        return vec![vec![]; n_q];
    }

    // Parallel merge: bucket offsets by query (single serial pass — small),
    // then build each query's result Vec independently in parallel. Replaces
    // the old single-threaded scatter, which was the dominant phase whenever
    // |S| was non-trivial (Fainder paper §7.2).
    let mut per_query_chunks: Vec<Vec<(usize, usize, usize)>> = vec![Vec::new(); n_q];
    for (cluster_idx, (_, offsets)) in cluster_results.iter().enumerate() {
        for &(q, start, end) in offsets {
            per_query_chunks[q].push((cluster_idx, start, end));
        }
    }

    pool.install(|| {
        per_query_chunks.into_par_iter().map(|chunks| {
            let total: usize = chunks.iter().map(|&(_, s, e)| e - s).sum();
            let mut out = Vec::with_capacity(total);
            for (cluster_idx, start, end) in chunks {
                out.extend_from_slice(&cluster_results[cluster_idx].0[start..end]);
            }
            out
        }).collect()
    })
}

// ── f16 column-centric variant
#[cfg(all(feature = "f16", not(feature = "aos")))]
pub(super) fn execute_columnar(
    typed_queries: &[TypedQuery],
    index: &FainderIndex,
    index_mode: IndexMode,
    is_conversion: bool,
    pool: &rayon::ThreadPool,
    suppress_results: bool,
) -> Vec<Vec<u32>> {
    let n_q = typed_queries.len();
    let n_c = index.n_clusters();

    let routes: Vec<Route> = pool.install(|| {
        (0..n_q * n_c)
            .into_par_iter()
            .map(|i| compute_route(&typed_queries[i / n_c], index, i % n_c, index_mode, is_conversion))
            .collect()
    });

    let cluster_results: Vec<(Vec<u32>, Vec<(usize, usize, usize)>)> = pool.install(|| {
        (0..n_c).into_par_iter().map(|c| {
            let n_hists = index.get_cluster_size(c);
            let mut buf:     Vec<u32>                   = Vec::new();
            let mut offsets: Vec<(usize, usize, usize)> = Vec::new();

            let n_bins = index.get_bins(c).len().saturating_sub(1).max(1);
            let mut groups: Vec<Vec<Vec<(usize, f32, bool)>>> =
                vec![vec![vec![]; n_bins + 1]; 2];
            let mut trivial_all: Vec<(usize, usize)> = Vec::new();

            for q in 0..n_q {
                match routes[q * n_c + c] {
                    Route::Pruned => {}
                    Route::TriviallyAll { pctl_mode } => trivial_all.push((q, pctl_mode)),
                    Route::Search { pctl_mode, bin_idx, target, is_gt } => {
                        let bi = bin_idx.min(n_bins);
                        groups[pctl_mode][bi].push((q, target, is_gt));
                    }
                }
            }

            for (q_idx, pctl_mode) in trivial_all {
                if let Some(sub) = index.get_subindex(c, pctl_mode) {
                    if n_hists <= sub.len() {
                        let start = buf.len();
                        sub.extend_ids(&mut buf, 0, n_hists, 0, n_hists);
                        offsets.push((q_idx, start, buf.len()));
                    }
                }
            }

            for pctl_mode in 0..2usize {
                for bin_idx in 0..=n_bins {
                    let group = &groups[pctl_mode][bin_idx];
                    if group.is_empty() { continue; }
                    let sub = match index.get_subindex(c, pctl_mode) { Some(s) => s, None => continue };
                    let idx_offset = bin_idx * sub.stride();
                    if idx_offset + n_hists > sub.len() { continue; }
                    let col_vals = &sub.values[idx_offset..idx_offset + n_hists];

                    #[cfg(feature = "batch-search")]
                    for chunk in group.chunks(BATCH) {
                        let hs = batch_partition_point_8_f16(col_vals, chunk);
                        for (i, &(q_idx, _, is_gt)) in chunk.iter().enumerate() {
                            let h = hs[i];
                            if !is_gt {
                                if h < n_hists {
                                    let start = buf.len();
                                    sub.extend_ids(&mut buf, bin_idx, n_hists, h, n_hists);
                                    offsets.push((q_idx, start, buf.len()));
                                }
                            } else if h > 0 {
                                let start = buf.len();
                                sub.extend_ids(&mut buf, bin_idx, n_hists, 0, h);
                                offsets.push((q_idx, start, buf.len()));
                            }
                        }
                    }
                    #[cfg(not(feature = "batch-search"))]
                    for &(q_idx, target, is_gt) in group {
                        let target_h = half::f16::from_f32(target);
                        let (h, take_tail) = if !is_gt {
                            (f16_partition_lt(col_vals, target_h), true)
                        } else {
                            (f16_partition_le(col_vals, target_h), false)
                        };
                        if take_tail {
                            if h < n_hists {
                                let start = buf.len();
                                sub.extend_ids(&mut buf, bin_idx, n_hists, h, n_hists);
                                offsets.push((q_idx, start, buf.len()));
                            }
                        } else if h > 0 {
                            let start = buf.len();
                            sub.extend_ids(&mut buf, bin_idx, n_hists, 0, h);
                            offsets.push((q_idx, start, buf.len()));
                        }
                    }
                }
            }

            (buf, offsets)
        }).collect()
    });

    if suppress_results {
        return vec![vec![]; n_q];
    }

    // Parallel merge — see f32 columnar engine for rationale.
    let mut per_query_chunks: Vec<Vec<(usize, usize, usize)>> = vec![Vec::new(); n_q];
    for (cluster_idx, (_, offsets)) in cluster_results.iter().enumerate() {
        for &(q, start, end) in offsets {
            per_query_chunks[q].push((cluster_idx, start, end));
        }
    }

    pool.install(|| {
        per_query_chunks.into_par_iter().map(|chunks| {
            let total: usize = chunks.iter().map(|&(_, s, e)| e - s).sum();
            let mut out = Vec::with_capacity(total);
            for (cluster_idx, start, end) in chunks {
                out.extend_from_slice(&cluster_results[cluster_idx].0[start..end]);
            }
            out
        }).collect()
    })
}
