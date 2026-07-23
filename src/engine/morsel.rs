// Morsel-driven scheduler — Bandle/Giceva VLDB 2021 adapted for Fainder.
//
// ── Problem this engine targets (work-fragmentation ceiling, §3.8 + §3.9):
//   query-batch K=128 wins 56gb t=96 (16.17s) but cooperative cluster
//   caching is best-effort. Rayon's par_chunks(128) hands ~78 cluster-outer
//   tasks to ~96 workers; workers progress through their batches' outer
//   cluster loops independently. Two workers can simultaneously be on
//   cluster c+1 and refault its bin-edges/values column from L3/DRAM that
//   another worker is still using in L1/L2.
//
// ── Mechanism (vs query-batch):
//   1) LPT scheduling: process clusters DESC by cluster_size (Graham 1969,
//      4/3 × OPT makespan bound).
//   2) Phase-major morsel push order: morsels for cluster c are pushed
//      to per-worker queues *before* morsels for c+1. Workers with FIFO
//      local deques therefore process phases in order. Combined with
//      LPT, soft phase alignment emerges: workers advance through phases
//      together (within ~1 phase) without explicit barriers.
//   3) Adaptive grain: target ~500µs per morsel (≥100µs hard clamp).
//      Initial estimate from cluster_size; refined by Step-3 timing
//      histograms.
//   4) Crossbeam-deque (Chase-Lev) Workers as per-thread FIFO queues +
//      stealers for cross-worker work-stealing on stragglers.
//
// ── Output buffer design (critical):
//   Per-worker, NOT per-(worker, query). v1 maintained a Vec<Vec<u32>>
//   per worker indexed by query — 96 workers × 10_000 queries = 960K Vec
//   headers (~23 MB of header churn), every push to a different cache
//   line. Catastrophic allocator pressure on Sapphire Rapids (10× slower
//   than default at t=32).
//
//   v2: each worker has ONE flat append-only `ids: Vec<u32>` plus a
//   `chunks: Vec<(query_id, start_offset, count)>` index. Per-(q,c) emit
//   appends contiguous ids and records the chunk. Merge phase scans
//   chunks across workers, builds per-query Vec<u32> in two passes:
//   first pass counts to size allocations, second pass copies. O(total
//   IDs) total work, allocator-friendly. Per-worker memory grows
//   geometrically (log #pushes), not linearly.
//
// ── References:
//   - Bandle/Giceva, "Make the Most out of Your SIMD Investments…",
//     VLDB 2021.
//   - Leis et al., "Morsel-Driven Parallelism…", SIGMOD 2014.
//   - Graham, "Bounds on Multiprocessing Timing Anomalies", 1969 (LPT).
//   - Crossbeam-deque: Rust impl of Chase-Lev work-stealing deque.

use crate::index::FainderIndex;
use crossbeam_deque::{Stealer, Worker};

use super::routing::{Route, compute_route};
use super::types::{IndexMode, TypedQuery};

#[cfg(all(not(feature = "pgm"), not(feature = "f16")))]
use super::search::{do_partition_le, do_partition_lt};

/// One unit of schedulable work: process queries [q_start, q_end) against
/// cluster `cluster`. 12 B; copy-by-value across the deque is ~free.
#[derive(Clone, Copy)]
struct Morsel {
    cluster: u32,
    q_start: u32,
    q_end: u32,
}

/// Per-worker append-only output. Memory layout designed for streaming
/// writes: each emit pushes contiguous ids to `ids`, records (q, start,
/// count) in `chunks`. Doubling reallocation amortises growth cost.
#[derive(Default)]
struct WorkerOut {
    ids: Vec<u32>,
    chunks: Vec<(u32, u32, u32)>, // (query_id, start_offset, count)
}

/// Pick morsel size (queries per morsel) for a cluster of given n_hists.
///
/// Heuristic: per-query work is dominated by emit (~n_hist/2 ids on
/// average for a median target). Target ~500µs/morsel keeps per-morsel
/// coordination overhead amortised. v2 uses a static heuristic; Step 3
/// will refine via per-morsel duration histogram.
fn choose_morsel_queries(n_hists: usize) -> u32 {
    let lg = (n_hists.max(2) as f64).log2().max(1.0);
    let baseline_lg = 19.5_f64; // log2(770_000) ≈ 19.55 — c256_56gb anchor
    let target_q = (50.0 * baseline_lg / lg).clamp(8.0, 256.0);
    target_q as u32
}

/// Pop one morsel: own deque first (FIFO), then steal from peers.
/// Returns None when one full settled pass observes Empty across all
/// peer queues (no Retry).
fn pop_morsel(
    local: &Worker<Morsel>,
    stealers: &[Stealer<Morsel>],
    own_idx: usize,
) -> Option<Morsel> {
    if let Some(m) = local.pop() {
        return Some(m);
    }
    let n = stealers.len();
    let mut quiet_pass = false;
    while !quiet_pass {
        quiet_pass = true;
        for k in 1..n {
            let j = (own_idx + k) % n;
            // Steal one element at a time — bulk steal would scramble
            // phase order across stolen batches.
            match stealers[j].steal() {
                crossbeam_deque::Steal::Success(m) => return Some(m),
                crossbeam_deque::Steal::Retry => {
                    quiet_pass = false;
                }
                crossbeam_deque::Steal::Empty => {}
            }
        }
    }
    None
}

/// Process one morsel: emit chunks into the calling worker's output.
#[cfg(not(any(feature = "aos", feature = "f16", feature = "pgm")))]
fn process_morsel(
    m: Morsel,
    typed_queries: &[TypedQuery],
    index: &FainderIndex,
    index_mode: IndexMode,
    is_conversion: bool,
    out: &mut WorkerOut,
) {
    let c = m.cluster as usize;
    let n_hists = index.get_cluster_size(c);
    for qi in m.q_start..m.q_end {
        let q = &typed_queries[qi as usize];
        let route = compute_route(q, index, c, index_mode, is_conversion);
        // Record the start offset before the (possible) emit. Each
        // (q, c) emits a single contiguous range, so one chunk per
        // (q, c) suffices.
        let start = out.ids.len() as u32;
        match route {
            Route::Pruned => {}
            Route::TriviallyAll { pctl_mode } => {
                if let Some(sub) = index.get_subindex(c, pctl_mode) {
                    if n_hists <= sub.len() {
                        sub.extend_ids(&mut out.ids, 0, n_hists, 0, n_hists);
                    }
                }
            }
            Route::Search { pctl_mode, bin_idx, target, is_gt } => {
                if let Some(sub) = index.get_subindex(c, pctl_mode) {
                    let idx_offset = bin_idx * sub.stride();
                    if idx_offset + n_hists <= sub.len() {
                        let col_vals = &sub.values[idx_offset..idx_offset + n_hists];
                        if !is_gt {
                            let h = do_partition_lt(col_vals, target);
                            if h < n_hists {
                                sub.extend_ids(&mut out.ids, bin_idx, n_hists, h, n_hists);
                            }
                        } else {
                            let h = do_partition_le(col_vals, target);
                            if h > 0 {
                                sub.extend_ids(&mut out.ids, bin_idx, n_hists, 0, h);
                            }
                        }
                    }
                }
            }
        }
        let count = out.ids.len() as u32 - start;
        if count > 0 {
            out.chunks.push((qi, start, count));
        }
    }
}

/// f32 entry point. Builds morsels in LPT-sorted phase-major order,
/// distributes round-robin to per-worker FIFO deques, spawns workers,
/// merges per-worker outputs into final per-query Vec<u32>.
///
/// `suppress_results=true`: skip the merge phase entirely and return a
/// Vec of empty Vecs. The Python wrapper discards the IDs in this mode
/// (`matches = [set() for _ in raw_matches]`), so paying the merge cost
/// would be pure waste on the bench path. Default and query-batch
/// engines never had a separate merge — they write per-query Vecs
/// directly during the worker phase — so the suppress short-circuit
/// here is what makes morsel timings comparable to those engines'.
#[cfg(not(any(feature = "aos", feature = "f16", feature = "pgm")))]
pub(super) fn execute_morsel(
    typed_queries: &[TypedQuery],
    index: &FainderIndex,
    index_mode: IndexMode,
    is_conversion: bool,
    pool: &rayon::ThreadPool,
    suppress_results: bool,
) -> Vec<Vec<u32>> {
    let n_c = index.n_clusters();
    let n_q = typed_queries.len();
    let n_threads = pool.current_num_threads().max(1);

    // ── Phase 1: build morsel list in LPT-sorted phase-major order.
    // Clusters DESC by cluster_size; within each cluster, queries
    // chunked per choose_morsel_queries(n_hists).
    let mut cluster_order: Vec<u32> = (0..n_c as u32).collect();
    cluster_order.sort_by_key(|&c| std::cmp::Reverse(index.get_cluster_size(c as usize)));

    // Per-worker FIFO deques. Distribute morsels round-robin across
    // workers in phase-major push order so each worker's local queue
    // is ordered phase 0 → phase 1 → ... when popped FIFO.
    let workers: Vec<Worker<Morsel>> = (0..n_threads).map(|_| Worker::new_fifo()).collect();
    let stealers: Vec<Stealer<Morsel>> = workers.iter().map(|w| w.stealer()).collect();

    let mut rr = 0usize;
    for &c in &cluster_order {
        let n_hists = index.get_cluster_size(c as usize);
        let qs = choose_morsel_queries(n_hists);
        let mut q = 0u32;
        while q < n_q as u32 {
            let qe = (q + qs).min(n_q as u32);
            workers[rr % n_threads].push(Morsel { cluster: c, q_start: q, q_end: qe });
            rr += 1;
            q = qe;
        }
    }

    // Per-worker append-only output buffers.
    let mut per_worker: Vec<WorkerOut> = (0..n_threads).map(|_| WorkerOut::default()).collect();

    let stealers_ref = &stealers[..];

    pool.install(|| {
        rayon::scope(|s| {
            for (w_idx, (local, out)) in workers
                .into_iter()
                .zip(per_worker.iter_mut())
                .enumerate()
            {
                s.spawn(move |_| {
                    let local = local;
                    while let Some(m) = pop_morsel(&local, stealers_ref, w_idx) {
                        process_morsel(m, typed_queries, index, index_mode, is_conversion, out);
                    }
                });
            }
        });
    });

    // ── Phase 2: merge per-worker outputs into final per-query Vec<u32>.
    //
    // Suppress short-circuit: bench mode discards the IDs, so don't
    // pay the merge cost. Default and query-batch don't have an
    // analogous merge phase (they write per-query Vec directly during
    // workers), so this is required for apples-to-apples comparison.
    if suppress_results {
        return (0..n_q).map(|_| Vec::new()).collect();
    }

    // Naive merge (one pass over per_worker.chunks → out[qi]) randomly
    // writes into 10K different per-query Vec<u32>s, hitting TLB + cache
    // misses on every chunk. Pre-bucketing chunks by query_id keeps
    // each query's chunks contiguous, then par_iter over queries fills
    // outs in parallel. Still costly (one full pass over the per-worker
    // ids buffers, ~16 s on c256_56gb t=32) but bounded.
    use rayon::prelude::*;
    let mut per_query_chunks: Vec<Vec<(u8, u32, u32)>> =
        (0..n_q).map(|_| Vec::new()).collect();
    for (w_idx, w) in per_worker.iter().enumerate() {
        for &(qi, start, count) in &w.chunks {
            per_query_chunks[qi as usize].push((w_idx as u8, start, count));
        }
    }
    let per_worker_ref = &per_worker[..];
    pool.install(|| {
        per_query_chunks
            .into_par_iter()
            .map(|chunks| {
                let total: usize = chunks.iter().map(|&(_, _, c)| c as usize).sum();
                let mut v = Vec::with_capacity(total);
                for (w_idx, start, count) in chunks {
                    let w = &per_worker_ref[w_idx as usize];
                    let s = start as usize;
                    let e = s + count as usize;
                    v.extend_from_slice(&w.ids[s..e]);
                }
                v
            })
            .collect()
    })
}
