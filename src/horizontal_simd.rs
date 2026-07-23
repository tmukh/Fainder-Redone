// Horizontal (inter-query) SIMD binary search for the columnar engine.
//
// The intra-search SIMD ablation (Phase 10) was a null result because the
// CPU's reorder buffer already saturates within-search instruction-level
// parallelism: the dependent CMOV chain in `partition_point` cannot be
// broken by adding a wider compare instruction at the leaves.
//
// Horizontal SIMD addresses a different bottleneck: cross-search ILP. Instead
// of vectorising one search, we run 16 independent binary searches in lockstep
// through the same bisection step graph using AVX-512 (lane width 16 for
// f32). Each step issues one `vpgatherdd` to load 16 mid-points from a single
// L1-resident column, one `vcmpps` to compare against 16 different targets,
// and one mask-blend to update each lane's `low`/`high`.
//
// This is the approach of Polychroniou, Raghavan, Ross, "Rethinking SIMD
// Vectorization for In-Memory Databases" (SIGMOD 2015), Section 4 — the
// canonical reference for vectorised binary search across multiple probes.
//
// Sapphire Rapids' improved gather throughput (vpgatherdd ~5 cycles
// reciprocal throughput vs. ~12-15 on Skylake-X) makes this design viable
// where it would have lost on earlier microarchitectures.
//
// Used only inside the columnar engine's per-(cluster, bin_idx) group, where
// all 16 queries access the same column slice. AVX-512F is detected at
// runtime; a scalar fallback is provided.

#[cfg(target_arch = "x86_64")]
use std::arch::x86_64::*;

/// Run 16 binary searches (one per AVX-512 lane) on a single sorted column.
/// Each lane finds the `partition_point` of `targets[lane]` in `col_vals`,
/// using strict less-than comparison: returns the first index where
/// `col_vals[i] >= target`.
///
/// `n_active` is the number of valid lanes (1..=16). Lanes >= `n_active` are
/// inactive; their output positions are unspecified.
///
/// SAFETY: caller must ensure `col_vals.len() <= u32::MAX` (we use i32
/// indexing).
#[cfg(all(target_arch = "x86_64", feature = "horizontal-simd"))]
#[target_feature(enable = "avx512f")]
pub unsafe fn batch_partition_lt_avx512(
    col_vals: &[f32],
    targets: &[f32; 16],
    n_active: usize,
) -> [usize; 16] {
    debug_assert!(n_active <= 16);
    let n = col_vals.len() as i32;
    let base_ptr = col_vals.as_ptr();

    // active_mask: bits 0..n_active set, the rest unset
    let active_mask: u16 = if n_active >= 16 { 0xFFFF } else { (1u16 << n_active) - 1 };

    // lows = 0 (16 lanes), highs = n (16 lanes), all-i32
    let mut lows = _mm512_setzero_si512();
    let mut highs = _mm512_set1_epi32(n);

    // targets vector
    let targets_v = _mm512_loadu_ps(targets.as_ptr());

    // Loop until all active lanes have low == high.
    // Each iteration shrinks the search window by ~half per active lane.
    // Bound on iterations: ceil(log2(n)) + 1 to be safe.
    let max_iters = 64usize;  // ample upper bound; loop normally exits earlier
    for _ in 0..max_iters {
        // mids = (lows + highs) / 2  (signed-32-bit add then shift right by 1)
        let sum = _mm512_add_epi32(lows, highs);
        let mids = _mm512_srai_epi32(sum, 1);

        // active_alive: lanes where low < high (still searching)
        let alive = _mm512_cmplt_epi32_mask(lows, highs);
        let active_alive = alive & active_mask;
        if active_alive == 0 { break; }

        // gather col_vals[mids] for active lanes; inactive lanes use mid=0 fallback
        // _mm512_mask_i32gather_ps: load f32 from base+mids[i]*4 where mask[i]=1
        let zero_f = _mm512_setzero_ps();
        let vals = _mm512_mask_i32gather_ps::<4>(zero_f, active_alive, mids, base_ptr);

        // compare: vals < targets → mask of lanes that should advance low to mid+1
        let less_mask = _mm512_cmp_ps_mask::<_CMP_LT_OQ>(vals, targets_v);
        // restrict to active lanes
        let advance_low = less_mask & active_alive;
        let move_high = (!less_mask) & active_alive;

        // For lanes in advance_low: lows = mids + 1
        let mids_plus1 = _mm512_add_epi32(mids, _mm512_set1_epi32(1));
        lows = _mm512_mask_blend_epi32(advance_low, lows, mids_plus1);
        // For lanes in move_high: highs = mids
        highs = _mm512_mask_blend_epi32(move_high, highs, mids);
    }

    // Extract lows as the 16 partition points
    let mut out = [0i32; 16];
    _mm512_storeu_epi32(out.as_mut_ptr() as *mut i32, lows);
    let mut result = [0usize; 16];
    for i in 0..16 {
        result[i] = out[i] as usize;
    }
    result
}

/// Same as `batch_partition_lt_avx512` but with `<=` semantics (equivalent
/// to `partition_point(|&x| x <= target)`).
#[cfg(all(target_arch = "x86_64", feature = "horizontal-simd"))]
#[target_feature(enable = "avx512f")]
pub unsafe fn batch_partition_le_avx512(
    col_vals: &[f32],
    targets: &[f32; 16],
    n_active: usize,
) -> [usize; 16] {
    debug_assert!(n_active <= 16);
    let n = col_vals.len() as i32;
    let base_ptr = col_vals.as_ptr();

    let active_mask: u16 = if n_active >= 16 { 0xFFFF } else { (1u16 << n_active) - 1 };

    let mut lows = _mm512_setzero_si512();
    let mut highs = _mm512_set1_epi32(n);
    let targets_v = _mm512_loadu_ps(targets.as_ptr());

    for _ in 0..64usize {
        let sum = _mm512_add_epi32(lows, highs);
        let mids = _mm512_srai_epi32(sum, 1);

        let alive = _mm512_cmplt_epi32_mask(lows, highs);
        let active_alive = alive & active_mask;
        if active_alive == 0 { break; }

        let zero_f = _mm512_setzero_ps();
        let vals = _mm512_mask_i32gather_ps::<4>(zero_f, active_alive, mids, base_ptr);

        // For partition_le: advance low when vals <= target → use _CMP_LE_OQ
        let leq_mask = _mm512_cmp_ps_mask::<_CMP_LE_OQ>(vals, targets_v);
        let advance_low = leq_mask & active_alive;
        let move_high = (!leq_mask) & active_alive;

        let mids_plus1 = _mm512_add_epi32(mids, _mm512_set1_epi32(1));
        lows = _mm512_mask_blend_epi32(advance_low, lows, mids_plus1);
        highs = _mm512_mask_blend_epi32(move_high, highs, mids);
    }

    let mut out = [0i32; 16];
    _mm512_storeu_epi32(out.as_mut_ptr() as *mut i32, lows);
    let mut result = [0usize; 16];
    for i in 0..16 {
        result[i] = out[i] as usize;
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(all(target_arch = "x86_64", feature = "horizontal-simd"))]
    #[test]
    fn lt_matches_stdlib_partition_point() {
        if !is_x86_feature_detected!("avx512f") { return; }
        let arr: Vec<f32> = (0..1400).map(|i| i as f32 * 0.7).collect();
        let targets: [f32; 16] = [
            -1.0, 0.0, 0.3, 0.7, 100.0, 250.5, 500.0, 700.0,
            850.3, 950.0, 979.3, 999.0, 1000.0, 1e4, 1e6, -1e6,
        ];
        let out = unsafe { batch_partition_lt_avx512(&arr, &targets, 16) };
        for (i, &t) in targets.iter().enumerate() {
            let expected = arr.partition_point(|&x| x < t);
            assert_eq!(out[i], expected, "lane {} target={}", i, t);
        }
    }

    #[cfg(all(target_arch = "x86_64", feature = "horizontal-simd"))]
    #[test]
    fn le_matches_stdlib_partition_point() {
        if !is_x86_feature_detected!("avx512f") { return; }
        let arr: Vec<f32> = (0..1400).map(|i| i as f32 * 0.7).collect();
        let targets: [f32; 16] = [
            -1.0, 0.0, 0.3, 0.7, 100.0, 250.5, 500.0, 700.0,
            850.3, 950.0, 979.3, 999.0, 1000.0, 1e4, 1e6, -1e6,
        ];
        let out = unsafe { batch_partition_le_avx512(&arr, &targets, 16) };
        for (i, &t) in targets.iter().enumerate() {
            let expected = arr.partition_point(|&x| x <= t);
            assert_eq!(out[i], expected, "lane {} target={}", i, t);
        }
    }

    #[cfg(all(target_arch = "x86_64", feature = "horizontal-simd"))]
    #[test]
    fn handles_partial_lane_count() {
        if !is_x86_feature_detected!("avx512f") { return; }
        let arr: Vec<f32> = (0..1400).map(|i| i as f32 * 0.7).collect();
        let mut targets = [0.0f32; 16];
        targets[0] = 100.0;
        targets[1] = 500.0;
        targets[2] = 999.0;
        let out = unsafe { batch_partition_lt_avx512(&arr, &targets, 3) };
        for (i, &t) in targets[..3].iter().enumerate() {
            let expected = arr.partition_point(|&x| x < t);
            assert_eq!(out[i], expected, "lane {} target={}", i, t);
        }
    }
}
