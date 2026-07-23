use numpy::{PyReadonlyArray1, PyReadonlyArray2};
use pyo3::prelude::*;
#[cfg(feature = "f16")]
use half::f16;

#[cfg(all(feature = "packed-ids", feature = "aos"))]
compile_error!("features `packed-ids` and `aos` are mutually exclusive (aos stores entries as (f32, u32) tuples; packed-ids needs a separate id buffer)");

#[cfg(all(feature = "local-ids", feature = "aos"))]
compile_error!("features `local-ids` and `aos` are mutually exclusive");

#[cfg(all(feature = "local-ids-bench", feature = "aos"))]
compile_error!("features `local-ids-bench` and `aos` are mutually exclusive");

#[cfg(all(feature = "local-ids-noalloc", feature = "aos"))]
compile_error!("features `local-ids-noalloc` and `aos` are mutually exclusive");

#[cfg(all(feature = "local-ids", feature = "local-ids-bench"))]
compile_error!("features `local-ids` and `local-ids-bench` are mutually exclusive (they differ in extend_ids: lookup vs no-lookup)");

#[cfg(all(feature = "local-ids", feature = "packed-ids"))]
compile_error!("features `local-ids` and `packed-ids` are mutually exclusive (local-ids replaces packed-ids' global storage with per-cluster local IDs)");

#[cfg(all(feature = "local-ids-bench", feature = "packed-ids"))]
compile_error!("features `local-ids-bench` and `packed-ids` are mutually exclusive");

#[cfg(all(feature = "local-ids-noalloc", feature = "packed-ids"))]
compile_error!("features `local-ids-noalloc` and `packed-ids` are mutually exclusive");

#[cfg(all(feature = "local-ids-noalloc", feature = "local-ids"))]
compile_error!("features `local-ids-noalloc` and `local-ids` are mutually exclusive");

#[cfg(all(feature = "local-ids-noalloc", feature = "local-ids-bench"))]
compile_error!("features `local-ids-noalloc` and `local-ids-bench` are mutually exclusive");

// ── SubIndex: two layouts controlled by Cargo feature flag ───────────────────
//
// SoA (default): separate contiguous arrays for values and indices.
//   Binary search over values[] touches only f32 elements → cache line holds 16
//   values → prefetcher loads ahead predictively.
//
// AoS (--features aos): interleaved (value, index) pairs.
//   Binary search must step over 8-byte pairs → each cache line holds only 8
//   useful f32 values (the other 4 bytes per entry are index data). This is the
//   control condition for the memory-layout ablation.
//
// Padding for SIMD (`stride` field):
//   With `--features simd`, each SoA column is followed by 32 sentinel entries
//   (`+∞` values, `0` indices). This lets the AVX-512 / AVX-512_FP16 final
//   stage of the binary search read 32 lanes past the actual data without
//   bounds checks; the sentinels never satisfy `< target` or `<= target` for
//   any finite target so they don't perturb the partition point. `stride` is
//   then `n_hists + 32`; without `simd`, `stride == n_hists`.

/// Number of `+∞` sentinel entries to append to each SoA column when the
/// `simd` feature is enabled. 32 covers AVX-512 (16 × f32) and AVX-512_FP16
/// (32 × f16) full-width vector loads at the final stage of binary search.
#[cfg(feature = "simd")]
pub const SOA_PAD: usize = 32;
#[cfg(not(feature = "simd"))]
pub const SOA_PAD: usize = 0;

#[cfg(not(any(feature = "aos", feature = "f16")))]
pub struct SubIndex {
    /// Column-major flattened percentile values: [bin0·hist0, bin0·hist1, …, bin1·hist0, …]
    /// Each column is padded with `SOA_PAD` `f32::INFINITY` sentinels at the tail.
    pub values: Vec<f32>,
    /// Column-major flattened histogram ids, same layout as values (padding = 0).
    /// Replaced by `packed_ids` + `bit_width` + `stride_words` under any of
    /// `--features packed-ids` / `local-ids` / `local-ids-bench`.
    #[cfg(not(any(feature = "packed-ids", feature = "local-ids", feature = "local-ids-bench", feature = "local-ids-noalloc")))]
    pub indices: Vec<u32>,
    /// Per-column storage stride (`n_hists + SOA_PAD`). Use this to compute
    /// per-bin offsets: `idx_offset = bin_idx * stride`.
    pub stride: usize,
    /// Bit-packed ids: one u32 buffer per SubIndex covering all `n_bins` columns.
    /// Column k starts at word index `k * stride_words`. Trailing pad word at the
    /// very end of the buffer makes the cross-word load in `packed::append_range`
    /// safe at the last id of the last column.
    ///
    /// Under `packed-ids`: each entry is a global histogram id, bit_width =
    /// ceil(log2(max_global_id + 1)).
    ///
    /// Under `local-ids` / `local-ids-bench`: each entry is a per-cluster
    /// LOCAL id in 0..n_hists, bit_width = ceil(log2(n_hists + 1)). The
    /// local→global lookup is in `local_to_global`.
    #[cfg(any(feature = "packed-ids", feature = "local-ids", feature = "local-ids-bench", feature = "local-ids-noalloc"))]
    pub packed_ids: Vec<u32>,
    #[cfg(any(feature = "packed-ids", feature = "local-ids", feature = "local-ids-bench", feature = "local-ids-noalloc"))]
    pub bit_width: u8,
    #[cfg(any(feature = "packed-ids", feature = "local-ids", feature = "local-ids-bench", feature = "local-ids-noalloc"))]
    pub stride_words: usize,
    /// Per-cluster lookup table: `local_to_global[local_id] = global_id`.
    /// Size n_hists × 4B per SubIndex (~20KB worst case on c256_56gb largest
    /// cluster, fits L1d 48KB on Sapphire Rapids 8468H within a cluster's
    /// processing window — see §3.11 mechanism prediction).
    /// Only present under `local-ids` / `local-ids-bench`.
    #[cfg(any(feature = "local-ids", feature = "local-ids-bench"))]
    pub local_to_global: Vec<u32>,
    /// One PGM-index model per bin (`Vec` length = `n_bins`). Each model
    /// covers the `n_hists` sorted f32 percentile values for that bin's
    /// column. Search returns an `ApproxPos` window of ≤ `2*ε+1` elements;
    /// caller does a small local scan to refine to the exact partition point.
    /// Only present when built with `--features pgm`.
    #[cfg(feature = "pgm")]
    pub pgm_per_bin: Vec<crate::pgm::PgmF32>,
}

#[cfg(not(any(feature = "aos", feature = "f16")))]
impl SubIndex {
    #[inline]
    pub fn len(&self) -> usize { self.values.len() }
    #[inline]
    pub fn stride(&self) -> usize { self.stride }

    /// Append ids `[start..end)` from column `bin_idx` to `out`.
    ///
    /// Four-way feature dispatch:
    /// - default: unpacked u32 → `extend_from_slice`.
    /// - `packed-ids`: packed global ids → `append_range`.
    /// - `local-ids`: packed local ids → `append_range_local_to_global`
    ///   (decode + L1 lookup per id, emits global ids).
    /// - `local-ids-bench`: packed local ids → `append_range`
    ///   (no lookup; emits LOCAL ids — bench-mode-only correctness).
    #[inline]
    pub fn extend_ids(&self, out: &mut Vec<u32>, bin_idx: usize, _n_hists: usize, start: usize, end: usize) {
        #[cfg(not(any(feature = "packed-ids", feature = "local-ids", feature = "local-ids-bench", feature = "local-ids-noalloc")))]
        {
            let off = bin_idx * self.stride + start;
            let n = end - start;
            out.extend_from_slice(&self.indices[off..off + n]);
        }
        #[cfg(feature = "packed-ids")]
        {
            let col_off = bin_idx * self.stride_words;
            crate::packed::append_range(out, &self.packed_ids, col_off, self.bit_width, start, end);
        }
        #[cfg(feature = "local-ids")]
        {
            let col_off = bin_idx * self.stride_words;
            crate::packed::append_range_local_to_global(
                out, &self.packed_ids, col_off, self.bit_width, start, end, &self.local_to_global,
            );
        }
        #[cfg(feature = "local-ids-bench")]
        {
            let col_off = bin_idx * self.stride_words;
            crate::packed::append_range(out, &self.packed_ids, col_off, self.bit_width, start, end);
        }
        #[cfg(feature = "local-ids-noalloc")]
        {
            // Identical decode path to local-ids-bench; the only difference
            // is build-time: local_to_global is NOT allocated. Used as a
            // control to disambiguate whether the multi-thread regression
            // observed on local-ids-bench comes from the 13-bit decoder
            // itself or from the resident local_to_global pages.
            let col_off = bin_idx * self.stride_words;
            crate::packed::append_range(out, &self.packed_ids, col_off, self.bit_width, start, end);
        }
    }
}

// f16 variant: values stored as half-precision to halve the index memory footprint.
// Binary search compares directly in f16 (matching Python's
// `np.searchsorted(col_f16, np.float16(target))`).
#[cfg(all(feature = "f16", not(feature = "aos")))]
pub struct SubIndex {
    /// Column-major flattened percentile values stored as f16 (half precision).
    /// Each column is padded with `SOA_PAD` `f16::INFINITY` sentinels at the tail.
    pub values: Vec<f16>,
    /// Column-major flattened histogram ids, same layout as values (padding = 0).
    #[cfg(not(any(feature = "packed-ids", feature = "local-ids", feature = "local-ids-bench", feature = "local-ids-noalloc")))]
    pub indices: Vec<u32>,
    pub stride: usize,
    #[cfg(any(feature = "packed-ids", feature = "local-ids", feature = "local-ids-bench", feature = "local-ids-noalloc"))]
    pub packed_ids: Vec<u32>,
    #[cfg(any(feature = "packed-ids", feature = "local-ids", feature = "local-ids-bench", feature = "local-ids-noalloc"))]
    pub bit_width: u8,
    #[cfg(any(feature = "packed-ids", feature = "local-ids", feature = "local-ids-bench", feature = "local-ids-noalloc"))]
    pub stride_words: usize,
    #[cfg(any(feature = "local-ids", feature = "local-ids-bench"))]
    pub local_to_global: Vec<u32>,
}

#[cfg(all(feature = "f16", not(feature = "aos")))]
impl SubIndex {
    #[inline]
    pub fn len(&self) -> usize { self.values.len() }
    #[inline]
    pub fn stride(&self) -> usize { self.stride }

    #[inline]
    pub fn extend_ids(&self, out: &mut Vec<u32>, bin_idx: usize, _n_hists: usize, start: usize, end: usize) {
        #[cfg(not(any(feature = "packed-ids", feature = "local-ids", feature = "local-ids-bench", feature = "local-ids-noalloc")))]
        {
            let off = bin_idx * self.stride + start;
            let n = end - start;
            out.extend_from_slice(&self.indices[off..off + n]);
        }
        #[cfg(feature = "packed-ids")]
        {
            let col_off = bin_idx * self.stride_words;
            crate::packed::append_range(out, &self.packed_ids, col_off, self.bit_width, start, end);
        }
        #[cfg(feature = "local-ids")]
        {
            let col_off = bin_idx * self.stride_words;
            crate::packed::append_range_local_to_global(
                out, &self.packed_ids, col_off, self.bit_width, start, end, &self.local_to_global,
            );
        }
        #[cfg(feature = "local-ids-bench")]
        {
            let col_off = bin_idx * self.stride_words;
            crate::packed::append_range(out, &self.packed_ids, col_off, self.bit_width, start, end);
        }
        #[cfg(feature = "local-ids-noalloc")]
        {
            // Identical decode path to local-ids-bench; the only difference
            // is build-time: local_to_global is NOT allocated. Used as a
            // control to disambiguate whether the multi-thread regression
            // observed on local-ids-bench comes from the 13-bit decoder
            // itself or from the resident local_to_global pages.
            let col_off = bin_idx * self.stride_words;
            crate::packed::append_range(out, &self.packed_ids, col_off, self.bit_width, start, end);
        }
    }
}

#[cfg(feature = "aos")]
pub struct SubIndex {
    /// Column-major flattened (value, index) pairs: [(bin0·hist0_val, id), (bin0·hist1_val, id), …]
    pub entries: Vec<(f32, u32)>,
    pub stride: usize,
}

#[cfg(feature = "aos")]
impl SubIndex {
    #[inline]
    pub fn len(&self) -> usize { self.entries.len() }
    #[inline]
    pub fn stride(&self) -> usize { self.stride }
}

// ─────────────────────────────────────────────────────────────────────────────

#[pyclass]
pub struct FainderIndex {
    cluster_sizes: Vec<usize>,
    bins: Vec<Vec<f64>>,
    variants: Vec<Vec<SubIndex>>,
}

#[pymethods]
impl FainderIndex {
    #[new]
    pub fn new(
        pctl_index: &Bound<'_, pyo3::types::PyList>,
        cluster_bins: Vec<PyReadonlyArray1<f64>>,
    ) -> PyResult<Self> {
        let n_clusters = pctl_index.len();

        if cluster_bins.len() != n_clusters {
            return Err(pyo3::exceptions::PyValueError::new_err("Bins length mismatch"));
        }

        let mut bins_data: Vec<Vec<f64>> = Vec::with_capacity(n_clusters);
        for b in cluster_bins {
            bins_data.push(b.as_array().iter().copied().collect());
        }

        let mut cluster_sizes: Vec<usize> = Vec::with_capacity(n_clusters);
        let mut all_variants: Vec<Vec<SubIndex>> = Vec::with_capacity(n_clusters);

        for (cluster_idx, cluster_item) in pctl_index.iter().enumerate() {
            let variants_list = cluster_item
                .downcast::<pyo3::types::PyList>()
                .map_err(|_| pyo3::exceptions::PyTypeError::new_err("Expected list of variants"))?;

            let mut cluster_subindices: Vec<SubIndex> = Vec::with_capacity(variants_list.len());
            let mut expected_n_hists = 0usize;
            let mut first = true;

            for variant_item in variants_list.iter() {
                let tuple = variant_item
                    .downcast::<pyo3::types::PyTuple>()
                    .map_err(|_| {
                        pyo3::exceptions::PyTypeError::new_err("Expected tuple(FArray, UInt32Array)")
                    })?;

                let p_array = tuple.get_item(0)?.extract::<PyReadonlyArray2<f32>>()?;
                let i_array = tuple.get_item(1)?.extract::<PyReadonlyArray2<u32>>()?;

                let p   = p_array.as_array();
                let ids = i_array.as_array();

                let n_hists = p.shape()[0];
                let n_bins  = p.shape()[1];

                if first {
                    expected_n_hists = n_hists;
                    cluster_sizes.push(n_hists);
                    first = false;
                } else if n_hists != expected_n_hists {
                    return Err(pyo3::exceptions::PyValueError::new_err(format!(
                        "Variant n_hists mismatch in cluster {}", cluster_idx
                    )));
                }

                if ids.shape()[0] != n_hists || ids.shape()[1] != n_bins {
                    return Err(pyo3::exceptions::PyValueError::new_err(
                        "pctl_index arrays shape mismatch within variant",
                    ));
                }

                // ── OPTIMIZATION: Column-Major Memory Flattening ──────────────
                // We flatten [n_hists][n_bins] in column-major order so that
                // for a given bin_idx the slice [offset .. offset+n_hists] is
                // contiguous in memory. This matches the query hot-loop access
                // pattern and lets the CPU prefetcher work predictively.
                //
                // SoA: values and indices stored in separate arrays.
                //   → binary search over values[] sees only f32 elements.
                //
                // AoS: (value, index) pairs interleaved.
                //   → binary search sees 8-byte pairs; index data pollutes
                //     cache lines during the search phase. (ablation control)

                #[cfg(not(any(feature = "aos", feature = "f16")))]
                {
                    let stride = n_hists + SOA_PAD;
                    let mut val_vec: Vec<f32> = Vec::with_capacity(stride * n_bins);
                    #[cfg(not(any(feature = "packed-ids", feature = "local-ids", feature = "local-ids-bench", feature = "local-ids-noalloc")))]
                    let mut idx_vec: Vec<u32> = Vec::with_capacity(stride * n_bins);
                    for b in 0..n_bins {
                        for h in 0..n_hists {
                            val_vec.push(p[[h, b]]);
                            #[cfg(not(any(feature = "packed-ids", feature = "local-ids", feature = "local-ids-bench", feature = "local-ids-noalloc")))]
                            idx_vec.push(ids[[h, b]]);
                        }
                        // Pad column tail with +∞ values / 0 indices so SIMD final
                        // stages can read SOA_PAD lanes past the actual data safely.
                        for _ in 0..SOA_PAD {
                            val_vec.push(f32::INFINITY);
                            #[cfg(not(any(feature = "packed-ids", feature = "local-ids", feature = "local-ids-bench", feature = "local-ids-noalloc")))]
                            idx_vec.push(0);
                        }
                    }

                    // Bit-pack ids per cluster. Width depends on feature mode:
                    //   --features packed-ids: ceil(log2(max_global_id + 1)) ≈ 20 bits
                    //   --features local-ids / local-ids-bench: ceil(log2(n_hists + 1))
                    //     ≈ 13 bits. Packed entries are per-cluster LOCAL ids; an
                    //     auxiliary `local_to_global` lookup table is built so the
                    //     emit path (packed::append_range_local_to_global) can
                    //     decode + lookup → global. Under local-ids-bench, the
                    //     emit short-circuits the lookup (suppress-mode-only
                    //     correctness — see §3.11).
                    #[cfg(feature = "packed-ids")]
                    let (packed_ids, bit_width, stride_words) = {
                        let mut max_id: u32 = 0;
                        for b in 0..n_bins {
                            for h in 0..n_hists {
                                let v = ids[[h, b]];
                                if v > max_id { max_id = v; }
                            }
                        }
                        let bw = crate::packed::bit_width_for((max_id as usize).saturating_add(1));
                        let sw = crate::packed::stride_words(n_hists, bw);
                        let mut packed = vec![0u32; sw * n_bins + 1];
                        for b in 0..n_bins {
                            let col_ids: Vec<u32> = (0..n_hists).map(|h| ids[[h, b]]).collect();
                            let off = b * sw;
                            crate::packed::pack_col(&col_ids, bw, &mut packed[off..off + sw]);
                        }
                        (packed, bw, sw)
                    };

                    #[cfg(any(feature = "local-ids", feature = "local-ids-bench"))]
                    let (packed_ids, bit_width, stride_words, local_to_global) = {
                        // Canonical local-ID assignment: histogram at row h of
                        // bin 0 gets local id = h. The same histogram appears at
                        // some other row h' in bin b; we map ids[[h', b]] → h via
                        // global_to_local at pack time so the packed entry at
                        // position (b, h') is the local id `h`. local_to_global
                        // is then just bin 0's id column.
                        let mut local_to_global: Vec<u32> = Vec::with_capacity(n_hists);
                        let mut global_to_local: std::collections::HashMap<u32, u32> =
                            std::collections::HashMap::with_capacity(n_hists);
                        for h in 0..n_hists {
                            let g = ids[[h, 0]];
                            local_to_global.push(g);
                            global_to_local.insert(g, h as u32);
                        }
                        let bw = crate::packed::bit_width_for(n_hists.saturating_add(1));
                        let sw = crate::packed::stride_words(n_hists, bw);
                        let mut packed = vec![0u32; sw * n_bins + 1];
                        for b in 0..n_bins {
                            let col_ids: Vec<u32> = (0..n_hists).map(|h| {
                                *global_to_local.get(&ids[[h, b]]).expect(
                                    "local-ids: bin b id missing from bin 0 mapping — malformed pctl_index"
                                )
                            }).collect();
                            let off = b * sw;
                            crate::packed::pack_col(&col_ids, bw, &mut packed[off..off + sw]);
                        }
                        (packed, bw, sw, local_to_global)
                    };

                    // Same as local-ids-bench but DROPS local_to_global after
                    // packing. Used to disambiguate the local-ids-bench
                    // multi-thread regression: if local-ids-noalloc still
                    // regresses, the resident table isn't responsible.
                    #[cfg(feature = "local-ids-noalloc")]
                    let (packed_ids, bit_width, stride_words) = {
                        let mut global_to_local: std::collections::HashMap<u32, u32> =
                            std::collections::HashMap::with_capacity(n_hists);
                        for h in 0..n_hists {
                            global_to_local.insert(ids[[h, 0]], h as u32);
                        }
                        let bw = crate::packed::bit_width_for(n_hists.saturating_add(1));
                        let sw = crate::packed::stride_words(n_hists, bw);
                        let mut packed = vec![0u32; sw * n_bins + 1];
                        for b in 0..n_bins {
                            let col_ids: Vec<u32> = (0..n_hists).map(|h| {
                                *global_to_local.get(&ids[[h, b]]).expect(
                                    "local-ids-noalloc: bin b id missing from bin 0 mapping"
                                )
                            }).collect();
                            let off = b * sw;
                            crate::packed::pack_col(&col_ids, bw, &mut packed[off..off + sw]);
                        }
                        // global_to_local goes out of scope and is freed here.
                        (packed, bw, sw)
                    };

                    // PGM model construction: one model per bin, parallel build via Rayon.
                    // ε read from FAINDER_PGM_EPSILON env var (default 32). Local scan after
                    // PGM lookup covers ≤ 2·ε+2 elements; 1 cache line at ε=32 (64×4B = 256B).
                    #[cfg(feature = "pgm")]
                    let pgm_per_bin: Vec<crate::pgm::PgmF32> = {
                        use rayon::prelude::*;
                        let pgm_epsilon: usize = std::env::var("FAINDER_PGM_EPSILON")
                            .ok().and_then(|s| s.parse().ok()).unwrap_or(32);
                        (0..n_bins).into_par_iter().map(|b| {
                            let start = b * stride;
                            let col = &val_vec[start .. start + n_hists];
                            crate::pgm::PgmF32::build(col, pgm_epsilon)
                        }).collect()
                    };

                    cluster_subindices.push(SubIndex {
                        values: val_vec,
                        #[cfg(not(any(feature = "packed-ids", feature = "local-ids", feature = "local-ids-bench", feature = "local-ids-noalloc")))]
                        indices: idx_vec,
                        stride,
                        #[cfg(any(feature = "packed-ids", feature = "local-ids", feature = "local-ids-bench", feature = "local-ids-noalloc"))]
                        packed_ids,
                        #[cfg(any(feature = "packed-ids", feature = "local-ids", feature = "local-ids-bench", feature = "local-ids-noalloc"))]
                        bit_width,
                        #[cfg(any(feature = "packed-ids", feature = "local-ids", feature = "local-ids-bench", feature = "local-ids-noalloc"))]
                        stride_words,
                        #[cfg(any(feature = "local-ids", feature = "local-ids-bench"))]
                        local_to_global,
                        #[cfg(feature = "pgm")]
                        pgm_per_bin,
                    });
                }

                #[cfg(all(feature = "f16", not(feature = "aos")))]
                {
                    let stride = n_hists + SOA_PAD;
                    let mut val_vec: Vec<f16> = Vec::with_capacity(stride * n_bins);
                    #[cfg(not(any(feature = "packed-ids", feature = "local-ids", feature = "local-ids-bench", feature = "local-ids-noalloc")))]
                    let mut idx_vec: Vec<u32> = Vec::with_capacity(stride * n_bins);
                    for b in 0..n_bins {
                        for h in 0..n_hists {
                            val_vec.push(f16::from_f32(p[[h, b]]));
                            #[cfg(not(any(feature = "packed-ids", feature = "local-ids", feature = "local-ids-bench", feature = "local-ids-noalloc")))]
                            idx_vec.push(ids[[h, b]]);
                        }
                        for _ in 0..SOA_PAD {
                            val_vec.push(f16::INFINITY);
                            #[cfg(not(any(feature = "packed-ids", feature = "local-ids", feature = "local-ids-bench", feature = "local-ids-noalloc")))]
                            idx_vec.push(0);
                        }
                    }
                    #[cfg(feature = "packed-ids")]
                    let (packed_ids, bit_width, stride_words) = {
                        let mut max_id: u32 = 0;
                        for b in 0..n_bins {
                            for h in 0..n_hists {
                                let v = ids[[h, b]];
                                if v > max_id { max_id = v; }
                            }
                        }
                        let bw = crate::packed::bit_width_for((max_id as usize).saturating_add(1));
                        let sw = crate::packed::stride_words(n_hists, bw);
                        let mut packed = vec![0u32; sw * n_bins + 1];
                        for b in 0..n_bins {
                            let col_ids: Vec<u32> = (0..n_hists).map(|h| ids[[h, b]]).collect();
                            let off = b * sw;
                            crate::packed::pack_col(&col_ids, bw, &mut packed[off..off + sw]);
                        }
                        (packed, bw, sw)
                    };
                    #[cfg(any(feature = "local-ids", feature = "local-ids-bench"))]
                    let (packed_ids, bit_width, stride_words, local_to_global) = {
                        let mut local_to_global: Vec<u32> = Vec::with_capacity(n_hists);
                        let mut global_to_local: std::collections::HashMap<u32, u32> =
                            std::collections::HashMap::with_capacity(n_hists);
                        for h in 0..n_hists {
                            let g = ids[[h, 0]];
                            local_to_global.push(g);
                            global_to_local.insert(g, h as u32);
                        }
                        let bw = crate::packed::bit_width_for(n_hists.saturating_add(1));
                        let sw = crate::packed::stride_words(n_hists, bw);
                        let mut packed = vec![0u32; sw * n_bins + 1];
                        for b in 0..n_bins {
                            let col_ids: Vec<u32> = (0..n_hists).map(|h| {
                                *global_to_local.get(&ids[[h, b]]).expect(
                                    "local-ids: bin b id missing from bin 0 mapping"
                                )
                            }).collect();
                            let off = b * sw;
                            crate::packed::pack_col(&col_ids, bw, &mut packed[off..off + sw]);
                        }
                        (packed, bw, sw, local_to_global)
                    };
                    #[cfg(feature = "local-ids-noalloc")]
                    let (packed_ids, bit_width, stride_words) = {
                        let mut global_to_local: std::collections::HashMap<u32, u32> =
                            std::collections::HashMap::with_capacity(n_hists);
                        for h in 0..n_hists {
                            global_to_local.insert(ids[[h, 0]], h as u32);
                        }
                        let bw = crate::packed::bit_width_for(n_hists.saturating_add(1));
                        let sw = crate::packed::stride_words(n_hists, bw);
                        let mut packed = vec![0u32; sw * n_bins + 1];
                        for b in 0..n_bins {
                            let col_ids: Vec<u32> = (0..n_hists).map(|h| {
                                *global_to_local.get(&ids[[h, b]]).expect(
                                    "local-ids-noalloc: bin b id missing from bin 0 mapping"
                                )
                            }).collect();
                            let off = b * sw;
                            crate::packed::pack_col(&col_ids, bw, &mut packed[off..off + sw]);
                        }
                        (packed, bw, sw)
                    };
                    cluster_subindices.push(SubIndex {
                        values: val_vec,
                        #[cfg(not(any(feature = "packed-ids", feature = "local-ids", feature = "local-ids-bench", feature = "local-ids-noalloc")))]
                        indices: idx_vec,
                        stride,
                        #[cfg(any(feature = "packed-ids", feature = "local-ids", feature = "local-ids-bench", feature = "local-ids-noalloc"))]
                        packed_ids,
                        #[cfg(any(feature = "packed-ids", feature = "local-ids", feature = "local-ids-bench", feature = "local-ids-noalloc"))]
                        bit_width,
                        #[cfg(any(feature = "packed-ids", feature = "local-ids", feature = "local-ids-bench", feature = "local-ids-noalloc"))]
                        stride_words,
                        #[cfg(any(feature = "local-ids", feature = "local-ids-bench"))]
                        local_to_global,
                    });
                }

                #[cfg(feature = "aos")]
                {
                    // AoS doesn't benefit from SIMD final-stage padding; stride == n_hists.
                    let stride = n_hists;
                    let mut entries: Vec<(f32, u32)> = Vec::with_capacity(n_hists * n_bins);
                    for b in 0..n_bins {
                        for h in 0..n_hists {
                            entries.push((p[[h, b]], ids[[h, b]]));
                        }
                    }
                    cluster_subindices.push(SubIndex { entries, stride });
                }

            }
            all_variants.push(cluster_subindices);
        }

        Ok(Self { cluster_sizes, bins: bins_data, variants: all_variants })
    }

    #[pyo3(signature = (queries, index_mode, num_threads=None, columnar=false, suppress_results=false))]
    pub fn run_queries<'py>(
        &self,
        py: Python<'py>,
        queries: Vec<(f32, String, f64)>,
        index_mode: &str,
        num_threads: Option<usize>,
        columnar: bool,
        suppress_results: bool,
    ) -> PyResult<Vec<PyObject>> {
        crate::engine::execute_queries(py, self, queries, index_mode, num_threads, columnar, suppress_results)
    }
}

impl FainderIndex {
    #[inline] pub fn get_bins(&self, c: usize) -> &[f64] { &self.bins[c] }
    #[inline] pub fn get_subindex(&self, c: usize, v: usize) -> Option<&SubIndex> {
        self.variants.get(c)?.get(v)
    }
    #[inline] pub fn n_clusters(&self) -> usize { self.bins.len() }
    #[inline] pub fn get_cluster_size(&self, c: usize) -> usize { self.cluster_sizes[c] }
}
