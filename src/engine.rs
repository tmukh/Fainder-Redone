use crate::index::{FainderIndex, SubIndex};
use pyo3::prelude::*;
use pyo3::types::PySet;
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
            "le" => Ok(Comparison::Le), // unlikely used but safe
            "gt" => Ok(Comparison::Gt),
            "ge" => Ok(Comparison::Ge), // unlikely used but safe
            s if s.contains("l") => Ok(Comparison::Lt), // Fallback for "lt" like logic if sloppy
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

struct TypedQuery {
    percentile: f32,
    comparison: Comparison,
    reference: f64,
}

pub fn execute_queries(
    py: Python,
    index: &FainderIndex,
    raw_queries: Vec<(f32, String, f64)>,
    index_mode_str: &str,
    num_threads: Option<usize>,
) -> PyResult<Vec<PyObject>> {
    let index_mode = IndexMode::from_str(index_mode_str)?;

    // 1. Parse all queries upfront (serial, fast enough)
    let typed_queries: Result<Vec<TypedQuery>, PyErr> = raw_queries
        .into_iter()
        .map(|(p, c_str, ref_val)| {
            let comp = Comparison::from_str(&c_str)?;
            Ok(TypedQuery {
                percentile: p,
                comparison: comp,
                reference: ref_val,
            })
        })
        .collect();
    let typed_queries = typed_queries?;

    // 2. Execute in parallel (No GIL)
    // We assume index structure is consistent (sanity checked in new)
    let n_clusters = index.n_clusters();

    // We need to determine if we are in "rebinning" mode (1 variant) or "conversion" (2 variants)
    // Actually, we just check how many variants exist per cluster.
    // We assume uniform structure across clusters for now, or handle per cluster.
    // Safe to check first cluster?
    // Let's implement robustly.

    // 2. Build a Rayon thread pool with the requested number of threads.
    // num_threads=None (or 0) → Rayon default (all available cores).
    // num_threads=Some(1)     → serial execution (ablation: isolates parallelism contribution).
    let pool = rayon::ThreadPoolBuilder::new()
        .num_threads(num_threads.unwrap_or(0))
        .build()
        .map_err(|e| pyo3::exceptions::PyRuntimeError::new_err(e.to_string()))?;

    let results: Vec<Vec<u32>> = pool.install(|| {
        typed_queries.par_iter().map(|q| {
            let mut matches: Vec<u32> = Vec::new();

            // Adjust percentile/logic based on comparison
            // Python: if "g" in comparison: percentile = 1.0 - percentile
            // And use "right" searchsorted equivalents if needed?
            // Python logic:
            // if "g": p = 1-p.
            // if ("g" & prec) or ("l" & recall):
            //    rebinning -> bin_mode=1
            //    conversion -> pctl_mode=1

            let (eff_percentile, is_gt) = match q.comparison {
                Comparison::Gt | Comparison::Ge => (1.0 - q.percentile, true),
                _ => (q.percentile, false),
            };

            let mut bin_mode = 0;
            let mut pctl_mode = 0;

            let condition = (is_gt && index_mode == IndexMode::Precision)
                || (!is_gt && index_mode == IndexMode::Recall);

            // Determine method implicitly from variants count of first cluster (assuming consistency)
            // But strict logic:
            // If variants[0].len() == 1 ("rebinning"): bin_mode=1 if condition, pctl_mode=0
            // If variants[0].len() > 1 ("conversion"): bin_mode=0, pctl_mode=1 if condition

            // We check cluster 0 (if exists)
            if n_clusters > 0 {
                // Peek at first cluster (safe because if n_clusters > 0, we can use `get_subindex` logic per cluster)
                // But generally property is global.
                // Let's assume rebinning if variants count == 1
                // Wait, `index` doesn't expose `get_variant_count`.
                // I'll add `get_subindex` which returns Option.
                // I'll just check `index.get_subindex(0, 1).is_some()` -> conversion.

                let is_conversion = index.get_subindex(0, 1).is_some();

                if condition {
                    if !is_conversion {
                        bin_mode = 1;
                    } else {
                        pctl_mode = 1;
                    }
                }
            }

            for c in 0..n_clusters {
                let bins = index.get_bins(c);
                if bins.len() < 2 {
                    continue;
                } // Empty bins?

                let ref_val = q.reference;
                if ref_val < bins[0] || ref_val > bins[bins.len() - 1] {
                    continue;
                }

                // Find bin index
                // Python: np.searchsorted(bins, ref, "left") - 1
                let search_idx = match bins.binary_search_by(|v| {
                    v.partial_cmp(&ref_val).unwrap_or(std::cmp::Ordering::Equal)
                }) {
                    Ok(i) => i,
                    Err(i) => i,
                };

                // Rust binary_search returns index where it could be inserted keeping order ("left" equivalent for Err)
                // If Exact match (Ok), it returns index.
                // We want bin index such that bins[i] <= ref < bins[i+1].
                // So if ref == bins[i], we want i.
                // If ref is between bins[i] and bins[i+1], binary_search returns i+1 (insertion point). So i + 1 - 1 = i?
                // Wait, binary_search: [10, 20]. Search 15 -> Err(1). 1-1 = 0. Correct.
                // Search 10 -> Ok(0). 0-1 = -1? No.
                // Python `searchsorted("left")`:
                // [10, 20]. Search 10 -> 0. 0-1 = -1 (clipped to 0).
                // Search 15 -> 1. 1-1 = 0.
                // Search 20 -> 2. 2-1 = 1.
                // Rust `partition_point` is equivalent to searchsorted.
                let pp = bins.partition_point(|&x| x < ref_val);
                // if ref=10 (bins[0]), bins element < 10 is false. pp=0. (Actually x < 10 is false for 10).
                // Wait, standard idiom for "partition_point" vs "binary_search".
                // I'll use `partition_point`.
                // `bins.partition_point(|&x| x <= ref_val)` is like "right".
                // `bins.partition_point(|&x| x < ref_val)` is like "left".
                // Python uses "left" for bins -> index.
                // `searchsorted(side='left', v=10)` on `[10, 20]` returns 0.
                // `partition_point(|x| x < 10)` on `[10, 20]`: 10<10 false. Returns 0.
                // `partition_point(|x| x < 15)`: 10<15 T, 20<15 F. Returns 1.
                // `partition_point(|x| x < 20)`: 10<20 T, 20<20 F. Returns 1.

                let pp = bins.partition_point(|&x| x < ref_val);
                let raw_bin_idx = if pp == 0 { 0 } else { pp - 1 };
                let bin_idx = (raw_bin_idx + bin_mode).min(bins.len() - 2); // bins has n_bins+1 edges for n_bins bins?
                                                                            // Actually bins array in Fainder: `cluster_bins` are bin edges?
                                                                            // Yes `np.linspace`.
                                                                            // If N edges, N-1 bins.
                                                                            // `len(bins) - 1` in python clip upper bound.
                                                                            // My `.min(bins.len() -2)` assumes len >= 2.

                // Access subindex
                if let Some(sub) = index.get_subindex(c, pctl_mode) {
                    let n_hists = index.get_cluster_size(c);
                    let idx_offset = bin_idx * n_hists;
                    if idx_offset + n_hists > sub.values.len() {
                        continue; // Should not happen with validation
                    }

                    let col_vals = &sub.values[idx_offset..idx_offset + n_hists];
                    let col_ids = &sub.indices[idx_offset..idx_offset + n_hists];

                    // Python: searchsorted on column
                    // if "l": left search. matches [hist_index:]
                    // if "g": right search. matches [:hist_index]

                    let target = eff_percentile;

                    if !is_gt {
                        // Less than: returns histograms with val >= target?
                        // Matches logic: `matches.update(pctl_index...[hist_index:])`
                        // So histograms starting from hist_index have pctl >= target.
                        // We want "histogram's percentile value" to be compared with query percentile?
                        // Logic in python: `hist_index = searchsorted(..., percentile, "left")`
                        // `pctl_index` stores sorted percentiles.
                        // We take everything FROM `hist_index` to END.
                        // So we take values >= percentile.

                        let h_idx = col_vals.partition_point(|&x| x < target);
                        if h_idx < n_hists {
                            matches.extend_from_slice(&col_ids[h_idx..]);
                        }
                    } else {
                        // Greater than: `searchsorted(..., "right")`
                        // matches `[:hist_index]`
                        // So we take values <= percentile (which was 1-p).

                        let h_idx = col_vals.partition_point(|&x| x <= target);
                        if h_idx > 0 {
                            matches.extend_from_slice(&col_ids[..h_idx]);
                        }
                    }
                }
            }
            matches
        }).collect()
    }); // end pool.install

    // 3. Convert to Python Sets (Sequential, GIL)
    let mut py_results: Vec<PyObject> = Vec::with_capacity(results.len());
    for res in results {
        // Use PySet::new_bound (PyO3 0.21+) or try PySet::new
        // Note: PySet::new might require importing the trait which provides 'new' if strictly typed?
        // No, it's an associated function.
        // Try PySet::new_bound which returns Bound<PySet>
        let set = PySet::new_bound(py, &res)?;
        py_results.push(set.to_object(py));
    }

    Ok(py_results)
}