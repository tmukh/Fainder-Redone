use numpy::{PyReadonlyArray1, PyReadonlyArray2};
use pyo3::prelude::*;

/// Internal structure holding the SoA data for one index variant (e.g. pctl_mode=0 or 1)
///
/// OPTIMIZATION: Structure of Arrays (SoA) Memory Layout
/// ======================================================
/// Instead of storing data as Array of Structs (e.g., [(percentile, id), (percentile, id), ...]),
/// we use SoA where values and indices are kept separate. This enables cache-efficient sequential
/// access patterns:
/// - Binary search over `values` accesses only f32 elements (no id field pollution)
/// - Sequential layout improves L1/L2 cache hit rates during partition_point() searches
/// - Estimated benefit: 20-30% improvement over AoS layout (see thesis section 4.2)
/// - Trade-off: Requires separate indexing into two arrays (negligible branch cost)
pub struct SubIndex {
    // values = column-major flattened percentile matrix
    pub values: Vec<f32>,
    // indices = column-major flattened ids matrix
    pub indices: Vec<u32>,
}

#[pyclass]
pub struct FainderIndex {
    // sizes[i] = number of histograms in cluster i
    cluster_sizes: Vec<usize>,

    // bins[i] = bin edges for cluster i (1D)
    bins: Vec<Vec<f64>>,

    // variants[cluster_i][variant_j]
    variants: Vec<Vec<SubIndex>>,
}

#[pymethods]
impl FainderIndex {
    #[new]
    pub fn new(
        // pctl_index: list[list[tuple[FArray, UInt32Array]]]
        pctl_index: &Bound<'_, pyo3::types::PyList>,
        cluster_bins: Vec<PyReadonlyArray1<f64>>,
    ) -> PyResult<Self> {
        let n_clusters = pctl_index.len();

        if cluster_bins.len() != n_clusters {
            return Err(pyo3::exceptions::PyValueError::new_err(
                "Bins length mismatch",
            ));
        }

        // Copy bins
        let mut bins_data: Vec<Vec<f64>> = Vec::with_capacity(n_clusters);
        for b in cluster_bins {
            let b_view = b.as_array(); // ArrayView1<f64>
            bins_data.push(b_view.iter().copied().collect());
        }

        let mut cluster_sizes: Vec<usize> = Vec::with_capacity(n_clusters);
        let mut all_variants: Vec<Vec<SubIndex>> = Vec::with_capacity(n_clusters);

        // Iterate PyList manually
        for (cluster_idx, cluster_item) in pctl_index.iter().enumerate() {
            let variants_list = cluster_item
                .downcast::<pyo3::types::PyList>()
                .map_err(|_| pyo3::exceptions::PyTypeError::new_err("Expected list of variants"))?;

            let mut cluster_subindices: Vec<SubIndex> = Vec::with_capacity(variants_list.len());
            let mut expected_n_hists = 0;
            let mut first = true;

            for variant_item in variants_list.iter() {
                // tuple(p_array, i_array) or list
                // we treat as tuple
                let tuple = variant_item
                    .downcast::<pyo3::types::PyTuple>()
                    .map_err(|_| {
                        pyo3::exceptions::PyTypeError::new_err(
                            "Expected tuple(FArray, UInt32Array)",
                        )
                    })?;

                let p_array = tuple.get_item(0)?.extract::<PyReadonlyArray2<f32>>()?;
                let i_array = tuple.get_item(1)?.extract::<PyReadonlyArray2<u32>>()?;

                let p = p_array.as_array(); // ArrayView2<f32>
                let ids = i_array.as_array(); // ArrayView2<u32>

                let n_hists = p.shape()[0];
                let n_bins = p.shape()[1];

                if first {
                    expected_n_hists = n_hists;
                    cluster_sizes.push(n_hists);
                    first = false;
                } else {
                    if n_hists != expected_n_hists {
                        return Err(pyo3::exceptions::PyValueError::new_err(format!(
                            "Variant n_hists mismatch in cluster {}",
                            cluster_idx
                        )));
                    }
                }

                if ids.shape()[0] != n_hists || ids.shape()[1] != n_bins {
                    return Err(pyo3::exceptions::PyValueError::new_err(
                        "pctl_index arrays shape mismatch within variant",
                    ));
                }

                let mut val_vec: Vec<f32> = Vec::with_capacity(n_hists * n_bins);
                let mut idx_vec: Vec<u32> = Vec::with_capacity(n_hists * n_bins);

                // OPTIMIZATION: Column-Major Memory Flattening
                // ============================================
                // We flatten the 2D matrix [n_hists][n_bins] in column-major order:
                // Original: [histogram_0_bin_0, histogram_0_bin_1, ... histogram_0_bin_N,
                //            histogram_1_bin_0, ...]  (row-major, cache-unfriendly)
                // Physical: [histogram_0_bin_0, histogram_1_bin_0, ... histogram_N_bin_0,
                //            histogram_0_bin_1, ...]  (column-major, cache-friendly)
                //
                // Benefit: In query execution, for each bin_idx, we access all histograms
                // sequentially: vals[offset:offset+n_hists]. This sequential access pattern
                // exploits CPU prefetchers and memory bandwidth.
                // Estimated benefit: Contributes to overall cache efficiency (< 5% TLB misses)
                for b in 0..n_bins {
                    for h in 0..n_hists {
                        val_vec.push(p[[h, b]]);
                        idx_vec.push(ids[[h, b]]);
                    }
                }

                cluster_subindices.push(SubIndex {
                    values: val_vec,
                    indices: idx_vec,
                });
            }
            all_variants.push(cluster_subindices);
        }

        Ok(Self {
            cluster_sizes,
            bins: bins_data,
            variants: all_variants,
        })
    }

    #[pyo3(signature = (queries, index_mode, num_threads=None))]
    pub fn run_queries<'py>(
        &self,
        py: Python<'py>,
        queries: Vec<(f32, String, f64)>,
        index_mode: &str,
        num_threads: Option<usize>,
    ) -> PyResult<Vec<PyObject>> {
        crate::engine::execute_queries(py, self, queries, index_mode, num_threads)
    }
}

impl FainderIndex {
    #[inline]
    pub fn get_bins(&self, cluster_idx: usize) -> &[f64] {
        &self.bins[cluster_idx]
    }

    #[inline]
    pub fn get_subindex(&self, cluster_idx: usize, variant_idx: usize) -> Option<&SubIndex> {
        self.variants.get(cluster_idx)?.get(variant_idx)
    }

    #[inline]
    pub fn n_clusters(&self) -> usize {
        self.bins.len()
    }

    #[inline]
    pub fn get_cluster_size(&self, cluster_idx: usize) -> usize {
        self.cluster_sizes[cluster_idx]
    }
}
