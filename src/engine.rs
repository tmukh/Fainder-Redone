use crate::index::RebinningIndex;
use pyo3::prelude::*;
use rayon::prelude::*;
use std::collections::HashSet;

pub fn execute_queries(
    index: &RebinningIndex,
    queries: Vec<(f32, String, f64)>,
    index_mode: &str,
) -> PyResult<Vec<Vec<u32>>> {
    let mode_recall = index_mode == "recall";
    let mode_precision = index_mode == "precision";

    // We parallelize over queries using Rayon
    let results: Vec<Vec<u32>> = queries
        .par_iter()
        .map(|(percentile, comparison, reference)| {
            let mut query_matches: HashSet<u32> = HashSet::new();

            // Rewrite > to < if needed (same logic as python)
            let (final_pctl, is_greater) = if comparison.contains('g') {
                (1.0 - percentile, true)
            } else {
                (*percentile, false)
            };

            let is_less = comparison.contains('l');
            let is_geq = is_greater; // greater-equal-ish logic handled via inversion

            // Determine pctl search mode
            // "rebinning" method in python logic:
            // if ("g" in comparison and index_mode == "precision") or ("l" in comparison and index_mode == "recall"):
            //     bin_mode = 1
            let mut bin_offset = 0;

            if (is_greater && mode_precision) || (is_less && mode_recall) {
                 bin_offset = 1;
            }

            // Iterate over all clusters (Contiguous memory access pattern!)
            for i in 0..index.n_clusters() {
                let bins = index.get_bins(i);

                // 1. Check if reference is in range of this cluster
                if *reference as f64 >= bins[0] && *reference as f64 <= *bins.last().unwrap() {
                    // Binary search key to find bin index
                    // equivalent to np.searchsorted(bins, reference, "left") - 1
                    let search_idx = match bins.binary_search_by(|v| v.partial_cmp(&(reference)).unwrap()) {
                        Ok(idx) => idx, // Exact match
                        Err(idx) => idx, // Insertion point
                    };

                    // Python logic: np.clip(np.searchsorted(..., 'left') - 1, 0, len-1)
                    // If Ok(idx), it means bins[idx] == ref. searchsorted 'left' returns idx. -1 => idx-1.
                    // If Err(idx), it means bins[idx-1] < ref < bins[idx]. searchsorted 'left' returns idx. -1 => idx-1.

                    // The standard algorithm for "bin index" of value X is usually finding the upper_bound - 1.

                    let mut bin_idx = if search_idx > 0 { search_idx - 1 } else { 0 };
                    if bin_idx >= bins.len() - 1 {
                        bin_idx = bins.len() - 2; // Last bin is usually len-1 size
                    }

                    // Apply offset logic from Python
                    let final_bin_idx = (bin_idx as isize + bin_offset) as usize;

                    // If the offset pushes us out of bounds, handle gracefully?
                    // Python clips BEFORE adding offset? No, python logic:
                    // clip(search - 1, 0, len-1) + bin_mode.
                    // So we can index out of bounds if we aren't careful.
                    // But in rebinning, we usually have n_bins in data = n_bins_edges - 1.
                    // Wait, RebinningIndex logic: n_bins data = n_bin_edges or n_bin_edges-1?
                    // Usually histogram values have 1 fewer element than edges.

                    // Let's assume valid access for now or check bounds.
                    // Data layout: [bin0_h0, bin0_h1... | bin1_h0...]
                    let n_hists = index.get_cluster_size(i);
                    let vals = index.get_values(i);
                    let ids = index.get_indices(i);

                    // Calculate start/end of the column for this bin
                    // Each bin column has n_hists elements.
                    let col_start = final_bin_idx * n_hists;
                    let col_end = col_start + n_hists;

                    if col_start < vals.len() {
                        let val_col = &vals[col_start..col_end];
                        let id_col = &ids[col_start..col_end];

                        // Search in the sorted percentile column
                        // Python: np.searchsorted(col, percentile, side)
                        if is_less {
                            // "l" -> side="left"
                            let h_idx = val_col.partition_point(|&x| x < final_pctl);
                            // All elements >= h_idx match?
                            // Logic: pctl_index stores percentiles.
                            // query < reference.
                            // Python: matches.update(ids[hist_index:])
                            for k in h_idx..n_hists {
                                query_matches.insert(id_col[k]);
                            }
                        } else {
                            // "g" -> side="right"
                            let h_idx = val_col.partition_point(|&x| x <= final_pctl);
                            // Python: matches.update(ids[:hist_index])
                            for k in 0..h_idx {
                                query_matches.insert(id_col[k]);
                            }
                        }
                    }

                } else {
                    // Reference value not in cluster range
                    // Skip logic (Optimization)
                     let bins = index.get_bins(i);
                     if (*reference as f64 <= bins[0] && is_greater) || (*reference as f64 >= *bins.last().unwrap() && is_less) {
                         // Full Match for this cluster
                         // Add all IDs
                        let ids = index.get_indices(i);
                        // Accessing the *first* column of IDs is sufficient since IDs are same row-wise?
                        // Wait, IDs array is (n_hists, n_bins).
                        // In Python we did: pctl_index[i][pctl_mode][1][:, 0]
                        // So we take the first column of IDs.
                        // Ideally, we should have a separate list of IDs for the cluster if they are constant?
                        // But if binsort/rebinning shuffles them, they might differ per bin?
                        // Rebinning (Index) usually assumes fixed IDs per cluster?
                        // Let's assume we take the first n_hists entries.
                        let n_hists = index.get_cluster_size(i);
                         for k in 0..n_hists {
                             query_matches.insert(ids[k]);
                         }
                     }
                }
            }

            query_matches.into_iter().collect()
        })
        .collect();

    Ok(results)
}
