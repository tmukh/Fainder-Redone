#!/usr/bin/env python3
"""
Bench wrapper around run-queries that:
  1. Runs the query under `perf stat` to capture cycles, instructions, cache-misses, etc.
  2. Parses run-queries log for the canonical wall-clock timing line.
  3. Writes one row per run to a SQLite database (logs/bench.db).
  4. Pushes the same metrics to Prometheus pushgateway with labels (build, threads, repeat).

Usage:
  scripts/bench.py --build pooled-f16-pin --threads 16 --repeat 1 \
                   --index $INDEX --queries $QUERIES \
                   --label-tag native      # extra free-form label

  # Or sweep mode (used by the campaign script):
  scripts/bench.py --build pooled-f16-pin --sweep 1,8,16,32,64 --repeats 3 \
                   --index $INDEX --queries $QUERIES
"""
from __future__ import annotations
import argparse
import os
import re
import sqlite3
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
DB_PATH = REPO / "logs" / "bench.db"
LOG_DIR = REPO / "logs" / "ablation"
PUSHGATEWAY = "http://localhost:9091/metrics/job/fainder_bench"

# Event 0xc7 = FP_ARITH_INST_RETIRED on Sapphire Rapids (Golden Cove).
# Umasks select operand width / precision:
#   0x80 = 512b_packed_single (AVX-512 f32)
#   0x40 = 512b_packed_double (AVX-512 f64)
#   0x20 = 256b_packed_single (AVX2  f32)
#   0x10 = 256b_packed_double (AVX2  f64)
#
# IMPORTANT CAVEAT: this event counts FP *arithmetic* (add/sub/mul/div/fma),
# NOT compares, gathers, or blends. Fainder's hot-path SIMD (vcmpps for
# binary-search lane comparison, vpgatherdd for mid-point loads,
# vpblendd for low/high update) emits precisely zero arithmetic instructions
# in the inner loop. As a result, this event will read near-zero even for
# a fully SIMD-vectorised build. We retain it because:
#   (a) it positively confirms that the FP-arithmetic-heavy paths
#       (Python NumPy reductions, FainderIndex construction) execute when
#       expected;
#   (b) reading near-zero on the Rust hot path is itself a *useful* finding
#       that documents what fp_arith does and does not see.
# For positive identification of vectorised compare/gather work at runtime,
# Intel PT or LBR sampling would be required (out of scope here); the
# canonical evidence used in this thesis is the static instruction-count
# audit of the compiled .so (Section ~5.exp:pin) plus the wall-time deltas
# of the simd / horizontal-simd ablations.
PERF_EVENTS = ",".join([
    "cycles", "instructions",
    "cache-references", "cache-misses",
    "L1-dcache-loads", "L1-dcache-load-misses",
    "LLC-loads", "LLC-load-misses",
    "branch-instructions", "branch-misses",
    "cpu/event=0xc7,umask=0x80,name=avx512_packed_single/",
    "cpu/event=0xc7,umask=0x40,name=avx512_packed_double/",
    "cpu/event=0xc7,umask=0x20,name=avx256_packed_single/",
    "cpu/event=0xc7,umask=0x10,name=avx256_packed_double/",
])

PERF_RE = {
    "cycles":               re.compile(r"([\d,]+)\s+cycles"),
    "instructions":         re.compile(r"([\d,]+)\s+instructions"),
    "cache_refs":           re.compile(r"([\d,]+)\s+cache-references"),
    "cache_misses":         re.compile(r"([\d,]+)\s+cache-misses"),
    "l1_loads":             re.compile(r"([\d,]+)\s+L1-dcache-loads"),
    "l1_misses":            re.compile(r"([\d,]+)\s+L1-dcache-load-misses"),
    "llc_loads":            re.compile(r"([\d,]+)\s+LLC-loads"),
    "llc_misses":           re.compile(r"([\d,]+)\s+LLC-load-misses"),
    "branch_insns":         re.compile(r"([\d,]+)\s+branch-instructions"),
    "branch_misses":        re.compile(r"([\d,]+)\s+branch-misses"),
    "avx512_ps":            re.compile(r"([\d,]+)\s+avx512_packed_single"),
    "avx512_pd":            re.compile(r"([\d,]+)\s+avx512_packed_double"),
    "avx256_ps":            re.compile(r"([\d,]+)\s+avx256_packed_single"),
    "avx256_pd":            re.compile(r"([\d,]+)\s+avx256_packed_double"),
}

WALL_RE = re.compile(r"Rust index-based query execution time: ([\d.]+)s")
PYWALL_RE = re.compile(r"Raw index-based query execution time: ([\d.]+)s")
RESULT_SIZE_RE = re.compile(
    r"Result-size stats: count=(\d+) mean=([\d.]+) median=([\d.]+) "
    r"p25=([\d.]+) p75=([\d.]+) total=(\d+)"
)


def init_db():
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    con = sqlite3.connect(DB_PATH)
    con.execute("""
        CREATE TABLE IF NOT EXISTS runs (
            id            INTEGER PRIMARY KEY AUTOINCREMENT,
            ts            REAL,
            build         TEXT,
            threads       INTEGER,
            repeat        INTEGER,
            label         TEXT,
            wall_s        REAL,
            cycles        INTEGER,
            instructions  INTEGER,
            ipc           REAL,
            cache_refs    INTEGER,
            cache_misses  INTEGER,
            l1_loads      INTEGER,
            l1_misses     INTEGER,
            llc_loads     INTEGER,
            llc_misses    INTEGER,
            branch_insns  INTEGER,
            branch_misses INTEGER,
            avx512_ps     INTEGER,
            avx512_pd     INTEGER,
            avx256_ps     INTEGER,
            avx256_pd     INTEGER,
            llc_bw_gbs    REAL,
            suppress_results INTEGER,
            result_count     INTEGER,
            result_mean      REAL,
            result_median    REAL,
            result_p25       REAL,
            result_p75       REAL,
            result_total     INTEGER,
            log_path      TEXT
        )
    """)
    # Add columns if upgrading an existing DB
    for col, typ in [("avx512_ps", "INTEGER"), ("avx512_pd", "INTEGER"),
                     ("avx256_ps", "INTEGER"), ("avx256_pd", "INTEGER"),
                     ("llc_bw_gbs", "REAL"),
                     # Step (1) gate-decision columns: distinguish suppress
                     # vs with-results runs and capture result-size distribution
                     # so we can attribute merge share to "results are huge"
                     # vs "per-ID materialisation is slow".
                     ("suppress_results", "INTEGER"),
                     ("result_count",     "INTEGER"),
                     ("result_mean",      "REAL"),
                     ("result_median",    "REAL"),
                     ("result_p25",       "REAL"),
                     ("result_p75",       "REAL"),
                     ("result_total",     "INTEGER")]:
        try:
            con.execute(f"ALTER TABLE runs ADD COLUMN {col} {typ}")
        except sqlite3.OperationalError:
            pass
    con.commit()
    return con


def parse_perf_stderr(text: str) -> dict:
    out = {}
    for k, pat in PERF_RE.items():
        m = pat.search(text)
        if m:
            out[k] = int(m.group(1).replace(",", ""))
    return out


def parse_run_log(path: Path) -> float | None:
    try:
        text = path.read_text()
    except FileNotFoundError:
        return None
    m = WALL_RE.search(text) or PYWALL_RE.search(text)
    return float(m.group(1)) if m else None


def push_to_gateway(build: str, threads: int, repeat: int, label: str,
                    wall_s: float, perf: dict):
    """Send one-shot metrics to pushgateway. Idempotent on (build, threads, repeat)."""
    instance = f"{build}-t{threads}-r{repeat}"
    url = f"{PUSHGATEWAY}/instance/{instance}"
    if label:
        url = f"{url}/label/{label}"
    labels_str = f'build="{build}",threads="{threads}",repeat="{repeat}"'
    lines = [
        '# TYPE fainder_wall_seconds gauge',
        f'fainder_wall_seconds{{{labels_str}}} {wall_s}',
    ]
    seen = set()
    for k, v in perf.items():
        if v is None or k in seen:
            continue
        seen.add(k)
        metric = f'fainder_perf_{k}'
        lines.append(f'# TYPE {metric} gauge')
        lines.append(f'{metric}{{{labels_str}}} {v}')
    body = "\n".join(lines) + "\n"
    try:
        req = urllib.request.Request(url, data=body.encode(), method="POST")
        urllib.request.urlopen(req, timeout=2)
    except Exception as e:
        print(f"  [warn] pushgateway POST failed: {e}", file=sys.stderr)


def parse_result_size(text: str) -> dict:
    """Extract per-query result-size distribution from runner.py's log line."""
    m = RESULT_SIZE_RE.search(text)
    if not m:
        return {}
    return {
        "result_count":  int(m.group(1)),
        "result_mean":   float(m.group(2)),
        "result_median": float(m.group(3)),
        "result_p25":    float(m.group(4)),
        "result_p75":    float(m.group(5)),
        "result_total":  int(m.group(6)),
    }


def run_one(build: str, threads: int, repeat: int, label: str,
            index: Path, queries: Path, env_extra: dict | None = None) -> dict:
    LOG_DIR.mkdir(parents=True, exist_ok=True)

    # Step (1) measurement gate: FAINDER_SUPPRESS_RESULTS=0 toggles the
    # `--suppress-results` flag off so we can measure the merge phase
    # (which engine.rs:805-808 short-circuits when suppressed). Default
    # remains "1" (suppressed) for backwards compatibility with existing
    # bench.db rows and the current ablation campaign methodology.
    suppress_results = os.environ.get("FAINDER_SUPPRESS_RESULTS", "1") != "0"
    suffix = "" if suppress_results else "-with_results"
    # Dataset name derived from index path: /.../<dataset>/indices/<file>.fidx
    dataset = index.parent.parent.name if index.parent.name == "indices" else "unknown"
    log_path = LOG_DIR / f"{dataset}-{build}-t{threads}-r{repeat}{suffix}.log"

    env = os.environ.copy()
    env["FAINDER_NUM_THREADS"] = str(threads)
    env["OPENBLAS_NUM_THREADS"] = "64"
    env["NUMEXPR_NUM_THREADS"] = "64"
    if env_extra:
        env.update(env_extra)

    cmd = ["perf", "stat", "-e", PERF_EVENTS, "--",
           "run-queries",
           "-i", str(index), "-t", "index", "-q", str(queries),
           "-m", "recall",
           "--log-level", "INFO", "--log-file", str(log_path)]
    if suppress_results:
        cmd.insert(cmd.index("--log-level"), "--suppress-results")
    # FAINDER_BENCH_PREFIX prepends an external launcher to the perf
    # invocation (e.g. `numactl --cpunodebind=0 --membind=0` for NUMA
    # probes). Tokens are space-separated.
    prefix_str = os.environ.get("FAINDER_BENCH_PREFIX", "").strip()
    if prefix_str:
        cmd = prefix_str.split() + cmd

    suppress_marker = "supp" if suppress_results else "with"
    print(f"  build={build} t={threads} r={repeat} ({suppress_marker}) ", end="", flush=True)
    t0 = time.time()
    # Timeout is generous to accommodate the with-results path on
    # GitTables-scale indices (10K queries × tens of thousands of result
    # IDs each → minutes of Python `set(arr.tolist())` boundary cost).
    # Override via FAINDER_BENCH_TIMEOUT_S if needed.
    timeout_s = int(os.environ.get("FAINDER_BENCH_TIMEOUT_S", "1800"))
    proc = subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=timeout_s)
    elapsed = time.time() - t0
    if proc.returncode != 0:
        print(f"FAILED (exit {proc.returncode})")
        print(proc.stderr[-500:])
        return {}

    wall_s = parse_run_log(log_path)
    if wall_s is None:
        print(f"FAILED (no wall_s in {log_path})")
        return {}
    perf = parse_perf_stderr(proc.stderr)
    ipc = perf["instructions"] / perf["cycles"] if perf.get("cycles") else None

    # Result-size stats are only emitted when suppress_results=False.
    rsize = parse_result_size(log_path.read_text()) if not suppress_results else {}

    msg = f"-> wall={wall_s:.3f}s"
    if ipc: msg += f" ipc={ipc:.2f}"
    if rsize: msg += f" |S|μ={rsize['result_mean']:.0f}"
    print(msg)

    # Derived: estimated DRAM bandwidth from LLC-load-misses.
    # Each LLC miss pulls a 64-byte cache line from DRAM. This is a lower-bound
    # estimate (does not include LLC writebacks or HW prefetcher traffic that
    # bypasses LLC), but useful as a proxy. Direct uncore IMC CAS counters
    # would give exact bandwidth but require root on this kernel.
    llc_bw_gbs = None
    if perf.get("llc_misses") and wall_s > 0:
        llc_bw_gbs = (perf["llc_misses"] * 64) / (wall_s * 1e9)

    row = {
        "ts": time.time(),
        "build": build, "threads": threads, "repeat": repeat, "label": label,
        "wall_s": wall_s,
        "log_path": str(log_path),
        "suppress_results": 1 if suppress_results else 0,
        **perf,
        "ipc": ipc,
        "llc_bw_gbs": llc_bw_gbs,
        **rsize,
    }
    return row


def insert_row(con, row: dict):
    cols = ",".join(row.keys())
    placeholders = ",".join("?" for _ in row)
    con.execute(f"INSERT INTO runs ({cols}) VALUES ({placeholders})", list(row.values()))
    con.commit()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--build", required=True, help="build label (e.g. pooled-f16-pin-mimalloc)")
    ap.add_argument("--threads", type=int, help="single thread count")
    ap.add_argument("--sweep", help="comma-separated thread counts (e.g. 1,8,16,32,64)")
    ap.add_argument("--repeats", type=int, default=3)
    ap.add_argument("--repeat", type=int, default=1, help="repeat number (single-run mode)")
    ap.add_argument("--index", type=Path, required=True)
    ap.add_argument("--queries", type=Path, required=True)
    ap.add_argument("--label", default="", help="extra free-form label")
    ap.add_argument("--no-perf", action="store_true", help="skip perf stat")
    args = ap.parse_args()

    con = init_db()

    threads_list = [int(t) for t in args.sweep.split(",")] if args.sweep else [args.threads]
    if not threads_list or any(t is None for t in threads_list):
        ap.error("Must specify --threads or --sweep")

    print(f"Build {args.build}: sweep={threads_list}, repeats={args.repeats}")
    for t in threads_list:
        for r in range(1, args.repeats + 1):
            row = run_one(args.build, t, r, args.label, args.index, args.queries)
            if row:
                insert_row(con, row)
                push_to_gateway(args.build, t, r, args.label,
                                row["wall_s"],
                                {k: v for k, v in row.items() if k in PERF_RE or k == "ipc"})
    con.close()


if __name__ == "__main__":
    main()
