use pyo3::prelude::*;

// Replace glibc malloc with mimalloc for the entire fainder_core extension.
// mimalloc uses per-thread sharded free lists, eliminating the central-arena
// mutex contention that glibc's ptmalloc hits when many Rayon workers grow
// per-query Vec<u32> output buffers simultaneously.
#[cfg(feature = "mimalloc")]
#[global_allocator]
static GLOBAL: mimalloc::MiMalloc = mimalloc::MiMalloc;

mod engine;
mod index;
mod rebinning;
#[cfg(feature = "simd")]
mod simd_search;
#[cfg(feature = "horizontal-simd")]
mod horizontal_simd;
#[cfg(feature = "pgm")]
mod pgm;
#[cfg(any(feature = "packed-ids", feature = "local-ids", feature = "local-ids-bench", feature = "local-ids-noalloc"))]
pub mod packed;

/// fainder-core: High-performance execution engine for Fainder.
#[pymodule]
fn fainder_core(m: &Bound<'_, PyModule>) -> PyResult<()> {
    m.add_class::<index::FainderIndex>()?;
    m.add_function(wrap_pyfunction!(rebinning::build_rebinning_index_cluster, m)?)?;
    Ok(())
}
