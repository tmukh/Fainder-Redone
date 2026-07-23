# Fainder-Redone: A Hardware-Conscious Rust Port of Fainder

Master's thesis artefact (TU Berlin, DIMA group). A Rust re-implementation of the query phase of
[Fainder (VLDB 2024)](https://doi.org/10.14778/3681954.3681999), used as the empirical vehicle for
a perf-counter-grounded ablation study of hardware-conscious optimisations on a two-socket
Sapphire Rapids server.

- **Author:** Tarik Abu Mukh
- **Advisor:** Lennart Behme
- **Upstream:** forked from [lbhm/fainder](https://github.com/lbhm/fainder) (reference Python implementation)

## What this repository contains

- A **Rust query engine** for Fainder's percentile predicates, exposed to Python via PyO3 and
  interface-compatible with the reference implementation
- **Bitwise-identical results** to the Python reference across all tested workloads
  (correctness gate runs before every timed measurement)
- The **measurement campaign** behind the thesis:
  - four hardware performance ceilings (single-thread compute / L1 latency, shared L3 capacity,
    on-socket memory-traffic pressure, cross-socket UPI)
  - five negative-composability instances on five hardware axes
  - a pre-flight ceiling-identification methodology
  - a dispatch-on-regime policy (23/24 cells within 5%, incl. out-of-distribution validation)
- **Headline numbers** (t=16, three calibration datasets): 530–598× end-to-end vs. the Python
  baseline (dominated by Python-side result materialisation), 22.7× / 4.6× / 1.34× search-phase,
  ~4.7× rebinning-kernel speedup (~2.2× at 5M histograms)

## Repository layout

- `src/` — Rust engine: row-centric, column-centric, query-batch, and morsel execution engines;
  all ablation variants behind Cargo feature flags
- `fainder/` — Python package (upstream Fainder plus Rust backend dispatch and flat-binary
  `.fidx` index I/O)
- `scripts/` — benchmark and sweep drivers used in the campaign (written for the measurement
  server; paths are machine-specific, kept for provenance)
- `analysis/` — figure generation from the measurement database + walkthrough notebooks
- `logs/bench.db` — SQLite ground truth of the campaign (all measurements; 5-rep median
  methodology). Every number in the thesis traces back to a row here
- `Thesis tex/` — thesis LaTeX source
- `experiments/` — upstream Fainder paper experiment suite (unmodified)
- `tests/` — correctness tests against the reference implementation

## Build

```bash
virtualenv venv && source venv/bin/activate
pip install -e .
maturin develop --release                 # default build (SoA, f32, scalar search)
```

Ablation builds select Cargo features, e.g.:

```bash
maturin develop --release --features f16
maturin develop --release --features "pooled f16 simd pin-cores cluster-prefetch mimalloc"  # best-combo
```

The full feature-flag matrix is documented in the thesis (Methodology chapter and Appendix A).

## Reproducing measurements

- Set `FAINDER_NUM_THREADS` for the Rayon pool; `FAINDER_SUPPRESS_RESULTS=1` isolates the
  search phase (used for all ceiling ablations)
- `scripts/bench.py` runs one `(threads, build, dataset)` cell under `perf stat` and appends to
  `logs/bench.db`
- Figures regenerate from `bench.db` without re-running experiments:
  `python analysis/gen_ch4_thesis_plots.py`
- Datasets derive from the [GitTables](https://gittables.github.io/) corpus; see the thesis
  (Methodology chapter) for the derivation pipeline

## Citation

If you use this work, cite the original Fainder paper:

```bibtex
@article{behme_fainder_2024,
    title        = {Fainder: A Fast and Accurate Index for Distribution-Aware Dataset Search},
    author       = {Behme, Lennart and Galhotra, Sainyam and Beedkar, Kaustubh and Markl, Volker},
    year         = 2024,
    journal      = {Proc. VLDB Endow.},
    volume       = 17,
    number       = 11,
    pages        = {3269--3282},
    doi          = {10.14778/3681954.3681999}
}
```
