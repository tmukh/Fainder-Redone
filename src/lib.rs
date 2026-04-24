use pyo3::prelude::*;

mod engine;
mod index;
mod rebinning;
#[cfg(feature = "simd")]
mod simd_search;
#[cfg(feature = "kary")]
mod kary_search;

/// fainder-core: High-performance execution engine for Fainder.
#[pymodule]
fn fainder_core(m: &Bound<'_, PyModule>) -> PyResult<()> {
    m.add_class::<index::FainderIndex>()?;
    m.add_function(wrap_pyfunction!(rebinning::build_rebinning_index_cluster, m)?)?;
    Ok(())
}
