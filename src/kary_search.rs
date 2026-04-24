// 4-way branchless search (k-ary partition_point with k=4).
//
// Motivation. Hardware perf counters (perf stat, eval_medium, t=1) show the
// Rust binary-search engine is compute/L1-bound: IPC ≈ 2.46 (of 4.0 max),
// L1 hit rate 99.45%, branch-mispred rate 0.01%. The stdlib `partition_point`
// compiles to a tight branchless CMOV loop, so the critical path per query is
// the chain of ~log_2(n) dependent CMOV updates (one per bisection step).
// On n≈1400 histograms per column this is ~11 steps.
//
// k-ary search reduces the number of dependent CMOV steps. At each iteration
// this implementation loads 3 pivots (quartile positions q, 2q, 3q within the
// current window), issues 3 independent comparisons, and counts how many are
// less than the target (result in {0,1,2,3}). The window shrinks to ~size/4
// per iteration, giving ~log_4(n) ≈ 6 steps instead of 11 for n≈1400.
//
// The three loads per iteration have no data dependency on each other, so the
// CPU's out-of-order engine can issue them in parallel. The critical path per
// iteration is still one load → compare → CMOV, but the total step count drops.
// If the serial CMOV chain is the bottleneck (the hypothesis this ablation
// tests), we should observe a ~2× speedup at t=1.
//
// Semantics: identical to `slice.partition_point(|&x| x < target)`.
//
// Safety: every `get_unchecked` call is guarded by `size >= 4` (so p3 <
// base + size <= arr.len()) or the linear tail invariant.

/// 4-way branchless search. Returns the first index `i` where `arr[i] >= target`
/// (or `arr.len()` if no such index exists). `arr` must be sorted ascending.
#[inline(always)]
pub fn partition_lt_4way(arr: &[f32], target: f32) -> usize {
    let mut base: usize = 0;
    let mut size: usize = arr.len();

    while size >= 4 {
        let q = size / 4;
        let p1 = base + q;
        let p2 = base + 2 * q;
        let p3 = base + 3 * q;
        // SAFETY: p3 = base + 3q < base + size <= arr.len() when size >= 4.
        let v1 = unsafe { *arr.get_unchecked(p1) };
        let v2 = unsafe { *arr.get_unchecked(p2) };
        let v3 = unsafe { *arr.get_unchecked(p3) };
        let c1 = (v1 < target) as usize;
        let c2 = (v2 < target) as usize;
        let c3 = (v3 < target) as usize;
        let count = c1 + c2 + c3;
        base += count * q;
        // If count == 3, we're in the last quarter whose length is size - 3q
        // (may exceed q when size is not divisible by 4). Otherwise the window
        // is exactly q. Branchless via is_last multiplier.
        let is_last = (count == 3) as usize;
        size = q + is_last * (size - 4 * q);
    }

    // Linear tail: size < 4, between 0 and 3 elements remaining.
    while size > 0 {
        if unsafe { *arr.get_unchecked(base) } >= target {
            return base;
        }
        base += 1;
        size -= 1;
    }
    base
}

/// 4-way branchless variant for `partition_point(|&x| x <= target)`.
/// Returns the first index `i` where `arr[i] > target`.
#[inline(always)]
pub fn partition_le_4way(arr: &[f32], target: f32) -> usize {
    let mut base: usize = 0;
    let mut size: usize = arr.len();

    while size >= 4 {
        let q = size / 4;
        let p1 = base + q;
        let p2 = base + 2 * q;
        let p3 = base + 3 * q;
        // SAFETY: p3 < base + size <= arr.len()
        let v1 = unsafe { *arr.get_unchecked(p1) };
        let v2 = unsafe { *arr.get_unchecked(p2) };
        let v3 = unsafe { *arr.get_unchecked(p3) };
        let c1 = (v1 <= target) as usize;
        let c2 = (v2 <= target) as usize;
        let c3 = (v3 <= target) as usize;
        let count = c1 + c2 + c3;
        base += count * q;
        let is_last = (count == 3) as usize;
        size = q + is_last * (size - 4 * q);
    }

    while size > 0 {
        if unsafe { *arr.get_unchecked(base) } > target {
            return base;
        }
        base += 1;
        size -= 1;
    }
    base
}

// ── f16 variants ─────────────────────────────────────────────────────────────
// When the `f16` feature is also enabled, the columnar engine stores values as
// half-precision. These k-ary variants dequantize each pivot via `to_f32()`
// at load time, matching the per-comparison cost of the stdlib f16 path.

#[cfg(feature = "f16")]
#[inline(always)]
pub fn partition_lt_4way_f16(arr: &[half::f16], target: f32) -> usize {
    let mut base: usize = 0;
    let mut size: usize = arr.len();

    while size >= 4 {
        let q = size / 4;
        let p1 = base + q;
        let p2 = base + 2 * q;
        let p3 = base + 3 * q;
        // SAFETY: p3 < base + size <= arr.len()
        let v1 = unsafe { (*arr.get_unchecked(p1)).to_f32() };
        let v2 = unsafe { (*arr.get_unchecked(p2)).to_f32() };
        let v3 = unsafe { (*arr.get_unchecked(p3)).to_f32() };
        let c1 = (v1 < target) as usize;
        let c2 = (v2 < target) as usize;
        let c3 = (v3 < target) as usize;
        let count = c1 + c2 + c3;
        base += count * q;
        let is_last = (count == 3) as usize;
        size = q + is_last * (size - 4 * q);
    }

    while size > 0 {
        if unsafe { (*arr.get_unchecked(base)).to_f32() } >= target {
            return base;
        }
        base += 1;
        size -= 1;
    }
    base
}

#[cfg(feature = "f16")]
#[inline(always)]
pub fn partition_le_4way_f16(arr: &[half::f16], target: f32) -> usize {
    let mut base: usize = 0;
    let mut size: usize = arr.len();

    while size >= 4 {
        let q = size / 4;
        let p1 = base + q;
        let p2 = base + 2 * q;
        let p3 = base + 3 * q;
        let v1 = unsafe { (*arr.get_unchecked(p1)).to_f32() };
        let v2 = unsafe { (*arr.get_unchecked(p2)).to_f32() };
        let v3 = unsafe { (*arr.get_unchecked(p3)).to_f32() };
        let c1 = (v1 <= target) as usize;
        let c2 = (v2 <= target) as usize;
        let c3 = (v3 <= target) as usize;
        let count = c1 + c2 + c3;
        base += count * q;
        let is_last = (count == 3) as usize;
        size = q + is_last * (size - 4 * q);
    }

    while size > 0 {
        if unsafe { (*arr.get_unchecked(base)).to_f32() } > target {
            return base;
        }
        base += 1;
        size -= 1;
    }
    base
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lt_matches_stdlib() {
        let arr: Vec<f32> = (0..1400).map(|i| i as f32 * 0.7).collect();
        for &t in &[-1.0_f32, 0.0, 0.3, 0.7, 500.0, 979.3, 1000.0, 1e6] {
            let expected = arr.partition_point(|&x| x < t);
            let actual = partition_lt_4way(&arr, t);
            assert_eq!(actual, expected, "target={}", t);
        }
    }

    #[test]
    fn le_matches_stdlib() {
        let arr: Vec<f32> = (0..1400).map(|i| i as f32 * 0.7).collect();
        for &t in &[-1.0_f32, 0.0, 0.3, 0.7, 500.0, 979.3, 1000.0, 1e6] {
            let expected = arr.partition_point(|&x| x <= t);
            let actual = partition_le_4way(&arr, t);
            assert_eq!(actual, expected, "target={}", t);
        }
    }

    #[test]
    fn handles_duplicates() {
        let arr = vec![1.0_f32, 2.0, 2.0, 2.0, 3.0, 3.0, 4.0];
        for &t in &[0.0_f32, 1.0, 2.0, 2.5, 3.0, 4.0, 5.0] {
            assert_eq!(
                partition_lt_4way(&arr, t),
                arr.partition_point(|&x| x < t),
                "lt target={}",
                t
            );
            assert_eq!(
                partition_le_4way(&arr, t),
                arr.partition_point(|&x| x <= t),
                "le target={}",
                t
            );
        }
    }

    #[test]
    fn handles_small_arrays() {
        for n in 0..8 {
            let arr: Vec<f32> = (0..n).map(|i| i as f32).collect();
            for t_int in -1..=(n as i32 + 1) {
                let t = t_int as f32;
                assert_eq!(
                    partition_lt_4way(&arr, t),
                    arr.partition_point(|&x| x < t),
                    "n={} target={}",
                    n,
                    t
                );
            }
        }
    }
}
