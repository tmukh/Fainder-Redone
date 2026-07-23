use crate::index::FainderIndex;
use numpy::IntoPyArray;
use pyo3::prelude::*;

mod search;
mod types;
#[cfg(not(feature = "aos"))]
mod routing;
mod row_centric;
#[cfg(not(feature = "aos"))]
mod columnar;
#[cfg(all(feature = "query-batch", not(feature = "aos")))]
mod query_batched;
#[cfg(all(feature = "morsel", not(feature = "aos"), not(feature = "f16"), not(feature = "pgm")))]
mod morsel;

use types::{IndexMode, Comparison, TypedQuery};
use row_centric::execute_row_centric;
#[cfg(not(feature = "aos"))]
use columnar::execute_columnar;
#[cfg(all(feature = "query-batch", not(feature = "aos")))]
use query_batched::execute_query_batched;
#[cfg(all(feature = "morsel", not(feature = "aos"), not(feature = "f16"), not(feature = "pgm")))]
use morsel::execute_morsel;

// `batch-search` and `horizontal-simd` both gate code paths inside the
// columnar engine on the same `group` of queries. Enabling both would
// double-execute every query, appending each query's result IDs to the
// cluster buffer twice. Forbid the combination.
#[cfg(all(feature = "batch-search", feature = "horizontal-simd"))]
compile_error!("features `batch-search` and `horizontal-simd` are mutually exclusive; enable at most one");

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

    // Build the Rayon thread pool. With --features pin-cores, also pin each
    // worker to a distinct physical core via core_affinity, avoiding SMT-sibling
    // co-location that otherwise lets two workers fight for one core's L1/L2.
    // Linux's default scheduler does not enforce physical-core uniqueness for
    // CPU-bound threads, so the +15.4% NUMA-pinning win at t=64 is partly an
    // artefact of node-level pinning happening to also separate SMT pairs.
    #[cfg(not(feature = "pin-cores"))]
    let pool = rayon::ThreadPoolBuilder::new()
        .num_threads(num_threads.unwrap_or(0))
        .build()
        .map_err(|e| pyo3::exceptions::PyRuntimeError::new_err(e.to_string()))?;

    #[cfg(feature = "pin-cores")]
    let pool = {
        // Sapphire Rapids 8468H: 96 physical cores across 2 NUMA sockets,
        // 192 logical (HT). Linux numbering on this box:
        //   logical 0..47   = physical cores on socket 0
        //   logical 48..95  = physical cores on socket 1
        //   logical 96..191 = HT siblings (in the same order)
        //
        // Pinning strategy:
        //   1) want ≤ 48: pin worker k → physical core k on socket 0 only.
        //      No SMT-sibling sharing, no cross-NUMA traffic. Best for
        //      single-socket scaling.
        //   2) 48 < want ≤ 96: pin workers across BOTH sockets, alternating
        //      socket per worker so workers fill socket 0 and socket 1
        //      symmetrically. Cross-socket loads will hit when index data
        //      lives on one socket — this is unavoidable above 48 threads
        //      and pinning still beats letting the scheduler migrate
        //      workers (which causes cache thrash).
        //   3) want > 96: necessarily uses HT siblings. We don't pin in this
        //      regime; HT siblings sharing one core's L1/L2 makes a static
        //      pin strictly worse than letting the OS load-balance.
        let want = num_threads.unwrap_or(0);
        let mut builder = rayon::ThreadPoolBuilder::new().num_threads(want);
        if want > 0 && want <= 96 {
            let core_ids = core_affinity::get_core_ids().unwrap_or_default();
            let plan: Vec<core_affinity::CoreId> = if want <= 48 {
                // Socket 0 physical cores only.
                core_ids.iter().filter(|c| c.id < 48).copied().collect()
            } else {
                // Interleave across sockets: worker k → physical core
                //   (k/2) on socket 0 if k even,
                //   (48 + k/2) on socket 1 if k odd.
                // This balances workers symmetrically across both sockets
                // for any 48 < want ≤ 96.
                let mut p: Vec<core_affinity::CoreId> = Vec::with_capacity(want);
                for k in 0..want {
                    let target_id = if k % 2 == 0 { k / 2 } else { 48 + (k - 1) / 2 };
                    if let Some(c) = core_ids.iter().find(|c| c.id == target_id) {
                        p.push(*c);
                    }
                }
                p
            };
            let plan = std::sync::Arc::new(plan);
            builder = builder.start_handler({
                let plan = plan.clone();
                move |idx| {
                    if let Some(core) = plan.get(idx) {
                        core_affinity::set_for_current(*core);
                    }
                }
            });
        }
        builder.build()
            .map_err(|e| pyo3::exceptions::PyRuntimeError::new_err(e.to_string()))?
    };

    let n_clusters    = index.n_clusters();
    let is_conversion = n_clusters > 0 && index.get_subindex(0, 1).is_some();

    let results: Vec<Vec<u32>> = if columnar {
        // Column-centric: only implemented for SoA (f32 and f16).
        // Falls back to row-centric for aos variant.
        #[cfg(not(feature = "aos"))]
        { execute_columnar(&typed_queries, index, index_mode, is_conversion, &pool, suppress_results) }
        #[cfg(feature = "aos")]
        { execute_row_centric(&typed_queries, index, index_mode, is_conversion, &pool) }
    } else {
        // Default (non-columnar): morsel scheduler > query-batch > row-centric,
        // chosen by Cargo features at build time. Only one of (morsel,
        // query-batch) is normally enabled per build.
        #[cfg(all(feature = "morsel", not(feature = "aos"), not(feature = "f16"), not(feature = "pgm")))]
        { execute_morsel(&typed_queries, index, index_mode, is_conversion, &pool, suppress_results) }
        #[cfg(all(feature = "query-batch", not(feature = "aos"), not(all(feature = "morsel", not(feature = "f16"), not(feature = "pgm")))))]
        { execute_query_batched(&typed_queries, index, index_mode, is_conversion, &pool) }
        #[cfg(not(any(
            all(feature = "morsel", not(feature = "aos"), not(feature = "f16"), not(feature = "pgm")),
            all(feature = "query-batch", not(feature = "aos")),
        )))]
        { execute_row_centric(&typed_queries, index, index_mode, is_conversion, &pool) }
    };

    let mut py_results: Vec<PyObject> = Vec::with_capacity(results.len());
    for res in results {
        let arr = res.into_pyarray_bound(py);
        py_results.push(arr.to_object(py));
    }
    Ok(py_results)
}
