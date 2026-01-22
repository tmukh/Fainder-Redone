try:
    from fainder import fainder_core
except ImportError:
    import fainder_core

import numpy as np

RebinningIndex = fainder_core.RebinningIndex

print("Rust extension imported successfully!")
print(f"Index class: {RebinningIndex}")

# Mock data to test initialization
# pctl_index: list[tuple[F32Array, UInt32Array]]
# cluster_bins: list[F64Array]

n_hists = 10
n_bins = 5
n_clusters = 2

pctl_index = []
cluster_bins = []

for i in range(n_clusters):
    bins = np.linspace(0, 100, n_bins + 1, dtype=np.float64)
    cluster_bins.append(bins)

    # Layout: (n_hists, n_bins)
    pctls = np.random.rand(n_hists, n_bins).astype(np.float32)
    ids = np.random.randint(0, 1000, (n_hists, n_bins), dtype=np.uint32)

    pctl_index.append((pctls, ids))

print("Initializing Rust Index...")
# Rust signature: new(pctl_index: Vec<(PyReadonlyArray2<f32>, PyReadonlyArray2<u32>)>, cluster_bins: Vec<PyReadonlyArray2<f64>>)
index = RebinningIndex(pctl_index, cluster_bins)
print("Index initialized!")

# Test query execution
# queries: Vec<(f32, String, f64)>
queries = [(0.5, "lt", 50.0), (0.9, "gt", 20.0)]

print("Running queries...")
results = index.run_queries(queries, "recall")
print(f"Results: {len(results)} queries executed.")
for i, res in enumerate(results):
    print(f"Query {i}: {len(res)} matches")

print("Verification complete.")
