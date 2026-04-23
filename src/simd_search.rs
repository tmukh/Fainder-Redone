// AVX2-accelerated binary search over sorted f32 slices.
//
// Algorithm: branchless scalar binary search down to 8 elements, then a single
// AVX2 comparison for the final stage.
//
// Why this is faster than scalar partition_point at low thread counts (latency-bound):
//   The standard branchless binary search makes log2(n) sequential dependent loads
//   (~12 for n=3500). Each load address depends on the previous comparison result,
//   so the CPU cannot pipeline them. The SIMD variant makes the same number of
//   dependent loads for the upper levels but replaces the final 3 scalar steps
//   (which access cache-warm data) with a single AVX2 register operation:
//
//     Scalar:  ... → load[i-2] → cmp → load[i-1] → cmp → load[i] → cmp
//     SIMD:    ... → load[i-2] → cmp → AVX2_load_8 → VCMPPS → MOVMSKPS
//
//   The SIMD final step issues ONE load (8 floats in one 256-bit load) and ONE
//   compare, replacing THREE sequential load→cmp→branch chains.
//
// Why it does NOT help at high thread counts (bandwidth-bound):
//   At t≥16 on eval_medium, the DRAM memory controller is saturated. The bottleneck
//   is total bytes per second, not the depth of the dependent load chain. Fewer
//   dependent loads don't help when the bus is full regardless. This is the same
//   reason Eytzinger (which also reduces the dependent chain depth) fails at t=16.
//
// The difference from Eytzinger: SIMD keeps the same sorted memory layout (no
// index restructuring) — it only changes the comparison algorithm. Memory footprint
// is identical to the SoA scalar build.

#[cfg(target_arch = "x86_64")]
use std::arch::x86_64::*;

/// Returns the count of elements strictly less than `target` in the sorted `f32` slice.
/// Equivalent to `slice.partition_point(|&x| x < target)`.
///
/// Safety: requires AVX2. Call only after `is_x86_feature_detected!("avx2")`.
#[cfg(target_arch = "x86_64")]
#[target_feature(enable = "avx2")]
pub unsafe fn partition_lt_avx2(haystack: &[f32], target: f32) -> usize {
    let n   = haystack.len();
    let ptr = haystack.as_ptr();
    let mut base = 0usize;
    let mut size = n;

    // Branchless binary search — no conditional branches = no mispredictions.
    // Each iteration halves the search range; loop exits when ≤8 elements remain.
    while size > 8 {
        let half = size / 2;
        // Branchless: cast bool to usize (0 or 1), multiply by step.
        // The CPU can compute both branches speculatively; no pipeline stall.
        base += (*ptr.add(base + half - 1) < target) as usize * half;
        size -= half;
    }

    // AVX2 final stage: compare up to 8 remaining elements in a single vector op.
    // Pad with +∞ so padding positions never satisfy `x < target`.
    let target_v = _mm256_set1_ps(target);
    let mut tmp  = [f32::INFINITY; 8];
    std::ptr::copy_nonoverlapping(ptr.add(base), tmp.as_mut_ptr(), size);
    let data = _mm256_loadu_ps(tmp.as_ptr());
    // _CMP_LT_OQ = 17: ordered quiet less-than (returns 0xFFFF..FF per lane if true).
    let cmp  = _mm256_cmp_ps(data, target_v, _CMP_LT_OQ);
    // movemask extracts the MSB of each 32-bit lane → 8-bit mask, bit i set iff lane i true.
    // For a sorted array: bits 0..h are set (x < target), bits h..8 are clear (x ≥ target).
    // count_ones() = number of set bits = number of elements < target = h.
    base + (_mm256_movemask_ps(cmp) as u32).count_ones() as usize
}

/// Returns the count of elements ≤ `target` in the sorted `f32` slice.
/// Equivalent to `slice.partition_point(|&x| x <= target)`.
///
/// Safety: requires AVX2.
#[cfg(target_arch = "x86_64")]
#[target_feature(enable = "avx2")]
pub unsafe fn partition_le_avx2(haystack: &[f32], target: f32) -> usize {
    let n   = haystack.len();
    let ptr = haystack.as_ptr();
    let mut base = 0usize;
    let mut size = n;

    while size > 8 {
        let half = size / 2;
        base += (*ptr.add(base + half - 1) <= target) as usize * half;
        size -= half;
    }

    let target_v = _mm256_set1_ps(target);
    let mut tmp  = [f32::INFINITY; 8];
    std::ptr::copy_nonoverlapping(ptr.add(base), tmp.as_mut_ptr(), size);
    let data = _mm256_loadu_ps(tmp.as_ptr());
    // _CMP_LE_OQ = 18: ordered quiet less-than-or-equal.
    let cmp  = _mm256_cmp_ps(data, target_v, _CMP_LE_OQ);
    base + (_mm256_movemask_ps(cmp) as u32).count_ones() as usize
}
