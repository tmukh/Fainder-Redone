//! PGM-index FFI bindings (C interface from `vendor/PGM-index/c-interface/cpgm.h`).
//!
//! Active only with `--features pgm`. We use the `uint32` PGM index with
//! `f32 → u32` bit-reinterpretation. CDF values are always non-negative
//! finite, so IEEE-754 bit ordering matches numeric ordering on this domain.
//! (Same trick used for the f16 SIMD path in `simd_search.rs`.)

#![cfg(feature = "pgm")]

use std::os::raw::c_void;

/// PGM approximate-position result. Mirrors `approx_pos_t` in cpgm.h.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct ApproxPos {
    pub pos: usize,
    pub lo: usize,
    pub hi: usize,
}

extern "C" {
    fn pgm_index_uint32_create(a: *const u32, n: usize, epsilon: usize) -> *mut c_void;
    fn pgm_index_uint32_destroy(pgm: *mut c_void);
    fn pgm_index_uint32_search(pgm: *const c_void, q: u32) -> ApproxPos;
    fn pgm_index_uint32_size_in_bytes(pgm: *const c_void) -> usize;
}

/// Owning handle to a per-column PGM model.
pub struct PgmF32 {
    handle: *mut c_void,
    n: usize,
}

// SAFETY: PGM index is read-only after construction; the C wrapper has no
// internal mutable state visible across calls. Send + Sync are sound.
unsafe impl Send for PgmF32 {}
unsafe impl Sync for PgmF32 {}

impl PgmF32 {
    /// Build a PGM model over a sorted f32 slice. `epsilon` is the model error
    /// bound — search returns a window of size at most `2 * epsilon + 1` to
    /// scan locally. Recommended starting value: 32.
    ///
    /// Caller must ensure `values` is sorted ascending and contains only
    /// non-negative finite values (CDFs in [0, 1]).
    pub fn build(values: &[f32], epsilon: usize) -> Self {
        // f32 → u32 bitcast preserves order for non-negative finite values.
        let bits: Vec<u32> = values.iter().map(|&v| v.to_bits()).collect();
        let handle = unsafe { pgm_index_uint32_create(bits.as_ptr(), bits.len(), epsilon) };
        Self { handle, n: values.len() }
    }

    /// Approximate position of `target` in the original sorted slice.
    /// `result.lo .. result.hi` is the local window the caller should scan.
    #[inline]
    pub fn search(&self, target: f32) -> ApproxPos {
        let q = target.to_bits();
        unsafe { pgm_index_uint32_search(self.handle, q) }
    }

    pub fn size_in_bytes(&self) -> usize {
        unsafe { pgm_index_uint32_size_in_bytes(self.handle) }
    }

    pub fn n(&self) -> usize {
        self.n
    }
}

impl Drop for PgmF32 {
    fn drop(&mut self) {
        if !self.handle.is_null() {
            unsafe { pgm_index_uint32_destroy(self.handle) };
            self.handle = std::ptr::null_mut();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn build_and_search_finds_approx_pos() {
        // Sorted CDF-style values in [0, 1].
        let values: Vec<f32> = (0..1000).map(|i| i as f32 / 1000.0).collect();
        let pgm = PgmF32::build(&values, 32);
        // Search for a value in the middle.
        let r = pgm.search(0.5);
        // The exact position is 500. PGM guarantees |r.pos - 500| <= epsilon.
        assert!(r.lo <= 500, "lo {} > 500", r.lo);
        assert!(r.hi >= 500, "hi {} < 500", r.hi);
        assert!(r.hi - r.lo <= 2 * 32 + 2, "window too wide: {}", r.hi - r.lo);
    }

    #[test]
    fn search_at_boundaries() {
        let values: Vec<f32> = vec![0.0, 0.25, 0.5, 0.75, 1.0];
        let pgm = PgmF32::build(&values, 4);
        // Below smallest
        let r = pgm.search(0.0);
        assert!(r.lo == 0);
        // At/above largest
        let r = pgm.search(1.0);
        assert!(r.hi >= 4);
    }
}
