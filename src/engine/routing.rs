use crate::index::FainderIndex;
use super::types::{Comparison, IndexMode, TypedQuery};

// ── Per-(query, cluster) routing: precomputed to separate the cheap arithmetic
// from the expensive binary search. Stored as a flat array [q * n_c + c].
#[derive(Clone, Copy)]
pub(super) enum Route {
    // Query's ref_val is outside cluster range in the wrong direction — skip.
    Pruned,
    // Query trivially matches the entire cluster (ref outside range, right direction).
    TriviallyAll { pctl_mode: usize },
    // Normal: binary search on the given (pctl_mode, bin_idx) column.
    Search { pctl_mode: usize, bin_idx: usize, target: f32, is_gt: bool },
}

pub(super) fn compute_route(
    q: &TypedQuery,
    index: &FainderIndex,
    c: usize,
    index_mode: IndexMode,
    is_conversion: bool,
) -> Route {
    let bins = index.get_bins(c);
    if bins.len() < 2 { return Route::Pruned; }

    let (eff_percentile, is_gt) = match q.comparison {
        Comparison::Gt | Comparison::Ge => (1.0 - q.percentile, true),
        _ => (q.percentile, false),
    };
    let condition  = (is_gt && index_mode == IndexMode::Precision)
                  || (!is_gt && index_mode == IndexMode::Recall);
    let bin_mode   = if condition && !is_conversion { 1 } else { 0 };
    let pctl_mode  = if condition &&  is_conversion { 1 } else { 0 };
    let ref_val    = q.reference;

    if ref_val < bins[0] || ref_val > bins[bins.len() - 1] {
        let trivially_all = (ref_val < bins[0] && is_gt)
                         || (ref_val > bins[bins.len() - 1] && !is_gt);
        return if trivially_all {
            Route::TriviallyAll { pctl_mode }
        } else {
            Route::Pruned
        };
    }

    let pp      = bins.partition_point(|&x| x < ref_val);
    let raw_idx = if pp == 0 { 0 } else { pp - 1 };
    let bin_idx = (raw_idx + bin_mode).min(bins.len() - 1);

    Route::Search { pctl_mode, bin_idx, target: eff_percentile, is_gt }
}
