use numpy::{PyReadonlyArray1, PyReadonlyArray2};
use pyo3::prelude::*;

#[pyclass]
pub struct RebinningIndex {
    // sizes[i] = number of histograms in cluster i
    cluster_sizes: Vec<usize>,

    // bins[i] = bin edges for cluster i (1D)
    bins: Vec<Vec<f64>>,

    // values[i] = column-major flattened percentile matrix for cluster i
    // Layout: [bin0 all hists, bin1 all hists, ...]
    cluster_values: Vec<Vec<f32>>,

    // indices[i] = column-major flattened ids matrix for cluster i
    cluster_indices: Vec<Vec<u32>>,
}

#[pymethods]
impl RebinningIndex {
    #[new]
    pub fn new(
        pctl_index: Vec<(PyReadonlyArray2<f32>, PyReadonlyArray2<u32>)>,
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

        // Copy + transpose to column-major layout for cache-friendly bin access
        let mut cluster_values: Vec<Vec<f32>> = Vec::with_capacity(n_clusters);
        let mut cluster_indices: Vec<Vec<u32>> = Vec::with_capacity(n_clusters);
        let mut cluster_sizes: Vec<usize> = Vec::with_capacity(n_clusters);

        for (p_array, i_array) in pctl_index {
            let p = p_array.as_array();   // ArrayView2<f32>
            let ids = i_array.as_array(); // ArrayView2<u32>

            let n_hists = p.shape()[0];
            let n_bins = p.shape()[1];

            // Basic sanity check: ids must match shape
            if ids.shape()[0] != n_hists || ids.shape()[1] != n_bins {
                return Err(pyo3::exceptions::PyValueError::new_err(
                    "pctl_index arrays shape mismatch",
                ));
            }

            cluster_sizes.push(n_hists);

            let mut val_vec: Vec<f32> = Vec::with_capacity(n_hists * n_bins);
            let mut idx_vec: Vec<u32> = Vec::with_capacity(n_hists * n_bins);

            // column-major flatten: for each bin, iterate all hists
            for b in 0..n_bins {
                for h in 0..n_hists {
                    val_vec.push(p[[h, b]]);
                    idx_vec.push(ids[[h, b]]);
                }
            }

            cluster_values.push(val_vec);
            cluster_indices.push(idx_vec);
        }

        Ok(Self {
            cluster_sizes,
            bins: bins_data,
            cluster_values,
            cluster_indices,
        })
    }

    pub fn run_queries(
        &self,
        queries: Vec<(f32, String, f64)>,
        index_mode: &str,
    ) -> PyResult<Vec<Vec<u32>>> {
        crate::engine::execute_queries(self, queries, index_mode)
    }
}

impl RebinningIndex {
    #[inline]
    pub fn get_bins(&self, cluster_idx: usize) -> &[f64] {
        &self.bins[cluster_idx]
    }

    #[inline]
    pub fn get_values(&self, cluster_idx: usize) -> &[f32] {
        &self.cluster_values[cluster_idx]
    }

    #[inline]
    pub fn get_indices(&self, cluster_idx: usize) -> &[u32] {
        &self.cluster_indices[cluster_idx]
    }

    #[inline]
    pub fn get_cluster_size(&self, cluster_idx: usize) -> usize {
        self.cluster_sizes[cluster_idx]
    }

    #[inline]
    pub fn n_clusters(&self) -> usize {
        self.bins.len()
    }
}
