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

// ── AVX-512 f32 final stage (16 lanes per compare) ──────────────────────────
//
// 2× the AVX2 final-stage width (16 vs 8). Uses stable AVX-512F intrinsics
// (`_mm512_cmp_ps_mask`, KMOV result, popcount).
//
// Padding contract: caller must guarantee at least 16 sentinel f32::INFINITY
// values past the slice end. SubIndex with `--features simd` provides 32
// (SOA_PAD), which trivially covers this.

/// Returns the count of elements strictly less than `target`.
/// SAFETY: requires AVX-512F + the padding contract above.
#[cfg(target_arch = "x86_64")]
#[target_feature(enable = "avx512f")]
pub unsafe fn partition_lt_avx512(haystack: &[f32], target: f32) -> usize {
    let n        = haystack.len();
    let ptr      = haystack.as_ptr();
    let mut base = 0usize;
    let mut size = n;

    // Branchless binary search down to ≤16 elements remaining.
    while size > 16 {
        let half = size / 2;
        // SAFETY: base + half - 1 < base + size ≤ n
        base += (*ptr.add(base + half - 1) < target) as usize * half;
        size -= half;
    }

    // Final stage: 16-lane f32 compare. We may read up to 16 elements past
    // the slice end into the +∞ padding, which won't satisfy `< target`.
    let target_v = _mm512_set1_ps(target);
    let data     = _mm512_loadu_ps(ptr.add(base));
    // _CMP_LT_OQ = 17: ordered quiet less-than. Returns __mmask16.
    let mask     = _mm512_cmp_ps_mask::<_CMP_LT_OQ>(data, target_v);
    base + (mask as u32).count_ones() as usize
}

/// Returns the count of elements ≤ `target`. SAFETY: as `partition_lt_avx512`.
#[cfg(target_arch = "x86_64")]
#[target_feature(enable = "avx512f")]
pub unsafe fn partition_le_avx512(haystack: &[f32], target: f32) -> usize {
    let n        = haystack.len();
    let ptr      = haystack.as_ptr();
    let mut base = 0usize;
    let mut size = n;

    while size > 16 {
        let half = size / 2;
        base += (*ptr.add(base + half - 1) <= target) as usize * half;
        size -= half;
    }

    let target_v = _mm512_set1_ps(target);
    let data     = _mm512_loadu_ps(ptr.add(base));
    let mask     = _mm512_cmp_ps_mask::<_CMP_LE_OQ>(data, target_v);
    base + (mask as u32).count_ones() as usize
}

// ── AVX-512 f16 search via u16-bitcast trick ─────────────────────────────────
//
// Sapphire Rapids has AVX-512_FP16, but Rust's `_mm512_cmp_ph_mask` intrinsic
// is still nightly-only. We sidestep this by exploiting a property of IEEE 754
// float layout:
//
//   For two non-negative finite f16 values a, b:
//     a < b  (as f16)  ⟺  bits(a) < bits(b)  (as u16, unsigned)
//
// CDF percentile values are always in [0, 1] and the column padding sentinel
// is +∞ (= 0x7C00, the largest non-NaN u16 representation), so unsigned u16
// comparison gives the exact same partition point as f16 comparison while
// using only stable AVX-512BW intrinsics.
//
// Padding contract: caller passes a slice of length `n` (logical) that is
// followed in the underlying allocation by at least 32 sentinel f16(+∞)
// values. SubIndex with --features simd guarantees this via SOA_PAD=32. The
// final-stage 32-lane unaligned load is therefore safe.

/// Returns the count of elements strictly less than `target` in the sorted
/// f16 slice — equivalent to `slice.partition_point(|&x| x < target)`.
///
/// SAFETY: requires AVX-512BW. The slice's underlying allocation must contain
/// at least `slice.len() + 32` valid f16 values, with the trailing 32 entries
/// being f16(+∞) sentinels. Callers built with `--features f16,simd` get this
/// from the SubIndex padding scheme.
///
/// CONTRACT: `target` must be a non-negative finite f16 value. The u16-bitcast
/// trick (treating the f16 storage as u16 for AVX-512 unsigned compare) is
/// equivalent to f16 ordering only when both operands are non-negative finite
/// (the sign bit on negatives flips the unsigned ordering). CDF percentile
/// queries always meet this contract — the percentile is in [0, 1] and the
/// stored column is sorted CDF values, also in [0, 1]. The dispatcher in
/// engine.rs constructs `target` via `f16::from_f32(percentile)` from a
/// percentile guaranteed to lie in (0, 1].
#[cfg(all(target_arch = "x86_64", feature = "f16"))]
#[target_feature(enable = "avx512bw,avx512f")]
pub unsafe fn partition_lt_avx512_f16(haystack: &[half::f16], target: half::f16) -> usize {
    let n        = haystack.len();
    let ptr      = haystack.as_ptr() as *const u16;
    let target_u = target.to_bits();
    let mut base = 0usize;
    let mut size = n;

    // Branchless binary search down to ≤32 elements remaining. Treats values
    // as u16 — equivalent to f16 ordering for non-negative finites and
    // sentinel +∞ (= 0x7C00).
    while size > 32 {
        let half = size / 2;
        // SAFETY: base + half - 1 < base + size ≤ n
        let v = *ptr.add(base + half - 1);
        base += (v < target_u) as usize * half;
        size -= half;
    }

    // Final stage: 32-lane u16 compare. `_mm512_loadu_epi16` reads 64 bytes;
    // we may read up to 32 elements past the slice end into the +∞ padding,
    // which won't satisfy `< target` and so doesn't perturb the result.
    let target_v = _mm512_set1_epi16(target_u as i16);
    let data     = _mm512_loadu_epi16(ptr.add(base) as *const i16);
    let mask     = _mm512_cmplt_epu16_mask(data, target_v);
    base + mask.count_ones() as usize
}

/// Returns the count of elements ≤ `target` in the sorted f16 slice —
/// equivalent to `slice.partition_point(|&x| x <= target)`.
#[cfg(all(target_arch = "x86_64", feature = "f16"))]
#[target_feature(enable = "avx512bw,avx512f")]
pub unsafe fn partition_le_avx512_f16(haystack: &[half::f16], target: half::f16) -> usize {
    let n        = haystack.len();
    let ptr      = haystack.as_ptr() as *const u16;
    let target_u = target.to_bits();
    let mut base = 0usize;
    let mut size = n;

    while size > 32 {
        let half = size / 2;
        let v = *ptr.add(base + half - 1);
        base += (v <= target_u) as usize * half;
        size -= half;
    }

    let target_v = _mm512_set1_epi16(target_u as i16);
    let data     = _mm512_loadu_epi16(ptr.add(base) as *const i16);
    let mask     = _mm512_cmple_epu16_mask(data, target_v);
    base + mask.count_ones() as usize
}

#[cfg(test)]
mod tests {
    #[cfg(target_arch = "x86_64")]
    #[test]
    fn avx512_f32_partition_matches_stdlib() {
        if !is_x86_feature_detected!("avx512f") { return; }
        // Build a sorted f32 column of length 1400 plus 32 +∞ sentinels
        // (matches SubIndex layout under --features simd).
        let mut v: Vec<f32> = (0..1400).map(|i| i as f32 * 0.7).collect();
        for _ in 0..32 { v.push(f32::INFINITY); }
        let real = &v[..1400];

        let targets = [
            -1.0_f32, 0.0, 0.3, 0.7, 100.0, 250.5, 500.0, 700.0,
            850.3, 950.0, 979.3, 999.0, 1000.0,
            // Targets equal to / between stored values:
            500.0 * 0.7, 500.0 * 0.7 + 0.001,
        ];
        for &t in &targets {
            let expected_lt = real.partition_point(|&x| x < t);
            let expected_le = real.partition_point(|&x| x <= t);
            let actual_lt = unsafe { super::partition_lt_avx512(real, t) };
            let actual_le = unsafe { super::partition_le_avx512(real, t) };
            assert_eq!(actual_lt, expected_lt, "lt mismatch target={}", t);
            assert_eq!(actual_le, expected_le, "le mismatch target={}", t);
        }
    }

    #[cfg(all(target_arch = "x86_64", feature = "f16"))]
    #[test]
    fn avx512_f16_partition_matches_stdlib() {
        use half::f16;
        if !is_x86_feature_detected!("avx512bw") || !is_x86_feature_detected!("avx512f") {
            return;
        }
        // Build a sorted f16 column of length 1400 plus 32 +∞ sentinels.
        let mut v: Vec<f16> = (0..1400u16)
            .map(|i| f16::from_f32(i as f32 / 1500.0))
            .collect();
        v.sort_by(|a, b| a.partial_cmp(b).unwrap());
        for _ in 0..32 { v.push(f16::INFINITY); }
        let real = &v[..1400];

        // Only non-negative finite targets — see the function contract.
        let targets = [
            f16::from_f32(0.0),  f16::from_f32(0.001),
            f16::from_f32(0.1),  f16::from_f32(0.5),
            f16::from_f32(0.9),  f16::from_f32(0.95),
            f16::from_f32(0.99999), f16::from_f32(1.5),
            // Edge cases worth covering: target equal to a stored value
            // (must return position AT the stored value, not after) and a
            // target between two stored values.
            f16::from_f32(700.0 / 1500.0),
            f16::from_f32(701.5 / 1500.0),
        ];
        for &t in &targets {
            let expected_lt = real.partition_point(|&x| x < t);
            let expected_le = real.partition_point(|&x| x <= t);
            let actual_lt = unsafe { super::partition_lt_avx512_f16(real, t) };
            let actual_le = unsafe { super::partition_le_avx512_f16(real, t) };
            assert_eq!(actual_lt, expected_lt, "lt mismatch target={:?}", t);
            assert_eq!(actual_le, expected_le, "le mismatch target={:?}", t);
        }
    }
}
