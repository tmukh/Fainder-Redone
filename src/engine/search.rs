// ── Partition-point dispatchers ──────────────────────────────────────────────
//
// `do_partition_lt(slice, t)` = first index where slice[i] >= t  (like partition_point(|&x| x < t))
// `do_partition_le(slice, t)` = first index where slice[i] >  t  (like partition_point(|&x| x <= t))
//
// Default build: delegates to Rust stdlib branchless partition_point.
// `--features simd`: uses AVX2/AVX-512 vectorized final stage (see src/simd_search.rs).
//
// Runtime CPU check is cached by `is_x86_feature_detected!` (bool flag, no syscall per call).
//
// Build matrix:
//   default:         stdlib partition_point (branchless binary CMOV)
//   --features simd: AVX-512/AVX2 partition_lt/le (final-stage vector compare).
//                    Kept as documented negative-result ablation (§3.1: ≤7% wins).

#[cfg(not(feature = "simd"))]
#[inline(always)]
#[allow(dead_code)]
pub(super) fn do_partition_lt(haystack: &[f32], target: f32) -> usize {
    haystack.partition_point(|&x| x < target)
}

#[cfg(not(feature = "simd"))]
#[inline(always)]
#[allow(dead_code)]
pub(super) fn do_partition_le(haystack: &[f32], target: f32) -> usize {
    haystack.partition_point(|&x| x <= target)
}

#[cfg(all(feature = "simd", target_arch = "x86_64"))]
#[inline(always)]
#[allow(dead_code)]
pub(super) fn do_partition_lt(haystack: &[f32], target: f32) -> usize {
    // Prefer AVX-512 (16 lanes per compare) over AVX2 (8 lanes) when the CPU
    // supports it. Sapphire Rapids has both; older AVX2-only chips fall
    // through to the AVX2 path.
    if is_x86_feature_detected!("avx512f") {
        unsafe { crate::simd_search::partition_lt_avx512(haystack, target) }
    } else if is_x86_feature_detected!("avx2") {
        unsafe { crate::simd_search::partition_lt_avx2(haystack, target) }
    } else {
        haystack.partition_point(|&x| x < target)
    }
}

#[cfg(all(feature = "simd", target_arch = "x86_64"))]
#[inline(always)]
#[allow(dead_code)]
pub(super) fn do_partition_le(haystack: &[f32], target: f32) -> usize {
    if is_x86_feature_detected!("avx512f") {
        unsafe { crate::simd_search::partition_le_avx512(haystack, target) }
    } else if is_x86_feature_detected!("avx2") {
        unsafe { crate::simd_search::partition_le_avx2(haystack, target) }
    } else {
        haystack.partition_point(|&x| x <= target)
    }
}

// ── f16 search dispatchers ──────────────────────────────────────────────────
//
// Build matrix:
//   default (f16 only):       stdlib partition_point compares directly in f16
//   --features simd:          AVX-512 32-lane u16-bitcast compare via avx512bw
//                             (Sapphire Rapids; falls back to stdlib if absent)
//
// All paths take `target: half::f16` — caller must f16-quantize the f32 query
// percentile via `half::f16::from_f32` to match Python's reference semantics
// (np.searchsorted(col_f16, np.float16(target), …)).

#[cfg(all(feature = "f16", feature = "simd", target_arch = "x86_64"))]
#[inline(always)]
pub(super) fn f16_partition_lt(haystack: &[half::f16], target: half::f16) -> usize {
    if is_x86_feature_detected!("avx512bw") && is_x86_feature_detected!("avx512f") {
        unsafe { crate::simd_search::partition_lt_avx512_f16(haystack, target) }
    } else {
        haystack.partition_point(|x| *x < target)
    }
}

#[cfg(all(feature = "f16", feature = "simd", target_arch = "x86_64"))]
#[inline(always)]
pub(super) fn f16_partition_le(haystack: &[half::f16], target: half::f16) -> usize {
    if is_x86_feature_detected!("avx512bw") && is_x86_feature_detected!("avx512f") {
        unsafe { crate::simd_search::partition_le_avx512_f16(haystack, target) }
    } else {
        haystack.partition_point(|x| *x <= target)
    }
}

#[cfg(all(feature = "f16", not(feature = "simd")))]
#[inline(always)]
pub(super) fn f16_partition_lt(haystack: &[half::f16], target: half::f16) -> usize {
    haystack.partition_point(|x| *x < target)
}

#[cfg(all(feature = "f16", not(feature = "simd")))]
#[inline(always)]
pub(super) fn f16_partition_le(haystack: &[half::f16], target: half::f16) -> usize {
    haystack.partition_point(|x| *x <= target)
}

// ── 8-way interleaved binary search ──────────────────────────────────────────
//
// Serial: one query searches the column sequentially → 12 dependent cache misses,
//         each stalls until the prior load resolves (~80 ns each).
//
// Batch (B=8): run 8 searches in lock-step. Each step computes 8 independent
//              midpoints then issues 8 independent loads. Because the loads have
//              no data dependency on each other the CPU's out-of-order engine
//              issues all 8 simultaneously, filling its MSHR slots and hiding
//              7/8ths of the latency per round. The first 1–3 steps additionally
//              share the same midpoint value (all 8 searches start from the same
//              mid = n/2), so those loads are free after the first hit.
//
// Used only in the columnar engine, where the column is already in L2 cache.
// Safety contract for get_unchecked: mids[i] < n when lo[i] < hi[i], and is
// clamped to 0 (always valid for n≥1) when lo[i] ≥ hi[i].
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(feature = "batch-search")]
pub(super) const BATCH: usize = 8;

/// Run up to 8 binary searches on `col_vals` in lock-step.
/// `queries[i] = (q_idx, target, is_gt)` for i in 0..chunk.len().
/// Returns `lo[8]`; inactive slots (i ≥ chunk.len()) return 0.
#[cfg(feature = "batch-search")]
#[inline]
pub(super) fn batch_partition_point_8(
    col_vals: &[f32],
    queries: &[(usize, f32, bool)],
) -> [usize; BATCH] {
    let m = queries.len();
    let n = col_vals.len();
    let mut lo = [0usize; BATCH];
    let mut hi = [n; BATCH];
    for i in m..BATCH { hi[i] = 0; }  // pad: lo[i]=hi[i]=0 → converged immediately

    if n == 0 { return lo; }
    // floor(log2(n)) + 1 iterations covers all cases; inactive/converged slots
    // just do a dummy load of col_vals[0] each step (harmless).
    let n_steps = (usize::BITS - n.leading_zeros()) as usize;

    for _ in 0..n_steps {
        // Compute midpoints: pure register arithmetic, no loads.
        // When lo[i] >= hi[i] (converged), we clamp to index 0.
        let mids: [usize; BATCH] = std::array::from_fn(|i| {
            if lo[i] < hi[i] { lo[i] + (hi[i] - lo[i]) / 2 } else { 0 }
        });
        // Issue 8 independent loads simultaneously.
        // SAFETY: mids[i] < hi[i] <= n when active; mids[i] = 0 < n otherwise.
        let vals: [f32; BATCH] =
            std::array::from_fn(|i| unsafe { *col_vals.get_unchecked(mids[i]) });
        // Update lo/hi (register ops only — no further loads).
        for i in 0..BATCH {
            if lo[i] < hi[i] {
                let (_, target, is_gt) = queries[i];
                if if is_gt { vals[i] <= target } else { vals[i] < target } {
                    lo[i] = mids[i] + 1;
                } else {
                    hi[i] = mids[i];
                }
            }
        }
    }
    lo
}

/// f16 variant: values are half::f16 stored in the column. Comparisons happen
/// in f16 to match the Python reference, which searches with `np.float16(target)`
/// against an f16 column. Comparing in f32 against an unquantized f32 target
/// shifts the partition point by one for any stored value that equals
/// `f16::from_f32(target)` exactly — silently dropping (or adding) such
/// histograms vs Python.
#[cfg(all(feature = "batch-search", feature = "f16", not(feature = "aos")))]
#[inline]
pub(super) fn batch_partition_point_8_f16(
    col_vals: &[half::f16],
    queries: &[(usize, f32, bool)],
) -> [usize; BATCH] {
    let m = queries.len();
    let n = col_vals.len();
    let mut lo = [0usize; BATCH];
    let mut hi = [n; BATCH];
    for i in m..BATCH { hi[i] = 0; }

    if n == 0 { return lo; }
    let n_steps = (usize::BITS - n.leading_zeros()) as usize;

    // Quantize each query's f32 target to f16 once (matches Python's
    // np.searchsorted(col_f16, np.float16(target), …) semantics).
    let mut targets_h = [half::f16::ZERO; BATCH];
    for i in 0..m { targets_h[i] = half::f16::from_f32(queries[i].1); }

    for _ in 0..n_steps {
        let mids: [usize; BATCH] = std::array::from_fn(|i| {
            if lo[i] < hi[i] { lo[i] + (hi[i] - lo[i]) / 2 } else { 0 }
        });
        // SAFETY: same as f32 variant above.
        let vals: [half::f16; BATCH] =
            std::array::from_fn(|i| unsafe { *col_vals.get_unchecked(mids[i]) });
        for i in 0..BATCH {
            if lo[i] < hi[i] {
                let (_, _, is_gt) = queries[i];
                let t = targets_h[i];
                if if is_gt { vals[i] <= t } else { vals[i] < t } {
                    lo[i] = mids[i] + 1;
                } else {
                    hi[i] = mids[i];
                }
            }
        }
    }
    lo
}
