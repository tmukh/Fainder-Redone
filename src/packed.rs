// Per-cluster bit-packed histogram IDs.
//
// Layout per SubIndex (column-major):
//   bit_width = ceil(log2(max(n_hists, 2)))            // 1..=32 bits per id
//   stride_words = ceil(n_hists * bit_width / 32)      // u32 words per column
//   packed_ids: Vec<u32> of length n_bins * stride_words + 1
//                                                      // +1 = trailing safety pad word
//
// Decode reads one u32 word and the next; combines into u64; shifts down by
// `bit_pos % 32` and masks `bit_width` bits. The trailing pad word makes the
// `packed[word_idx + 1]` read safe at the very last column's last id; for any
// non-last column a cross-column read just pulls the start of the next column,
// whose bits are masked out anyway.
//
// Caller invariants:
//   * pack_col is given exactly `n_hists` ids per column, each id < 2^bit_width
//   * append_range receives 0 <= start <= end <= n_hists for the current column

/// Bits needed to encode any id in [0, n-1]. Minimum 1 (so n=1 still has a valid
/// bit width and pack/unpack are no-ops degenerately).
#[inline]
pub fn bit_width_for(n: usize) -> u8 {
    if n <= 1 { 1 } else {
        (usize::BITS - (n - 1).leading_zeros()) as u8
    }
}

/// u32 words needed to hold n_hists ids at the given bit width (no trailing pad).
#[inline]
pub fn stride_words(n_hists: usize, bit_width: u8) -> usize {
    let bits = n_hists * bit_width as usize;
    (bits + 31) / 32
}

/// Pack `ids` (each < 2^bit_width) into `dst` starting at `dst_word_off`.
/// `dst[dst_word_off .. dst_word_off + stride_words(ids.len(), bit_width)]`
/// must be in bounds and zero-initialised.
pub fn pack_col(ids: &[u32], bit_width: u8, dst: &mut [u32]) {
    let bw = bit_width as usize;
    if bw == 0 || ids.is_empty() { return; }
    for (k, &v) in ids.iter().enumerate() {
        let bit_pos = k * bw;
        let word_idx = bit_pos / 32;
        let shift = (bit_pos % 32) as u32;
        let v64 = (v as u64) << shift;
        dst[word_idx] |= v64 as u32;
        if shift as usize + bw > 32 {
            dst[word_idx + 1] |= (v64 >> 32) as u32;
        }
    }
}

/// Append ids `[start..end)` from one packed column (starting at word `col_off`
/// in `packed`) to `out`. `packed` must have one trailing zero word past the
/// last column to make the cross-word load safe at the final id of the buffer.
#[inline]
pub fn append_range(
    out: &mut Vec<u32>,
    packed: &[u32],
    col_off: usize,
    bit_width: u8,
    start: usize,
    end: usize,
) {
    let bw = bit_width as usize;
    if start >= end { return; }
    let mask: u64 = if bw == 32 { u32::MAX as u64 } else { (1u64 << bw) - 1 };
    let n = end - start;
    out.reserve(n);

    let mut bit_pos = start * bw;
    let mut word_idx = col_off + bit_pos / 32;
    let mut shift = (bit_pos % 32) as u32;

    for _ in 0..n {
        // SAFETY: packed[word_idx + 1] is in bounds because the buffer carries
        // a trailing pad word; mask discards any bits from the next column.
        let lo = packed[word_idx] as u64;
        let hi = packed[word_idx + 1] as u64;
        let combined = (hi << 32) | lo;
        out.push(((combined >> shift) & mask) as u32);

        bit_pos += bw;
        let new_word = col_off + bit_pos / 32;
        word_idx = new_word;
        shift = (bit_pos % 32) as u32;
    }
}

/// Variant of `append_range` for `--features local-ids`: decode each id from
/// the packed column as a per-cluster LOCAL id, look it up in
/// `local_to_global` (size n_hists × 4B), and push the resulting GLOBAL id.
///
/// Mechanism (§3.11): the lookup table is at most ~20 KB per cluster
/// (n_hists ≤ ~5000) and fits L1d (48 KB on Sapphire Rapids 8468H) for the
/// duration of a cluster's processing window. Within qbatch K=128 the table
/// is touched ~K × selectivity ≈ 64 times per (cluster, batch); after the
/// first 1–2 queries it's fully resident in L1, so subsequent decodes pay
/// L1 latency (~4 cycles), not DRAM bandwidth. Across the K-batch boundary
/// the table flushes, but the next cluster's table replaces it.
///
/// In default row-centric (par_iter over queries × serial clusters) the
/// table flushes between every (q, c+1) cluster transition for that worker
/// — predicting net negative there. The compositional prediction is
/// registered upfront in §3.11 and tested by the sweep.
#[inline]
pub fn append_range_local_to_global(
    out: &mut Vec<u32>,
    packed: &[u32],
    col_off: usize,
    bit_width: u8,
    start: usize,
    end: usize,
    local_to_global: &[u32],
) {
    let bw = bit_width as usize;
    if start >= end { return; }
    let mask: u64 = if bw == 32 { u32::MAX as u64 } else { (1u64 << bw) - 1 };
    let n = end - start;
    out.reserve(n);

    let mut bit_pos = start * bw;
    let mut word_idx = col_off + bit_pos / 32;
    let mut shift = (bit_pos % 32) as u32;

    for _ in 0..n {
        let lo = packed[word_idx] as u64;
        let hi = packed[word_idx + 1] as u64;
        let combined = (hi << 32) | lo;
        let local_id = ((combined >> shift) & mask) as usize;
        // SAFETY: pack_col guarantees local_id < n_hists; local_to_global
        // is sized n_hists at build time.
        out.push(local_to_global[local_id]);

        bit_pos += bw;
        let new_word = col_off + bit_pos / 32;
        word_idx = new_word;
        shift = (bit_pos % 32) as u32;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn round_trip(ids: &[u32], bit_width: u8) {
        let n_words = stride_words(ids.len(), bit_width);
        let mut buf = vec![0u32; n_words + 1];
        pack_col(ids, bit_width, &mut buf[..n_words]);
        let mut out = Vec::new();
        append_range(&mut out, &buf, 0, bit_width, 0, ids.len());
        assert_eq!(out.as_slice(), ids, "bw={} ids={:?}", bit_width, ids);
    }

    #[test] fn rt_1bit() { round_trip(&[0,1,1,0,1,0,0,1,1,1,0], 1); }
    #[test] fn rt_3bit() { round_trip(&[0,1,2,3,4,5,6,7,0,7,3,5], 3); }
    #[test] fn rt_10bit() {
        let ids: Vec<u32> = (0..1023u32).collect();
        round_trip(&ids, 10);
    }
    #[test] fn rt_13bit() {
        let ids: Vec<u32> = (0..5000u32).collect();
        round_trip(&ids, 13);
    }
    #[test] fn rt_partial_range() {
        let ids: Vec<u32> = (0..1000u32).collect();
        let bw = 10u8;
        let n_words = stride_words(ids.len(), bw);
        let mut buf = vec![0u32; n_words + 1];
        pack_col(&ids, bw, &mut buf[..n_words]);
        let mut out = Vec::new();
        append_range(&mut out, &buf, 0, bw, 100, 200);
        assert_eq!(out, (100u32..200u32).collect::<Vec<_>>());
    }
    #[test] fn rt_two_columns() {
        let bw = 10u8;
        let stride = stride_words(1000, bw);
        let mut buf = vec![0u32; stride * 2 + 1];
        let col0: Vec<u32> = (0..1000u32).collect();
        let col1: Vec<u32> = (0..1000u32).map(|i| 999 - i).collect();
        let (a, b) = buf[..stride*2].split_at_mut(stride);
        pack_col(&col0, bw, a);
        pack_col(&col1, bw, b);
        let mut out = Vec::new();
        append_range(&mut out, &buf, stride, bw, 0, 1000);
        assert_eq!(out, col1);
    }
}
