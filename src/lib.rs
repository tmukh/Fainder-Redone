use pyo3::prelude::*;

mod engine;
mod index;
#[cfg(feature = "simd")]
mod simd_search;

/// fainder-core: High-performance execution engine for Fainder.
#[pymodule]
fn fainder_core(m: &Bound<'_, PyModule>) -> PyResult<()> {
    m.add_class::<index::FainderIndex>()?;
    Ok(())
}
