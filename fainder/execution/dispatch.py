"""Dispatch-on-regime selector for Fainder Rust engines.

Given workload parameters (cluster count, total histogram count, thread count),
return the recommended Cargo build features and runtime env vars based on the
mechanism analysis in docs/RESULTS.md §3.9.8.

The §3.7-3.9 ablation campaign established that no single build is best across
the (dataset_size, thread_count) surface. Each ceiling on this hardware
(latency / bandwidth / HT / work-fragmentation) is best attacked by a
different technique; on c256_56gb three different engines win at three
different thread counts, with no engine within 5% of the regime-best at every
cell. Dispatch-on-regime is therefore the deployment recipe — not an
optimisation, but the only way to be near-optimal across the surface.

Empirical decision boundaries derived from bench.db medians (see
scripts/validate_dispatch.py):

- t > 96 (HT-active):                                 bestofsuite       (pin-cores avoids HT-sibling contention)
- 1 < t <= 32:                                        bestofsuite       (f16 + simd compress per-cluster work; binding ceiling is search-phase bandwidth)
- t = 1 AND n_hists >= 600K:                          query-batch K=64  (sequential cold-load amortisation; 2x faster than default on 56gb t=1)
- 32 < t <= 96 AND n_hists < 600K:                    bestofsuite       (still wins on 10gb/30gb at all t)
- 32 < t <= 96 AND n_hists >= 600K AND t == 64:       packed-ids        (DRAM-bandwidth ceiling binds; +emit-phase compression wins)
- 32 < t <= 96 AND n_hists >= 600K AND t in {65..96}: query-batch K=128 (work-fragmentation ceiling binds)
- otherwise:                                          bestofsuite       (default safe choice)

The 600K threshold separates n_hists distributions where the
work-fragmentation regime emerges (56gb has 770K) from those where
bestofsuite still dominates (30gb has 410K). The threshold is
workload-shaped — a different cluster-count or histograms-per-cluster
distribution would shift it. Re-running the campaign on a 4th dataset
(e.g. 80-120 GB) is the cheapest way to refine the boundary.
"""

from __future__ import annotations
from dataclasses import dataclass


@dataclass(frozen=True)
class EngineConfig:
    """Build recipe + runtime knobs for one regime cell.

    Fields:
        features: Space-separated Cargo feature list to pass to
                  ``maturin develop --features``. Empty string = default build.
        env:      Environment variables to set before invoking ``run-queries``.
        rationale: One-line explanation of the choice (for logging/audit).
        ceiling: The hardware ceiling this build addresses
                 ("bandwidth", "work-fragmentation", "HT-contention", or "latency").
    """
    features: str
    env: dict[str, str]
    rationale: str
    ceiling: str


# Empirical threshold separating regimes where the bandwidth + work-fragmentation
# ceilings emerge (n_hists >= 600K, observed on c256_56gb at 770K) from regimes
# where bestofsuite still dominates (c256_30gb at 410K is still in this region).
# Refining this with a 4th dataset between 410K and 770K would tighten the boundary.
BIG_DATA_HIST_COUNT = 600_000

# Bestofsuite feature set, used in multiple branches.
BESTOFSUITE_FEATURES = "pooled f16 simd pin-cores cluster-prefetch mimalloc"


def select_engine(
    *,
    n_clusters: int,
    n_hists: int,
    n_threads: int,
    n_queries: int = 10_000,
) -> EngineConfig:
    """Return the recommended build for a (regime) tuple.

    Args:
        n_clusters: Number of clusters in the loaded FainderIndex.
        n_hists: Total histogram count summed across clusters
                 (``sum(index.get_cluster_size(c) for c in range(n_clusters))``).
        n_threads: Configured thread count
                 (the value that will be passed to FAINDER_NUM_THREADS).
        n_queries: Number of queries in the batch about to be executed.
                   Reserved for future adaptive-K heuristics; not currently used.

    Returns:
        EngineConfig with the build features and env vars to deploy.
    """
    big_data = n_hists >= BIG_DATA_HIST_COUNT

    # HT-active regime (t > 96 on Sapphire Rapids 8468H): pin-cores'
    # deterministic physical-only plan beats default's OS-scheduled placement
    # (§3.8: default IPC drops to 0.43, bestofsuite stays usable).
    if n_threads > 96:
        return EngineConfig(
            features=BESTOFSUITE_FEATURES,
            env={},
            rationale=f"t={n_threads} > 96: HT-sibling contention is binding; pin-cores deterministic placement",
            ceiling="HT-contention",
        )

    # t=1 on medium-or-big data: query-batch's loop reorder amortises cluster
    # cold-load across K queries, no thread coordination overhead.  −40% on
    # 56gb t=1, −11% on 30gb t=1 (§3.9.4); 10gb t=1 (130K hists) prefers
    # bestofsuite, so use a lower threshold than BIG_DATA_HIST_COUNT here.
    if n_threads == 1 and n_hists >= 300_000:
        return EngineConfig(
            features="query-batch",
            env={"FAINDER_QUERY_BATCH": "64"},
            rationale=f"t=1 + n_hists={n_hists}: sequential cold-load amortisation via column-centric loop reorder",
            ceiling="work-fragmentation",
        )

    # Medium-to-high t on big data: the work-fragmentation/bandwidth split.
    # 56gb t=64 → packed-ids (16.6s); 56gb t≥65 → query-batch K=128 (16.2s).
    # This is the cleanest dispatch boundary in the campaign (§3.9.8).
    if big_data and n_threads >= 64:
        if n_threads <= 64:
            return EngineConfig(
                features="packed-ids",
                env={},
                rationale=f"t={n_threads} on big data: emit-phase bandwidth is binding; packed-ids reduces by ~37%",
                ceiling="bandwidth",
            )
        return EngineConfig(
            features="query-batch",
            env={"FAINDER_QUERY_BATCH": "128"},
            rationale=f"t={n_threads} on big data: work-fragmentation is binding; query-batch K=128",
            ceiling="work-fragmentation",
        )

    # Default (covers t<=32 always, and 32<t<=96 on small/medium data).
    # bestofsuite's f16+simd+pin-cores wins everywhere not covered by the
    # special-case branches above.
    return EngineConfig(
        features=BESTOFSUITE_FEATURES,
        env={},
        rationale=f"t={n_threads}, n_hists={n_hists}: bestofsuite's bandwidth attack dominates this regime",
        ceiling="bandwidth",
    )
