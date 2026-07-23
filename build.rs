// Build the C++ wrapper for PGM-index when --features pgm is set.
//
// The PGM-index library is header-only C++17. Their c-interface/cpgm.cpp
// provides a stable C ABI for {int32, int64, uint32, uint64} index types.
// We use the uint32 path with f32→u32 bitcast (CDF percentile values are
// always non-negative finite, so unsigned bit ordering preserves f32 order).
//
// No-op when the `pgm` feature is disabled (zero compile-time cost for
// non-PGM builds).

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    if std::env::var_os("CARGO_FEATURE_PGM").is_none() {
        return;
    }

    let pgm_root = "vendor/PGM-index";
    let cpgm_src = format!("{pgm_root}/c-interface/cpgm.cpp");
    let pgm_include = format!("{pgm_root}/include");
    let cpgm_include = format!("{pgm_root}/c-interface");

    println!("cargo:rerun-if-changed={cpgm_src}");
    println!("cargo:rerun-if-changed={pgm_include}/pgm/pgm_index.hpp");

    cc::Build::new()
        .cpp(true)
        .std("c++17")
        .opt_level(3)
        .flag_if_supported("-march=native")
        .flag_if_supported("-fno-rtti")
        .file(&cpgm_src)
        .include(&pgm_include)
        .include(&cpgm_include)
        .compile("cpgm_static");
}
