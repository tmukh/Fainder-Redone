// Hybrid engine: parallelise over K-query batches; within each batch the
// outer loop is clusters and the inner loop is the batch's queries.
//
// Mechanism (vs row-centric default):
//   Row-centric:  for q in queries: for c in clusters: <work(q, c)>
//                 → cluster c+1's first cache line is loaded ~10000 times total
//                 (once per query). With par_iter over queries and N threads,
//                 each thread issues ~10000/N cluster-c+1 cold loads.
//
//   Query-batch:  for batch in queries.chunks(K): for c in clusters: for q in batch: <work(q, c)>
//                 → cluster c+1's first cache line is loaded once per BATCH,
//                 not once per query, then reused K times across the inner
//                 batch loop while still hot in L1. Amortises cluster
//                 cold-load by factor K.
//
// Tradeoffs vs columnar (par over clusters, K=all queries):
//   - Columnar parallelism caps at #clusters (~191 on c256_56gb), so at t=96
//     each thread gets 2 clusters of work — load-imbalanced if cluster sizes
//     differ. We see this directly: §3.5 columnar at t=96 on 56gb is 40s vs
//     bestofsuite's 20.5s.
//   - Query-batch with K=64 gives 10000/64 = 156 work units. With t=96 that's
//     ~1.6 tasks/thread. Still imbalanced. K=32 → 312 tasks (~3.3/thread).
//     Tunable; default K=64.
//
// K is read from FAINDER_QUERY_BATCH env (default 64). K=1 reduces to a slow
// transposed row-centric (don't use); K=n_q would equal columnar with serial
// queries (bad parallelism).

use crate::index::FainderIndex;
use rayon::prelude::*;
use super::types::{IndexMode, TypedQuery};
use super::routing::{Route, compute_route};
#[cfg(all(not(feature = "pgm"), not(feature = "f16")))]
use super::search::{do_partition_lt, do_partition_le};
#[cfg(all(feature = "f16", not(feature = "aos")))]
use super::search::{f16_partition_lt, f16_partition_le};

#[cfg(not(any(feature = "aos", feature = "f16")))]
pub(super) fn execute_query_batched(
    typed_queries: &[TypedQuery],
    index: &FainderIndex,
    index_mode: IndexMode,
    is_conversion: bool,
    pool: &rayon::ThreadPool,
) -> Vec<Vec<u32>> {
    let n_c = index.n_clusters();
    let k: usize = std::env::var("FAINDER_QUERY_BATCH")
        .ok()
        .and_then(|s| s.parse().ok())
        .filter(|&k: &usize| k > 0)
        .unwrap_or(64);

    pool.install(|| {
        typed_queries
            .par_chunks(k)
            .flat_map_iter(|q_batch| {
                let bsz = q_batch.len();
                // Per-batch output: one Vec<u32> per query in batch.
                let mut results: Vec<Vec<u32>> = (0..bsz)
                    .map(|_| Vec::with_capacity(1024))
                    .collect();

                // Precompute routes for this batch × all clusters (one
                // partition_point on bins per (q, c)). Stored row-major
                // [q_idx_in_batch * n_c + c] so each cluster step reads its
                // batch's routes contiguously.
                let mut routes: Vec<Route> = Vec::with_capacity(bsz * n_c);
                for q in q_batch.iter() {
                    for c in 0..n_c {
                        routes.push(compute_route(q, index, c, index_mode, is_conversion));
                    }
                }

                // Outer loop: clusters. Inner: queries within the batch.
                // Cluster c's bin-edges + active column slices stay hot in
                // L1/L2 across all K iterations of the inner loop.
                for c in 0..n_c {
                    let n_hists = index.get_cluster_size(c);
                    for (i, _q) in q_batch.iter().enumerate() {
                        let route = routes[i * n_c + c];
                        match route {
                            Route::Pruned => {}
                            Route::TriviallyAll { pctl_mode } => {
                                if let Some(sub) = index.get_subindex(c, pctl_mode) {
                                    if n_hists <= sub.len() {
                                        sub.extend_ids(&mut results[i], 0, n_hists, 0, n_hists);
                                    }
                                }
                            }
                            Route::Search { pctl_mode, bin_idx, target, is_gt } => {
                                let sub = match index.get_subindex(c, pctl_mode) {
                                    Some(s) => s,
                                    None => continue,
                                };
                                let idx_offset = bin_idx * sub.stride();
                                if idx_offset + n_hists > sub.len() { continue; }
                                let col_vals = &sub.values[idx_offset..idx_offset + n_hists];

                                #[cfg(feature = "pgm")]
                                {
                                    let approx = sub.pgm_per_bin[bin_idx].search(target);
                                    let lo = approx.lo.min(n_hists);
                                    let hi = approx.hi.min(n_hists);
                                    let local = &col_vals[lo..hi];
                                    if !is_gt {
                                        let h = lo + local.partition_point(|&x| x < target);
                                        if h < n_hists {
                                            sub.extend_ids(&mut results[i], bin_idx, n_hists, h, n_hists);
                                        }
                                    } else {
                                        let mut h = lo + local.partition_point(|&x| x <= target);
                                        while h < n_hists && col_vals[h] <= target { h += 1; }
                                        if h > 0 {
                                            sub.extend_ids(&mut results[i], bin_idx, n_hists, 0, h);
                                        }
                                    }
                                }

                                #[cfg(not(feature = "pgm"))]
                                {
                                    if !is_gt {
                                        let h = do_partition_lt(col_vals, target);
                                        if h < n_hists {
                                            sub.extend_ids(&mut results[i], bin_idx, n_hists, h, n_hists);
                                        }
                                    } else {
                                        let h = do_partition_le(col_vals, target);
                                        if h > 0 {
                                            sub.extend_ids(&mut results[i], bin_idx, n_hists, 0, h);
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                results.into_iter()
            })
            .collect()
    })
}

// ── f16 variant: same loop structure, columns are half::f16, per-query
// target is quantised to f16 once at point-of-use to match Python's
// np.searchsorted(col_f16, np.float16(target)) semantics. No PGM branch:
// the SubIndex variant under `f16` does not carry pgm_per_bin (PgmF32 is
// f32-only), so pgm + f16 is not a meaningful build combination.
#[cfg(all(feature = "f16", not(feature = "aos")))]
pub(super) fn execute_query_batched(
    typed_queries: &[TypedQuery],
    index: &FainderIndex,
    index_mode: IndexMode,
    is_conversion: bool,
    pool: &rayon::ThreadPool,
) -> Vec<Vec<u32>> {
    let n_c = index.n_clusters();
    let k: usize = std::env::var("FAINDER_QUERY_BATCH")
        .ok()
        .and_then(|s| s.parse().ok())
        .filter(|&k: &usize| k > 0)
        .unwrap_or(64);

    pool.install(|| {
        typed_queries
            .par_chunks(k)
            .flat_map_iter(|q_batch| {
                let bsz = q_batch.len();
                let mut results: Vec<Vec<u32>> = (0..bsz)
                    .map(|_| Vec::with_capacity(1024))
                    .collect();

                let mut routes: Vec<Route> = Vec::with_capacity(bsz * n_c);
                for q in q_batch.iter() {
                    for c in 0..n_c {
                        routes.push(compute_route(q, index, c, index_mode, is_conversion));
                    }
                }

                for c in 0..n_c {
                    let n_hists = index.get_cluster_size(c);
                    for (i, _q) in q_batch.iter().enumerate() {
                        let route = routes[i * n_c + c];
                        match route {
                            Route::Pruned => {}
                            Route::TriviallyAll { pctl_mode } => {
                                if let Some(sub) = index.get_subindex(c, pctl_mode) {
                                    if n_hists <= sub.len() {
                                        sub.extend_ids(&mut results[i], 0, n_hists, 0, n_hists);
                                    }
                                }
                            }
                            Route::Search { pctl_mode, bin_idx, target, is_gt } => {
                                let sub = match index.get_subindex(c, pctl_mode) {
                                    Some(s) => s,
                                    None => continue,
                                };
                                let idx_offset = bin_idx * sub.stride();
                                if idx_offset + n_hists > sub.len() { continue; }
                                let col_vals = &sub.values[idx_offset..idx_offset + n_hists];
                                let target_h = half::f16::from_f32(target);
                                if !is_gt {
                                    let h = f16_partition_lt(col_vals, target_h);
                                    if h < n_hists {
                                        sub.extend_ids(&mut results[i], bin_idx, n_hists, h, n_hists);
                                    }
                                } else {
                                    let h = f16_partition_le(col_vals, target_h);
                                    if h > 0 {
                                        sub.extend_ids(&mut results[i], bin_idx, n_hists, 0, h);
                                    }
                                }
                            }
                        }
                    }
                }

                results.into_iter()
            })
            .collect()
    })
}
