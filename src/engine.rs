use crate::index::{FainderIndex, SubIndex};
use numpy::IntoPyArray;
use pyo3::prelude::*;
use rayon::prelude::*;

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Comparison {
    Lt, // <
    Le, // <=
    Gt, // >
    Ge, // >=
}

impl Comparison {
    fn from_str(s: &str) -> PyResult<Self> {
        match s {
            "lt" => Ok(Comparison::Lt),
            "le" => Ok(Comparison::Le),
            "gt" => Ok(Comparison::Gt),
            "ge" => Ok(Comparison::Ge),
            s if s.contains("l") => Ok(Comparison::Lt),
            s if s.contains("g") => Ok(Comparison::Gt),
            _ => Err(pyo3::exceptions::PyValueError::new_err(format!(
                "Invalid comparison operator: {}",
                s
            ))),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum IndexMode {
    Precision,
    Recall,
}

impl IndexMode {
    fn from_str(s: &str) -> PyResult<Self> {
        match s {
            "precision" => Ok(IndexMode::Precision),
            "recall" => Ok(IndexMode::Recall),
            _ => Err(pyo3::exceptions::PyValueError::new_err(format!(
                "Invalid index mode: {}",
                s
            ))),
        }
    }
}

pub struct TypedQuery {
    pub percentile: f32,
    pub comparison: Comparison,
    pub reference: f64,
}

// ── Per-(query, cluster) routing: precomputed to separate the cheap arithmetic
// from the expensive binary search. Stored as a flat array [q * n_c + c].
#[derive(Clone, Copy)]
enum Route {
    // Query's ref_val is outside cluster range in the wrong direction — skip.
    Pruned,
    // Query trivially matches the entire cluster (ref outside range, right direction).
    TriviallyAll { pctl_mode: usize },
    // Normal: binary search on the given (pctl_mode, bin_idx) column.
    Search { pctl_mode: usize, bin_idx: usize, target: f32, is_gt: bool },
}

fn compute_route(
    q: &TypedQuery,
    index: &FainderIndex,
    c: usize,
    index_mode: IndexMode,
    is_conversion: bool,
) -> Route {
    let bins = index.get_bins(c);
    if bins.len() < 2 { return Route::Pruned; }

    let (eff_percentile, is_gt) = match q.comparison {
        Comparison::Gt | Comparison::Ge => (1.0 - q.percentile, true),
        _ => (q.percentile, false),
    };
    let condition  = (is_gt && index_mode == IndexMode::Precision)
                  || (!is_gt && index_mode == IndexMode::Recall);
    let bin_mode   = if condition && !is_conversion { 1 } else { 0 };
    let pctl_mode  = if condition &&  is_conversion { 1 } else { 0 };
    let ref_val    = q.reference;

    if ref_val < bins[0] || ref_val > bins[bins.len() - 1] {
        let trivially_all = (ref_val < bins[0] && is_gt)
                         || (ref_val > bins[bins.len() - 1] && !is_gt);
        return if trivially_all {
            Route::TriviallyAll { pctl_mode }
        } else {
            Route::Pruned
        };
    }

    let pp      = bins.partition_point(|&x| x < ref_val);
    let raw_idx = if pp == 0 { 0 } else { pp - 1 };
    let bin_idx = (raw_idx + bin_mode).min(bins.len() - 1);

    Route::Search { pctl_mode, bin_idx, target: eff_percentile, is_gt }
}

// ── Row-centric engine (original): par_iter over queries, serial cluster loop.
// Access pattern: each query sweeps all clusters independently — no column reuse.
fn execute_row_centric(
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
                    #[cfg(not(any(feature = "aos", feature = "eytzinger")))]
                    return sub.indices[..n_hists].to_vec();
                    #[cfg(all(feature = "eytzinger", not(feature = "aos")))]
                    return sub.sorted_ids[..n_hists].to_vec();
                    #[cfg(feature = "aos")]
                    return sub.entries[..n_hists].iter().map(|e| e.1).collect();
                }

                let pp      = bins.partition_point(|&x| x < ref_val);
                let raw_idx = if pp == 0 { 0 } else { pp - 1 };
                let bin_idx = (raw_idx + bin_mode).min(bins.len() - 1);

                let sub = match index.get_subindex(c, pctl_mode) { Some(s) => s, None => return vec![] };
                let n_hists    = index.get_cluster_size(c);
                let idx_offset = bin_idx * n_hists;
                if idx_offset + n_hists > sub.len() { return vec![]; }

                #[cfg(not(any(feature = "aos", feature = "f16", feature = "eytzinger")))]
                {
                    let col_vals = &sub.values[idx_offset..idx_offset + n_hists];
                    let col_ids  = &sub.indices[idx_offset..idx_offset + n_hists];
                    if !is_gt {
                        let h = col_vals.partition_point(|&x| x < target);
                        if h < n_hists { col_ids[h..].to_vec() } else { vec![] }
                    } else {
                        let h = col_vals.partition_point(|&x| x <= target);
                        if h > 0 { col_ids[..h].to_vec() } else { vec![] }
                    }
                }

                #[cfg(all(feature = "f16", not(feature = "aos"), not(feature = "eytzinger")))]
                {
                    let col_vals = &sub.values[idx_offset..idx_offset + n_hists];
                    let col_ids  = &sub.indices[idx_offset..idx_offset + n_hists];
                    if !is_gt {
                        let h = col_vals.partition_point(|x| x.to_f32() < target);
                        if h < n_hists { col_ids[h..].to_vec() } else { vec![] }
                    } else {
                        let h = col_vals.partition_point(|x| x.to_f32() <= target);
                        if h > 0 { col_ids[..h].to_vec() } else { vec![] }
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

                #[cfg(all(feature = "eytzinger", not(feature = "aos")))]
                {
                    let col_eyt  = &sub.eyt_values[idx_offset..idx_offset + n_hists];
                    let col_perm = &sub.inv_perm[idx_offset..idx_offset + n_hists];
                    let col_ids  = &sub.sorted_ids[idx_offset..idx_offset + n_hists];
                    let n = n_hists;
                    let decode = |k: usize| -> usize {
                        let j = k >> (k.trailing_ones() + 1);
                        if j == 0 { n } else { col_perm[j - 1] as usize }
                    };
                    let h = if !is_gt {
                        let mut k = 1usize;
                        while k <= n {
                            #[cfg(target_arch = "x86_64")]
                            if 2 * k <= n {
                                unsafe {
                                    let ptr = col_eyt.as_ptr().add(2 * k - 1) as *const i8;
                                    std::arch::x86_64::_mm_prefetch(ptr, std::arch::x86_64::_MM_HINT_T0);
                                }
                            }
                            k = 2 * k + (col_eyt[k - 1] < target) as usize;
                        }
                        decode(k)
                    } else {
                        let mut k = 1usize;
                        while k <= n {
                            #[cfg(target_arch = "x86_64")]
                            if 2 * k <= n {
                                unsafe {
                                    let ptr = col_eyt.as_ptr().add(2 * k - 1) as *const i8;
                                    std::arch::x86_64::_mm_prefetch(ptr, std::arch::x86_64::_MM_HINT_T0);
                                }
                            }
                            k = 2 * k + (col_eyt[k - 1] <= target) as usize;
                        }
                        decode(k)
                    };
                    if !is_gt {
                        if h < n { col_ids[h..].to_vec() } else { vec![] }
                    } else {
                        if h > 0 { col_ids[..h].to_vec() } else { vec![] }
                    }
                }
            };

            #[cfg(not(feature = "cluster-par"))]
            { (0..n_clusters).flat_map(process_cluster).collect() }
            #[cfg(feature = "cluster-par")]
            {
                use rayon::prelude::*;
                (0..n_clusters).into_par_iter().flat_map(|c| process_cluster(c)).collect()
            }
        }).collect()
    })
}

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
#[cfg(not(any(feature = "aos", feature = "f16", feature = "eytzinger")))]
fn execute_columnar(
    typed_queries: &[TypedQuery],
    index: &FainderIndex,
    index_mode: IndexMode,
    is_conversion: bool,
    pool: &rayon::ThreadPool,
    suppress_results: bool,
) -> Vec<Vec<u32>> {
    let n_q       = typed_queries.len();
    let n_c       = index.n_clusters();

    let t0 = std::time::Instant::now();

    // Precompute routing for all (query, cluster) pairs.
    // Cheap: only partition_point on the small `bins` array (no index data access).
    // Laid out as route[q * n_c + c] for sequential access per cluster task.
    let routes: Vec<Route> = (0..n_q * n_c)
        .map(|i| {
            let q = i / n_c;
            let c = i % n_c;
            compute_route(&typed_queries[q], index, c, index_mode, is_conversion)
        })
        .collect();

    eprintln!("TIMER route_precompute: {:.3}s", t0.elapsed().as_secs_f64());

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
                        buf.extend_from_slice(&sub.indices[..n_hists]);
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
                    let idx_offset = bin_idx * n_hists;
                    if idx_offset + n_hists > sub.len() { continue; }

                    let col_vals = &sub.values[idx_offset..idx_offset + n_hists];
                    let col_ids  = &sub.indices[idx_offset..idx_offset + n_hists];

                    for &(q_idx, target, is_gt) in group {
                        let (h, take_tail) = if !is_gt {
                            (col_vals.partition_point(|&x| x < target), true)
                        } else {
                            (col_vals.partition_point(|&x| x <= target), false)
                        };
                        if take_tail {
                            if h < n_hists {
                                let start = buf.len();
                                buf.extend_from_slice(&col_ids[h..]);
                                offsets.push((q_idx, start, buf.len()));
                            }
                        } else if h > 0 {
                            let start = buf.len();
                            buf.extend_from_slice(&col_ids[..h]);
                            offsets.push((q_idx, start, buf.len()));
                        }
                    }
                }
            }

            (buf, offsets)
        }).collect()
    });

    eprintln!("TIMER parallel_phase: {:.3}s", t0.elapsed().as_secs_f64());

    // When suppress_results=true (benchmark mode), skip the 20 GB scatter-merge.
    // The parallel phase above already measured the binary search work; the merge
    // is pure memory movement that the Python CLI discards anyway.
    if suppress_results {
        eprintln!("TIMER merge: skipped (suppress_results)");
        return vec![vec![]; n_q];
    }

    let total_ids: usize = cluster_results.iter().map(|(buf, _)| buf.len()).sum();
    let total_offsets: usize = cluster_results.iter().map(|(_, off)| off.len()).sum();
    eprintln!("DIAG total_result_ids={} total_offsets={}", total_ids, total_offsets);

    // Merge: scatter flat-buffer slices into per-query result vecs.
    // Only n_c cross-thread frees (one Vec<u32> buf per cluster).
    let mut results: Vec<Vec<u32>> = vec![vec![]; n_q];
    for (buf, offsets) in cluster_results {
        for (q, start, end) in offsets {
            results[q].extend_from_slice(&buf[start..end]);
        }
    }

    eprintln!("TIMER merge: {:.3}s", t0.elapsed().as_secs_f64());

    results
}

// ── f16 column-centric variant
#[cfg(all(feature = "f16", not(feature = "aos"), not(feature = "eytzinger")))]
fn execute_columnar(
    typed_queries: &[TypedQuery],
    index: &FainderIndex,
    index_mode: IndexMode,
    is_conversion: bool,
    pool: &rayon::ThreadPool,
    suppress_results: bool,
) -> Vec<Vec<u32>> {
    use half::f16;
    let n_q = typed_queries.len();
    let n_c = index.n_clusters();

    let routes: Vec<Route> = (0..n_q * n_c)
        .map(|i| compute_route(&typed_queries[i / n_c], index, i % n_c, index_mode, is_conversion))
        .collect();

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
                        buf.extend_from_slice(&sub.indices[..n_hists]);
                        offsets.push((q_idx, start, buf.len()));
                    }
                }
            }

            for pctl_mode in 0..2usize {
                for bin_idx in 0..=n_bins {
                    let group = &groups[pctl_mode][bin_idx];
                    if group.is_empty() { continue; }
                    let sub = match index.get_subindex(c, pctl_mode) { Some(s) => s, None => continue };
                    let idx_offset = bin_idx * n_hists;
                    if idx_offset + n_hists > sub.len() { continue; }
                    let col_vals = &sub.values[idx_offset..idx_offset + n_hists];
                    let col_ids  = &sub.indices[idx_offset..idx_offset + n_hists];

                    for &(q_idx, target, is_gt) in group {
                        let (h, take_tail) = if !is_gt {
                            (col_vals.partition_point(|x| x.to_f32() < target), true)
                        } else {
                            (col_vals.partition_point(|x| x.to_f32() <= target), false)
                        };
                        if take_tail {
                            if h < n_hists {
                                let start = buf.len();
                                buf.extend_from_slice(&col_ids[h..]);
                                offsets.push((q_idx, start, buf.len()));
                            }
                        } else if h > 0 {
                            let start = buf.len();
                            buf.extend_from_slice(&col_ids[..h]);
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

    let mut results: Vec<Vec<u32>> = vec![vec![]; n_q];
    for (buf, offsets) in cluster_results {
        for (q, start, end) in offsets {
            results[q].extend_from_slice(&buf[start..end]);
        }
    }
    results
}

pub fn execute_queries(
    py: Python,
    index: &FainderIndex,
    raw_queries: Vec<(f32, String, f64)>,
    index_mode_str: &str,
    num_threads: Option<usize>,
    columnar: bool,
    suppress_results: bool,
) -> PyResult<Vec<PyObject>> {
    let index_mode = IndexMode::from_str(index_mode_str)?;

    let typed_queries: Result<Vec<TypedQuery>, PyErr> = raw_queries
        .into_iter()
        .map(|(p, c_str, ref_val)| {
            Ok(TypedQuery {
                percentile: p,
                comparison: Comparison::from_str(&c_str)?,
                reference: ref_val,
            })
        })
        .collect();
    let typed_queries = typed_queries?;

    let pool = rayon::ThreadPoolBuilder::new()
        .num_threads(num_threads.unwrap_or(0))
        .build()
        .map_err(|e| pyo3::exceptions::PyRuntimeError::new_err(e.to_string()))?;

    let n_clusters    = index.n_clusters();
    let is_conversion = n_clusters > 0 && index.get_subindex(0, 1).is_some();

    let results: Vec<Vec<u32>> = if columnar {
        // Column-centric: only implemented for SoA (f32 and f16).
        // Falls back to row-centric for aos/eytzinger variants.
        #[cfg(not(feature = "aos"))]
        { execute_columnar(&typed_queries, index, index_mode, is_conversion, &pool, suppress_results) }
        #[cfg(feature = "aos")]
        { execute_row_centric(&typed_queries, index, index_mode, is_conversion, &pool) }
    } else {
        execute_row_centric(&typed_queries, index, index_mode, is_conversion, &pool)
    };

    let t_pyo3 = std::time::Instant::now();
    let mut py_results: Vec<PyObject> = Vec::with_capacity(results.len());
    for res in results {
        let arr = res.into_pyarray_bound(py);
        py_results.push(arr.to_object(py));
    }
    if columnar {
        eprintln!("TIMER pyo3_conversion: {:.3}s", t_pyo3.elapsed().as_secs_f64());
    }
    Ok(py_results)
}
