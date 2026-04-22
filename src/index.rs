use numpy::{PyReadonlyArray1, PyReadonlyArray2};
use pyo3::prelude::*;
#[cfg(feature = "f16")]
use half::f16;

// ── SubIndex: two layouts controlled by Cargo feature flag ───────────────────
//
// SoA (default): separate contiguous arrays for values and indices.
//   Binary search over values[] touches only f32 elements → cache line holds 16
//   values → prefetcher loads ahead predictively.
//
// AoS (--features aos): interleaved (value, index) pairs.
//   Binary search must step over 8-byte pairs → each cache line holds only 8
//   useful f32 values (the other 4 bytes per entry are index data). This is the
//   control condition for the memory-layout ablation.

#[cfg(not(any(feature = "aos", feature = "f16", feature = "eytzinger")))]
pub struct SubIndex {
    /// Column-major flattened percentile values: [bin0·hist0, bin0·hist1, …, bin1·hist0, …]
    pub values: Vec<f32>,
    /// Column-major flattened histogram ids, same layout as values
    pub indices: Vec<u32>,
}

#[cfg(not(any(feature = "aos", feature = "f16", feature = "eytzinger")))]
impl SubIndex {
    #[inline]
    pub fn len(&self) -> usize { self.values.len() }
}

// f16 variant: values stored as half-precision to halve the index memory footprint.
// Binary search dequantizes on the fly (one instruction per comparison).
#[cfg(all(feature = "f16", not(feature = "aos"), not(feature = "eytzinger")))]
pub struct SubIndex {
    /// Column-major flattened percentile values stored as f16 (half precision)
    pub values: Vec<f16>,
    /// Column-major flattened histogram ids, same layout as values
    pub indices: Vec<u32>,
}

#[cfg(all(feature = "f16", not(feature = "aos"), not(feature = "eytzinger")))]
impl SubIndex {
    #[inline]
    pub fn len(&self) -> usize { self.values.len() }
}

#[cfg(feature = "aos")]
pub struct SubIndex {
    /// Column-major flattened (value, index) pairs: [(bin0·hist0_val, id), (bin0·hist1_val, id), …]
    pub entries: Vec<(f32, u32)>,
}

#[cfg(feature = "aos")]
impl SubIndex {
    #[inline]
    pub fn len(&self) -> usize { self.entries.len() }
}

// Eytzinger layout: values stored in BFS (breadth-first) order per column.
//
// Standard sorted binary search accesses positions n/2, n/4, 3n/4, … in the sorted array —
// unpredictable jumps that defeat hardware prefetching. Eytzinger reorders elements so
// that the binary search visits contiguous indices: root at 1, its children at 2–3, then
// 4–7, etc. The first 4 levels (15 elements = 60 bytes) fit in a single cache line,
// allowing the hardware prefetcher to read ahead predictively.
//
// We pair eyt_values (BFS-ordered for fast search) with inv_perm (maps BFS index → sorted
// position) and sorted_ids (histogram IDs in sorted order for result collection).
// Memory: 12 bytes/element vs 8 for SoA — 50% overhead for the prefetch benefit.
#[cfg(feature = "eytzinger")]
pub struct SubIndex {
    /// BFS-ordered percentile values per column: eyt[j-1] = element at BFS position j (1-indexed)
    pub eyt_values: Vec<f32>,
    /// Maps BFS index (0-based) → sorted position: inv_perm[j-1] = sorted rank of eyt[j]
    pub inv_perm: Vec<u32>,
    /// Histogram IDs in sorted order per column (for result collection after search)
    pub sorted_ids: Vec<u32>,
}

#[cfg(feature = "eytzinger")]
impl SubIndex {
    #[inline]
    pub fn len(&self) -> usize { self.eyt_values.len() }
}

// ─────────────────────────────────────────────────────────────────────────────

/// Recursively build a 1-indexed Eytzinger (BFS) layout from a sorted slice.
/// `i` is the current BFS position (1-based), `k` tracks the in-order position.
/// On return, `eyt[i-1]` holds the sorted element at the current in-order step,
/// and `perm[i-1]` records its sorted index.
#[cfg(feature = "eytzinger")]
fn eytzinger_rec(sorted: &[f32], eyt: &mut [f32], perm: &mut [u32], i: usize, k: &mut usize) {
    if i > sorted.len() { return; }
    eytzinger_rec(sorted, eyt, perm, 2 * i, k);
    eyt[i - 1]  = sorted[*k];
    perm[i - 1] = *k as u32;
    *k += 1;
    eytzinger_rec(sorted, eyt, perm, 2 * i + 1, k);
}

#[pyclass]
pub struct FainderIndex {
    cluster_sizes: Vec<usize>,
    bins: Vec<Vec<f64>>,
    variants: Vec<Vec<SubIndex>>,
}

#[pymethods]
impl FainderIndex {
    #[new]
    pub fn new(
        pctl_index: &Bound<'_, pyo3::types::PyList>,
        cluster_bins: Vec<PyReadonlyArray1<f64>>,
    ) -> PyResult<Self> {
        let n_clusters = pctl_index.len();

        if cluster_bins.len() != n_clusters {
            return Err(pyo3::exceptions::PyValueError::new_err("Bins length mismatch"));
        }

        let mut bins_data: Vec<Vec<f64>> = Vec::with_capacity(n_clusters);
        for b in cluster_bins {
            bins_data.push(b.as_array().iter().copied().collect());
        }

        let mut cluster_sizes: Vec<usize> = Vec::with_capacity(n_clusters);
        let mut all_variants: Vec<Vec<SubIndex>> = Vec::with_capacity(n_clusters);

        for (cluster_idx, cluster_item) in pctl_index.iter().enumerate() {
            let variants_list = cluster_item
                .downcast::<pyo3::types::PyList>()
                .map_err(|_| pyo3::exceptions::PyTypeError::new_err("Expected list of variants"))?;

            let mut cluster_subindices: Vec<SubIndex> = Vec::with_capacity(variants_list.len());
            let mut expected_n_hists = 0usize;
            let mut first = true;

            for variant_item in variants_list.iter() {
                let tuple = variant_item
                    .downcast::<pyo3::types::PyTuple>()
                    .map_err(|_| {
                        pyo3::exceptions::PyTypeError::new_err("Expected tuple(FArray, UInt32Array)")
                    })?;

                let p_array = tuple.get_item(0)?.extract::<PyReadonlyArray2<f32>>()?;
                let i_array = tuple.get_item(1)?.extract::<PyReadonlyArray2<u32>>()?;

                let p   = p_array.as_array();
                let ids = i_array.as_array();

                let n_hists = p.shape()[0];
                let n_bins  = p.shape()[1];

                if first {
                    expected_n_hists = n_hists;
                    cluster_sizes.push(n_hists);
                    first = false;
                } else if n_hists != expected_n_hists {
                    return Err(pyo3::exceptions::PyValueError::new_err(format!(
                        "Variant n_hists mismatch in cluster {}", cluster_idx
                    )));
                }

                if ids.shape()[0] != n_hists || ids.shape()[1] != n_bins {
                    return Err(pyo3::exceptions::PyValueError::new_err(
                        "pctl_index arrays shape mismatch within variant",
                    ));
                }

                // ── OPTIMIZATION: Column-Major Memory Flattening ──────────────
                // We flatten [n_hists][n_bins] in column-major order so that
                // for a given bin_idx the slice [offset .. offset+n_hists] is
                // contiguous in memory. This matches the query hot-loop access
                // pattern and lets the CPU prefetcher work predictively.
                //
                // SoA: values and indices stored in separate arrays.
                //   → binary search over values[] sees only f32 elements.
                //
                // AoS: (value, index) pairs interleaved.
                //   → binary search sees 8-byte pairs; index data pollutes
                //     cache lines during the search phase. (ablation control)

                #[cfg(not(any(feature = "aos", feature = "f16", feature = "eytzinger")))]
                {
                    let mut val_vec: Vec<f32> = Vec::with_capacity(n_hists * n_bins);
                    let mut idx_vec: Vec<u32> = Vec::with_capacity(n_hists * n_bins);
                    for b in 0..n_bins {
                        for h in 0..n_hists {
                            val_vec.push(p[[h, b]]);
                            idx_vec.push(ids[[h, b]]);
                        }
                    }
                    cluster_subindices.push(SubIndex { values: val_vec, indices: idx_vec });
                }

                #[cfg(all(feature = "f16", not(feature = "aos"), not(feature = "eytzinger")))]
                {
                    let mut val_vec: Vec<f16> = Vec::with_capacity(n_hists * n_bins);
                    let mut idx_vec: Vec<u32> = Vec::with_capacity(n_hists * n_bins);
                    for b in 0..n_bins {
                        for h in 0..n_hists {
                            val_vec.push(f16::from_f32(p[[h, b]]));
                            idx_vec.push(ids[[h, b]]);
                        }
                    }
                    cluster_subindices.push(SubIndex { values: val_vec, indices: idx_vec });
                }

                #[cfg(feature = "aos")]
                {
                    let mut entries: Vec<(f32, u32)> = Vec::with_capacity(n_hists * n_bins);
                    for b in 0..n_bins {
                        for h in 0..n_hists {
                            entries.push((p[[h, b]], ids[[h, b]]));
                        }
                    }
                    cluster_subindices.push(SubIndex { entries });
                }

                #[cfg(all(feature = "eytzinger", not(feature = "aos")))]
                {
                    let mut eyt_vec:  Vec<f32> = Vec::with_capacity(n_hists * n_bins);
                    let mut perm_vec: Vec<u32> = Vec::with_capacity(n_hists * n_bins);
                    let mut idx_vec:  Vec<u32> = Vec::with_capacity(n_hists * n_bins);
                    for b in 0..n_bins {
                        // Extract the sorted column (pctl_index is already sorted per column)
                        let col_vals: Vec<f32> = (0..n_hists).map(|h| p[[h, b]]).collect();
                        let col_ids:  Vec<u32> = (0..n_hists).map(|h| ids[[h, b]]).collect();
                        // Permute values into BFS order; record sorted-position for each BFS slot
                        let mut eyt_col  = vec![0.0f32; n_hists];
                        let mut perm_col = vec![0u32;   n_hists];
                        let mut k = 0usize;
                        eytzinger_rec(&col_vals, &mut eyt_col, &mut perm_col, 1, &mut k);
                        eyt_vec.extend_from_slice(&eyt_col);
                        perm_vec.extend_from_slice(&perm_col);
                        idx_vec.extend_from_slice(&col_ids);
                    }
                    cluster_subindices.push(SubIndex {
                        eyt_values: eyt_vec,
                        inv_perm:   perm_vec,
                        sorted_ids: idx_vec,
                    });
                }
            }
            all_variants.push(cluster_subindices);
        }

        Ok(Self { cluster_sizes, bins: bins_data, variants: all_variants })
    }

    #[pyo3(signature = (queries, index_mode, num_threads=None, columnar=false, suppress_results=false))]
    pub fn run_queries<'py>(
        &self,
        py: Python<'py>,
        queries: Vec<(f32, String, f64)>,
        index_mode: &str,
        num_threads: Option<usize>,
        columnar: bool,
        suppress_results: bool,
    ) -> PyResult<Vec<PyObject>> {
        crate::engine::execute_queries(py, self, queries, index_mode, num_threads, columnar, suppress_results)
    }
}

impl FainderIndex {
    #[inline] pub fn get_bins(&self, c: usize) -> &[f64] { &self.bins[c] }
    #[inline] pub fn get_subindex(&self, c: usize, v: usize) -> Option<&SubIndex> {
        self.variants.get(c)?.get(v)
    }
    #[inline] pub fn n_clusters(&self) -> usize { self.bins.len() }
    #[inline] pub fn get_cluster_size(&self, c: usize) -> usize { self.cluster_sizes[c] }
}
