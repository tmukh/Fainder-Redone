# Defense cue card — one line per beat, ★ = say verbatim

**1 TITLE [0:30]** ★ "The interesting results are structural — the speedup is the least interesting of them."

**2 OUTLINE [0:20]** one sentence, never read the sections.

**3 SEARCH+FAINDER [1:00]** scenario → obstacle → histograms → name last. ★ "Find all columns whose 90th percentile is above a threshold." Pain: 5M × 1M tables, every query. Payoff: scan → binary searches. Proof: 2 orders, 1 TB → 3.2 GB. → "How does a scan become a binary search? One picture."

**4 PLAIN WORDS [1:30]** pipeline L→R; axis: τ picks the tick, p picks the cut. ★ "Median above 20 = fewer than half the values at or below 20." Independent clusters → parallel. Search = few reads, emit = many writes. → "That's the algorithm. The problem is what it ran on."

**5 PYTHON [1:15]** GIL = talking stick; searchsorted never passes it. ★ "96 threads, one talking stick." Flat sweep 2%. AoS: half of every line wasted. 2.4 h. ★ "IPC 2.35 vs 0.96, yet 378x slower — 6.2x the instructions on one core. Fewer instructions on more cores, not IPC."

**6 GOAL [0:30]** close the gap; PyO3 same API; bitwise constraint; out of scope. ★ "The investigation is the thesis; the port is the instrument."

**7 SETUP [1:00]** 2 sockets, 96 cores, 105 MiB L3, 1 TB. 48/socket ⇒ t≤48 one socket. 3 scales + OOD SPARSER 3.2x. Same 10K queries. 5-rep median. perf. 2,658 runs → database.

**8 ENGINE [1:00]** callable like a library; Rayon steals work, no GIL; flag per axis. ★ "Every variant is its own reproducible build." (+ say: every build passes the bitwise gate)

**9 CEILINGS [1:30]** one curve, four regions. Define, name, don't explain. ★ "A ceiling is what you'd have to fix to go faster in that range." HANDS (acquitted) / ROOM / ROAD / BRIDGE.

**10 C-i [0:45]** chain: waits → PGM arc skips → SIMD brace finishes. Table: 0.90–1.13, noise. ★ "Not the depth — the number: 3.8M cheap cache-resident chains. Fixed by adding threads, until the next ceiling."

**11 C-ii [1:30]** CLAIM → AOS → POOLED → SPARSE → VERDICT. AoS penalty only inside [8,32]. Pooled: ~1M allocs, lock queue, 0.53/0.80. Sparse: 610 stops, churn, f16 20%. ★ "Two culprits, one range: the lock on dense, the cache on sparse — the data's shape decides."

**12 C-iii [1:00]** ROAD → NOT BANDWIDTH → 42 → FEWER BYTES. ★ "Congestion, not saturation, at half a percent of STREAM peak." ★ "32 more cores, 42% slower." packed-ids 20-bit, −37% bytes → +21%, −20% worst cell.

**13 C-iv [1:00]** A default / B all-local −11–13% = the link cost measured / C "fair" = worst 26–41%, kills prefetcher / D engineered-worst TIES A. ★ "The default was already paying the link." ≤48 pin it; >48 no escape → genuine ceiling → F2.

**14 NEGCOMP [1:45]** → "Each fix worked in its own regime — so combine the good ones. That move is where the main finding lives." NAME → BUNDLE (0.773) → TWIST → PACKED (12/18) → RENUMBER (3.5x, dTLB 52x) → CALLBACK (interleave = the placement probe) → SWEEP → LAW → CLOSE. ★ "The coarser absorbed the headroom; the finer still pays its overhead; it recovers nothing." ★ "All five plausible. All five falsified. Five axes, one shape — structure, not coincidence."

**15 PRE-FLIGHT [1:15]** BROKEN TOOL → FLIP → 5 STEPS → RECEIPT. ★ "Measure before building — the build you'd add to already exists." Walk the five steps by hand. Pooled passes; packed-on-bundle dies at step two.

**16 DISPATCH [1:00]** no dominating build → ship the selection: (histograms, threads) in, build out. ★ "17/18 only proves consistency — the honest test is the dataset it never studied." 6/6 within 1% → 23/24. ★ "Table machine-specific; procedure is not."

**17 SPEEDUP [1:15]** MODES → SEARCH → DECOMPOSITION → HEADLINE → REBINNING, in that order. Suppress = stopwatch; with-results = user. 22.7 → 1.34 ★ "The ceilings don't care what language you wrote." 97–99.8% = dict construction ★ "Per-object in Python, per-byte in Rust." 2.4 h → 16 s — RUST IS FASTER, watch the inversion. → "With queries at 16 seconds the bottleneck moves — same law, pipeline scale: 4.7x and 2.2x."

**18 RELATED [1:00]** Layout adopted / Search refuted / Execution followed / Composition challenged. ★ "Nobody has documented five mechanism-grounded negative pairs plus a predictive check." + gap line.

**19 CONTRIBUTIONS [0:30]** eng: engine + dispatch. sci: ceilings + negcomp. method: pre-flight. ★ "The engineering is the staging ground; the middle three generalise."

**20 FUTURE [0:45]** F1 huge pages → local-ids. F2 NUMA-aware → ceiling iv. F3 adaptive precision. Columnar. Density range.

**21 CLOSING [0:30]** speedups specific; thresholds no, methodology yes. Final sentence, nothing after: ★ "Identify the binding ceiling at the target composition before committing the implementation cost of the next optimisation. Thank you."

**22 QUESTIONS** breathe. Backups start with B0, the worked example.

**EMERGENCY** hot: compress 18+19. Wobble: silence + next bold word, never "sorry". Lennart's easy questions are layups. Unknown: "Not measured — but here's how the pre-flight procedure would answer it."
