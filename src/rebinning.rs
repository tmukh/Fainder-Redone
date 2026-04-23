// Rust port of fainder.preprocessing.percentile_index (continuous_value mode only).
//
// Python original:
//   rebin_collection   — Pool.map() over histograms, pickle between processes
//   create_rebinning_index — cumsum + argsort + apply, Python/NumPy
//
// Rust:
//   build_rebinning_index_cluster — Rayon par_iter over histograms, single process,
//                                   zero IPC overhead; cumsum + sort in-process.
//
// The function processes ONE cluster at a time.  Python calls it in a loop over
// clusters (57 iterations for eval_medium).  Within each call the GIL is released
// during both the parallel rebinning phase and the sort phase.

use ndarray::{Array2, ShapeBuilder};
use numpy::{IntoPyArray, PyArray2, PyReadonlyArray1, NotContiguousError};
use pyo3::prelude::*;
use rayon::prelude::*;

/// Rebin one histogram from `old_bins` edges into `new_bins` edges.
///
/// Implements the "continuous_value" approximation: density is assumed uniform
/// within each old bin, so the fraction of a bin's value assigned to a new bin
/// equals the length-overlap / old-bin-width.
///
/// Returns a Vec<f32> of length `new_bins.len() - 1`.
fn rebin_histogram(values: &[f32], old_bins: &[f64], new_bins: &[f64]) -> Vec<f32> {
    let n_new = new_bins.len() - 1;
    let mut out = vec![0f32; n_new];

    for (i, &val) in values.iter().enumerate() {
        if val == 0.0f32 {
            continue;
        }
        let lo = old_bins[i];
        let hi = old_bins[i + 1];
        let width = hi - lo;
        if width <= 0.0 {
            continue;
        }

        // searchsorted(new_bins, lo, side='right') - 1
        // = last edge index where edge <= lo
        let start = new_bins.partition_point(|&x| x <= lo).saturating_sub(1);
        // searchsorted(new_bins, hi, side='left')
        // = first edge index where edge >= hi → = first bin j where new_bins[j] >= hi
        // We cap at n_new so bin j+1 is always valid.
        let end = new_bins.partition_point(|&x| x < hi).min(n_new);

        for j in start..end {
            let new_lo = new_bins[j];
            let new_hi = new_bins[j + 1];
            let olo = lo.max(new_lo);
            let ohi = hi.min(new_hi);
            if olo >= ohi {
                continue;
            }
            let fraction = (ohi - olo) / width;
            out[j] += (fraction * val as f64) as f32;
        }
    }
    out
}

/// Build the rebinning percentile index for a single cluster.
///
/// Equivalent to calling `rebin_collection` (parallel) then
/// `create_rebinning_index` (cumsum + sort) for one cluster.
///
/// # Arguments
/// * `ids`            — histogram IDs, shape (n_hists,)
/// * `hist_values`    — list of n_hists arrays, each shape (n_old_bins_i,), dtype f32
/// * `hist_bin_edges` — list of n_hists arrays, each shape (n_old_bins_i+1,), dtype f64
/// * `new_bins`       — cluster bin edges, shape (n_new_bins+1,), dtype f64
/// * `rounding_precision` — decimal places for cumsum rounding (typically 4)
///
/// # Returns
/// `(pctls, ids_out)` — two numpy arrays of shape `(n_hists, n_new_bins+1)`,
/// Fortran memory order, matching the output of `create_rebinning_index`.
#[pyfunction]
pub fn build_rebinning_index_cluster<'py>(
    py: Python<'py>,
    ids: Vec<u32>,
    hist_values: Vec<PyReadonlyArray1<'py, f32>>,
    hist_bin_edges: Vec<PyReadonlyArray1<'py, f64>>,
    new_bins: PyReadonlyArray1<'py, f64>,
    rounding_precision: i32,
) -> PyResult<(Py<PyArray2<f32>>, Py<PyArray2<u32>>)> {
    let n_hists = ids.len();
    // n_cols = n_new_bins + 1 (first col is always 0; last = cumsum up to final edge)
    let new_bins_slice = new_bins.as_slice()?;
    let n_cols = new_bins_slice.len(); // = n_new_bins + 1

    // Extract contiguous slices from numpy arrays while GIL is held.
    // We copy to owned Vec so Rayon workers don't need the GIL.
    let vals_data: Vec<Vec<f32>> = hist_values
        .iter()
        .map(|a| -> Result<Vec<f32>, NotContiguousError> { a.as_slice().map(|s| s.to_vec()) })
        .collect::<Result<_, _>>()
        .map_err(|e| pyo3::exceptions::PyValueError::new_err(format!("non-contiguous hist_values array: {e}")))?;
    let bins_data: Vec<Vec<f64>> = hist_bin_edges
        .iter()
        .map(|a| -> Result<Vec<f64>, NotContiguousError> { a.as_slice().map(|s| s.to_vec()) })
        .collect::<Result<_, _>>()
        .map_err(|e| pyo3::exceptions::PyValueError::new_err(format!("non-contiguous hist_bin_edges array: {e}")))?;
    let new_bins_vec: Vec<f64> = new_bins_slice.to_vec();
    let ids_vec = ids; // already owned

    // ── Phase 1: parallel rebinning (GIL released) ────────────────────────────
    let rebinned: Vec<Vec<f32>> = py.allow_threads(|| {
        (0..n_hists)
            .into_par_iter()
            .map(|i| rebin_histogram(&vals_data[i], &bins_data[i], &new_bins_vec))
            .collect()
    });

    // ── Phase 2: cumsum + sort (GIL still released — pure Rust) ──────────────
    // We store (pctls, sort_ids) in Fortran order: element (h, k) → index k*n_hists+h.
    let round_factor = 10f64.powi(rounding_precision);
    let mut pctls_flat = vec![0f32; n_hists * n_cols];
    let mut out_ids_flat = vec![0u32; n_hists * n_cols];

    // Fill col 0 (all zeros for pctls) and broadcast histogram ID across all cols.
    for h in 0..n_hists {
        let id = ids_vec[h];
        let row = &rebinned[h];
        let mut cum = 0.0f64;
        out_ids_flat[h] = id; // col 0
        for k in 0..row.len() {
            cum += row[k] as f64;
            let rounded = (cum * round_factor).round() / round_factor;
            // Fortran index for (h, k+1): (k+1)*n_hists + h
            pctls_flat[(k + 1) * n_hists + h] = rounded as f32;
            out_ids_flat[(k + 1) * n_hists + h] = id;
        }
    }

    // Stable sort each column by pctls value independently.
    // Matches: sort_indices = np.argsort(pctls, axis=0, kind='stable')
    //           pctls = np.take_along_axis(pctls, sort_indices, axis=0)
    //           ids   = np.take_along_axis(ids,   sort_indices, axis=0)
    for k in 0..n_cols {
        let col = k * n_hists;
        let pctls_col  = &mut pctls_flat[col..col + n_hists];
        let ids_col    = &mut out_ids_flat[col..col + n_hists];

        // Sort (pctls, id) pairs stably by pctls value.
        let mut pairs: Vec<(f32, u32)> = pctls_col
            .iter()
            .zip(ids_col.iter())
            .map(|(&p, &i)| (p, i))
            .collect();
        pairs.sort_by(|a, b| a.0.partial_cmp(&b.0).unwrap_or(std::cmp::Ordering::Equal));
        for (j, (p, i)) in pairs.into_iter().enumerate() {
            pctls_col[j] = p;
            ids_col[j] = i;
        }
    }

    // ── Phase 3: wrap as Fortran-order numpy arrays ───────────────────────────
    // ndarray ShapeBuilder: (rows, cols).f() creates column-major (Fortran) layout.
    let shape_f = (n_hists, n_cols).f();
    let pctls_nd: Array2<f32> = Array2::from_shape_vec(shape_f, pctls_flat)
        .map_err(|e| pyo3::exceptions::PyValueError::new_err(e.to_string()))?;
    let shape_f2 = (n_hists, n_cols).f();
    let ids_nd: Array2<u32> = Array2::from_shape_vec(shape_f2, out_ids_flat)
        .map_err(|e| pyo3::exceptions::PyValueError::new_err(e.to_string()))?;

    Ok((
        pctls_nd.into_pyarray_bound(py).unbind(),
        ids_nd.into_pyarray_bound(py).unbind(),
    ))
}
