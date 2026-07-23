import json
import pickle
import sys
from multiprocessing import set_start_method
from pathlib import Path
from typing import Any, Literal

import numpy as np
import zstandard as zstd
from loguru import logger

from fainder.typing import (
    ConversionIndex,
    F32Array,
    F64Array,
    FArray,
    Histogram,
    PercentileIndex,
    PercentileIndexPointer,
    PercentileQuery,
    RebinningIndex,
    UInt32Array,
)

ROUNDING_PRECISION = 4


def filter_hists(
    hists: list[tuple[np.uint32, Histogram]], filter_ids: UInt32Array | list[int]
) -> list[tuple[np.uint32, Histogram]]:
    return [hist for hist in hists if hist[0] in filter_ids]


def filter_index(
    pctl_index: list[PercentileIndex],
    cluster_bins: list[F64Array],
    filter_ids: UInt32Array | list[int],
) -> tuple[list[PercentileIndex], list[F64Array]]:
    new_index: list[PercentileIndex] = []
    new_bins: list[F64Array] = []
    for i, cluster in enumerate(pctl_index):
        new_cluster: list[tuple[FArray, UInt32Array]] = []
        for pctls, ids in cluster:
            mask = np.isin(ids.reshape(-1, order="F"), filter_ids)
            new_pctls = np.require(
                pctls.reshape(-1, order="F")[mask].reshape((-1, pctls.shape[1]), order="F"),
                dtype=pctls.dtype,
                requirements="F",
            )
            new_ids = np.require(
                ids.reshape(-1, order="F")[mask].reshape((-1, ids.shape[1]), order="F"),
                dtype=ids.dtype,
                requirements="F",
            )
            new_cluster.append((new_pctls, new_ids))

        if mask.sum() > 0:
            new_index.append(tuple(new_cluster))  # type: ignore
            new_bins.append(cluster_bins[i])

    return new_index, new_bins


def filter_binsort(
    binsort: tuple[F64Array, tuple[F32Array, F32Array, F32Array], UInt32Array],
    filter_ids: UInt32Array | list[int],
) -> tuple[F64Array, tuple[F32Array, F32Array, F32Array], UInt32Array]:
    mask = np.isin(binsort[2], filter_ids)
    return (
        binsort[0][mask],
        (binsort[1][0][mask], binsort[1][1][mask], binsort[1][2][mask]),
        binsort[2][mask],
    )


def query_accuracy_metrics(
    truth: set[np.uint32], prediction: set[np.uint32]
) -> tuple[float, float, float]:
    """Compute precision, recall, and the F1-score for an approximate query result.

    Args:
        truth (set[np.uint32]): ground truth
        prediction (set[np.uint32]): predicted results

    Returns:
        tuple[float, float, float]: precision, recall, F1-score
    """
    if len(truth) == 0 and len(prediction) == 0:
        return 1.0, 1.0, 1.0
    if len(truth) == 0:
        return 0.0, 1.0, 0.0
    if len(prediction) == 0:
        return 1.0, 0.0, 0.0
    tp = len(truth & prediction)
    fp = len(prediction - truth)
    fn = len(truth - prediction)

    return tp / (fp + tp), tp / (fn + tp), 2 * tp / (2 * tp + fp + fn)


def collection_accuracy_metrics(
    truth: list[set[np.uint32]], prediction: list[set[np.uint32]]
) -> tuple[list[float], list[float], list[float]]:
    assert len(truth) == len(prediction)
    precision = []
    recall = []
    f1_score = []

    for i in range(len(truth)):
        p, r, f = query_accuracy_metrics(truth[i], prediction[i])
        precision.append(p)
        recall.append(r)
        f1_score.append(f)

    return precision, recall, f1_score


def parse_percentile_query(args: list[str]) -> PercentileQuery:
    assert len(args) == 3

    percentile = float(args[0])
    assert 0 < percentile <= 1

    reference = float(args[2])

    assert args[1] in ["ge", "gt", "le", "lt"]
    comparison: Literal["le", "lt", "ge", "gt"] = args[1]  # type: ignore

    return percentile, comparison, reference


def save_output(
    path: Path | str, data: Any, name: str | None = "output", threads: int | None = None
) -> None:
    if isinstance(path, str):
        path = Path(path)

    path.parent.mkdir(parents=True, exist_ok=True)
    path = path.with_suffix(".zst")

    cctx = None
    if threads:
        cctx = zstd.ZstdCompressor(threads=threads)

    with zstd.open(path, "wb", cctx=cctx) as file:
        pickle.dump(data, file, protocol=pickle.HIGHEST_PROTOCOL)
    if name:
        logger.debug(f"Saved {name} to {path}")


def load_input(path: Path | str, name: str | None = "input") -> Any:
    if name:
        logger.debug(f"Loading {name} from {path}")
    with zstd.open(path, "rb") as file:
        return pickle.load(file)


# ── Flat binary index format (.fidx directory) ────────────────────────────────
# Layout: {name}.fidx/
#   meta.json            — cluster count, modes, dtype, shapes
#   bins_{i}.npy         — float64 bin edges for cluster i
#   pctls_{i}_{m}.npy    — float32/16 sorted percentiles  (Fortran-order)
#   ids_{i}_{m}.npy      — uint32   sorted histogram IDs  (Fortran-order)
#
# Why faster than pickle+zstd:
#   pickle+zstd: decompress ~500MB → Python object tree (list/tuple wrappers) → numpy
#   .npy:        np.load reads a tiny header + raw bytes with a single C read call
#   mmap_mode:   maps the file into virtual memory; OS pages in only accessed data
# ─────────────────────────────────────────────────────────────────────────────

FIDX_SUFFIX = ".fidx"


def save_flat_index(
    path: Path | str,
    pctl_index: list,
    cluster_bins: list,
    name: str | None = "index",
) -> Path:
    """Save a percentile index as a directory of .npy files (flat binary format).

    Significantly faster to load than pickle+zstd; supports zero-copy mmap loading.
    """
    path = Path(path)
    if path.suffix != FIDX_SUFFIX:
        path = path.with_suffix(FIDX_SUFFIX)
    path.mkdir(parents=True, exist_ok=True)

    n_clusters = len(pctl_index)
    n_modes = len(pctl_index[0])
    pctl_dtype = str(pctl_index[0][0][0].dtype)

    meta = {
        "version": 1,
        "n_clusters": n_clusters,
        "n_modes": n_modes,
        "pctl_dtype": pctl_dtype,
        "clusters": [],
    }

    for i, (cluster, bins) in enumerate(zip(pctl_index, cluster_bins)):
        np.save(path / f"bins_{i}.npy", bins)
        cluster_meta = {"n_hists": int(cluster[0][0].shape[0]), "n_bins": int(cluster[0][0].shape[1])}
        for m, (pctls, ids) in enumerate(cluster):
            # Ensure arrays are Fortran-order before saving (preserve layout)
            np.save(path / f"pctls_{i}_{m}.npy", np.asfortranarray(pctls))
            np.save(path / f"ids_{i}_{m}.npy", np.asfortranarray(ids))
        meta["clusters"].append(cluster_meta)

    (path / "meta.json").write_text(json.dumps(meta, indent=2))

    if name:
        total_bytes = sum(f.stat().st_size for f in path.iterdir() if f.suffix == ".npy")
        logger.debug(f"Saved {name} to {path} ({total_bytes / 1e9:.2f} GB raw)")
    return path


def load_flat_index(
    path: Path | str,
    mmap_mode: str | None = None,
    name: str | None = "index",
) -> tuple[list, list]:
    """Load a flat binary index from a .fidx directory.

    Args:
        mmap_mode: None = read into RAM (fast, ~2–5s for eval_medium).
                   'r'  = memory-map (near-zero startup; OS pages in on access).
    """
    path = Path(path)
    if path.suffix != FIDX_SUFFIX:
        path = path.with_suffix(FIDX_SUFFIX)

    meta = json.loads((path / "meta.json").read_text())
    n_clusters = meta["n_clusters"]
    n_modes = meta["n_modes"]

    if name:
        logger.debug(f"Loading {name} from {path} (mmap={mmap_mode})")

    pctl_index = []
    cluster_bins = []

    for i in range(n_clusters):
        bins = np.load(path / f"bins_{i}.npy", mmap_mode=mmap_mode)
        cluster = []
        for m in range(n_modes):
            pctls = np.load(path / f"pctls_{i}_{m}.npy", mmap_mode=mmap_mode)
            ids   = np.load(path / f"ids_{i}_{m}.npy",   mmap_mode=mmap_mode)
            cluster.append((pctls, ids))
        pctl_index.append(tuple(cluster))
        cluster_bins.append(bins)

    return pctl_index, cluster_bins


def is_flat_index(path: Path | str) -> bool:
    """Return True if path looks like a .fidx directory."""
    path = Path(path)
    if path.suffix == FIDX_SUFFIX and path.is_dir():
        return True
    # Also accept path without suffix if the .fidx dir exists
    fidx = path.with_suffix(FIDX_SUFFIX)
    return fidx.is_dir()


def load_index(
    path: Path | str,
    mmap_mode: str | None = None,
    name: str | None = "index",
) -> tuple[list, list]:
    """Unified loader: auto-detects pickle+zstd (.zst) vs flat binary (.fidx)."""
    path = Path(path)
    fidx_path = path if path.suffix == FIDX_SUFFIX else path.with_suffix(FIDX_SUFFIX)

    if fidx_path.is_dir():
        return load_flat_index(fidx_path, mmap_mode=mmap_mode, name=name)
    else:
        data = load_input(path, name=name)
        return data


def configure_run(
    stdout_log_level: str, log_file: str | None = None, start_method: str = "spawn"
) -> None:
    logger.remove()
    logger.add(
        sys.stdout,
        format="{time:YYYY-MM-DD HH:mm:ss} | <level>{message}</level>",
        level=stdout_log_level,
    )
    if log_file:
        logger.add(
            log_file,
            format="{time:YYYY-MM-DD HH:mm:ss} | {level:<7.7} | {message}",
            level="TRACE",
            mode="w",
        )

    try:
        set_start_method(start_method)
    except RuntimeError:
        logger.debug("Start context already set, ignoring")


def unlink_pointers(shm_pointers: list[PercentileIndexPointer]) -> None:
    for cluster_pointers in shm_pointers:
        for pctl_pointer, id_pointer in cluster_pointers:
            pctl_pointer.unlink()
            id_pointer.unlink()


def get_index_size(index: list[ConversionIndex] | list[RebinningIndex]) -> int:
    size = 0
    for cluster in index:
        for pctls, ids in cluster:
            size += pctls.nbytes + ids.nbytes
    return size


def predict_index_size(
    clustered_hists: list[list[tuple[np.uint32, Histogram]]], cluster_bins: list[F64Array]
) -> int:
    size = 0
    for i in range(len(clustered_hists)):
        size += len(clustered_hists[i]) * len(cluster_bins[i]) * 6
    return size
