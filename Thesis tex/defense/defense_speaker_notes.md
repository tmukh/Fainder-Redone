# Defense speaker notes

These notes assume you remember nothing. Part 1 is the story in one page. Part 2 explains every concept that appears on a slide. Part 3 is the slide-by-slide script with timings. Part 4 covers the backup slides. Part 5 collects likely questions that have no backup slide.

Total budget: 20 minutes, 21 slides after the title. The script targets sum to about 20:35 (see the cheat sheet); if you are running long live, compress slides 10 (Ceiling i) and 19 (Contributions), which repeat material the committee has already heard.

**DIMA checklist mapping** (from the course FAQ): comparison against the state of the art → slide 18; individual contributions → slide 19; unanticipated findings → slides 10 (ceiling (i) refuted), 12 (the f16 and pooled sign flips), and 14 (five falsified composition predictions, including the pre-registered local-ids one); future work → slide 20. Remaining items on you: the official Thesis Defense Template is on the course Moodle page — check whether the chair requires it before presenting from this deck — and schedule the 20-minute dry run with Lennart (he is unavailable after ~Sept 23).

---

## Part 1: The story in one page

Fainder is an index for searching datasets by statistical property when you can only see per-column histograms, not raw data. It was published by Lennart Behme (your advisor) at VLDB 2024. Its reference implementation is Python, and Python's overhead dominates: 10,000 queries on the 5-million-histogram workload take about 2.5 hours no matter how many threads you give it, because the GIL serialises everything.

You rewrote the query phase in Rust and used that engine to run an ablation study: more than twenty optimisation ideas, each toggled by a build flag, each measured against hardware performance counters. Three findings came out.

**Finding 1 (scientific):** performance is bounded by four distinct hardware ceilings, each binding at a different thread count: (i) single-thread load latency at t≤8 — this one is the textbook assumption for binary search, and you refuted it; (ii) shared L3 capacity around t=16; (iii) on-socket memory-traffic pressure at t=32–48; (iv) the cross-socket UPI interconnect above t=48.

**Finding 2 (structural):** optimisations targeting these ceilings compose negatively. Five separate pairs, on five different hardware axes, all failed the same way: the coarser optimisation had already absorbed the headroom, so the finer one's overhead became a net loss. Every pair had a plausible argument for why it should compose positively. Every argument was falsified by perf counters.

**Finding 3 (methodological):** the fix is pre-flight ceiling identification. Before implementing an optimisation, probe which ceiling actually binds at the composition you intend to add it to. If the optimisation's target ceiling no longer binds there, do not build it.

The deployment consequence is dispatch-on-regime: no single build wins everywhere, so a policy picks the best build per workload regime. It matched the empirical best in 17 of 18 calibration cells exactly, 18/18 within 5%, and 6/6 within 1% at an out-of-distribution density point.

The headline speedup is 530–598× end-to-end over Python — but you present it honestly: ~99% of that ratio is Rust avoiding Python's per-result dictionary construction, not faster search. The search phase alone is 22.7× on the small dataset, shrinking to 1.34× on the largest as the workload runs into the shared hardware ceilings. You lead with the findings, not the number.

---

## Part 2: Concepts, from scratch

### The problem domain

**Distribution-aware dataset search.** You have millions of datasets (data lakes, open-data portals). A user wants "columns whose 90th percentile exceeds 1000". The raw data may be inaccessible (privacy, licensing) or too large to scan. Providers publish per-column histograms instead, and search runs over those summaries.

**Histogram.** A column summarised as bins with counts: "values 0–10: 4,200 rows; 10–20: 1,100 rows; ...". Fainder's corpus has 5,017,619 of these, extracted from GitTables.

**GitTables.** A public corpus of ~1M tables (~120M columns) scraped from CSV files on GitHub. Filtered to numeric columns with at least 100 rows, it yields the 5M histograms.

**Percentile predicate.** A query tuple (p, op, τ): percentile p in [0,1], operator < or >, threshold τ. "Find all columns where the p-th percentile is above/below τ." The workload is a fixed set of 10,000 such tuples, sampled from the original Fainder paper's workload, shared across all datasets.

**Fainder's index.** Three construction steps: (1) K-means groups similar histograms into clusters; (2) inside each cluster, all histograms are *rebinned* onto one shared bin grid, so they become comparable column-by-column; (3) cumulative densities (running sums) are precomputed. With cumulative densities on a shared grid, a percentile predicate reduces to binary search instead of scanning each histogram. Result in the original paper: two orders of magnitude faster than a naive scan of all profiles, and the index fits in 3.2 GB instead of over 1 TB.

**K-means / effective clusters.** K-means partitions the histograms into k groups by similarity. The target k is not what you get: some clusters end up empty or get merged. c256_56gb targets k=256 but has 191 *effective* (populated) clusters; c1024_56gb targets 1024 and has 610. Effective clusters is the number that matters at query time.

**How a query executes.** For each cluster: binary search #1 over the shared bin-boundary array (~142 entries) locates which bin τ falls into. Binary search #2 over the cluster's precomputed cumulative-density column slice finds which histograms satisfy the predicate at that bin. Then the engine *emits* the IDs of matching histograms. Clusters are independent, so the cluster loop parallelises naturally. Rust uses `partition_point` (the standard-library binary search over a predicate) for both searches.

**Search phase vs emit phase.** Search = the binary searches. Emit = writing out matching IDs. They stress different resources: search is latency/cache-bound, emit is bandwidth/allocator-bound. The benchmark measures them separately via suppress mode (below).

### Measurement vocabulary

**Suppress-results vs with-results.** Suppress mode runs the full search but discards results instead of materialising them; with-results builds the actual result structures. Comparing Rust-suppress vs Python-suppress isolates the search engines. With-results vs with-results is what a user experiences. Keeping the two apart is what makes the 530× headline honest.

**5-rep median.** Every measured cell (dataset × build × thread count) ran 5 repetitions; the reported wall time is the median, not the mean. Medians resist outlier runs.

**Wall / wall-clock.** Elapsed real time for the workload. The primary metric.

**perf / hardware performance counters.** CPUs count internal events in hardware: instructions retired, cache misses at each level, TLB misses, stalled cycles. Linux `perf` reads these. Every mechanism claim in the thesis is backed by these counters, not by intuition.

**IPC (instructions per cycle).** How many instructions the CPU completes per clock cycle. High IPC = the pipeline flows; low IPC = it stalls (often waiting for memory). Counterintuitive fact you cite: Python's IPC is *higher* than Rust's (2.35 vs 0.96) while being 378× slower, because NumPy's bulk array operations pipeline beautifully — Python just executes 6.2× more instructions, all on one effective core. Wall time = instructions × cycles-per-instruction ÷ frequency, so you can lose on IPC and win on instruction count and parallelism.

**Noise band.** Run-to-run variance on the server is ±3–6% at t=16, up to ±5–12% at t=32/64. Effects below ±8% in single-run tables are called "within noise".

**Precision = recall = 1.000.** Every result set the Rust engine produces is bitwise-identical to Python's: no missing results (recall 1) and no spurious ones (precision 1). Checked in the harness on every measured configuration.

### Hardware vocabulary

**The machine.** Two Intel Xeon Platinum 8468H CPUs ("Sapphire Rapids" generation), 48 physical cores each = 96 physical, 192 logical with SMT. 105 MiB of L3 cache per socket. 1 TB of DDR5-4800 RAM. This class of two-socket server is what a search service actually deploys on.

**Cache hierarchy.** L1d: 48 KiB per core, ~4–5 cycle latency. L2: 2 MiB per core. L3: 105 MiB *shared by all cores on the socket*. DRAM: hundreds of cycles away. Data moves in 64-byte cache lines. The further down you go, the more threads compete for the same resource — which is why ceilings appear as thread count grows.

**Dependent-load chain.** Binary search reads the middle element, compares, then decides which half to read next. Each load depends on the previous one, so the CPU cannot overlap them. This serial chain is why the literature assumes binary search is latency-bound — the assumption your ceiling (i) work refuted for this workload, because the searched arrays are small enough to be cache-resident.

**SMT / hyper-threading / HT siblings.** Each physical core presents two logical CPUs sharing its execution units. Beyond t=96 the workload puts two threads on one physical core and they contend; that is HT-sibling contention, a regime you observed above the four ceilings.

**NUMA.** Non-Uniform Memory Access. Each socket has its own local RAM. Accessing the other socket's RAM crosses the UPI interconnect at ~2.1× the latency. Node 0 = cores 0–47, node 1 = cores 48–95; hence t≤48 fits one socket and t>48 forces cross-socket traffic. That boundary cleanly separates ceiling (iv) from the others.

**UPI.** Ultra-Path Interconnect, the point-to-point link between the two sockets. Ceiling (iv).

**First-touch vs interleave.** Two NUMA memory placement policies. First-touch: a memory page lands on the node of the thread that first writes it, keeping each cluster's bytes contiguous on one node. Interleave: pages alternate round-robin between nodes in 4 KB granularity, which balances load in theory but shreds spatial locality and defeats the hardware prefetcher — measured +26–41% regression.

**Prefetcher.** Hardware that watches access patterns and fetches predicted-next cache lines early. Works on contiguous streams; round-robin page placement breaks the stream.

**TLB / dTLB.** The CPU translates virtual to physical addresses through the Translation Lookaside Buffer, a small cache of page mappings (data side = dTLB). A miss triggers a page-table walk costing ~100 cycles. The local-ids ablation raised dTLB misses 52× per instruction — that single number explains its +186–245% regression.

**Transparent Huge Pages (THP).** Linux can back memory with 2 MiB pages instead of 4 KiB. One TLB entry then covers 512× more memory, cutting miss frequency accordingly. Future work F1.

**STREAM Triad.** The standard memory-bandwidth benchmark; this machine sustains ~330 GB/s aggregate. Your workload's LLC-miss traffic (64 B per missed probe) computes to roughly 0.5% of that peak — which is exactly why you say "memory-traffic *pressure*", never "bandwidth-bound". Bandwidth-bound would mean the DRAM channels are saturated; they are nowhere near. What rises is queue occupancy in the memory subsystem, and it shows up as anti-scaling.

**Anti-scaling.** Adding cores makes wall time *worse*. The signature of ceiling (iii).

### Software vocabulary

**GIL.** CPython's Global Interpreter Lock: one thread executes Python bytecode at a time. `numpy.searchsorted` (the binary search Python-Fainder uses) does not release it, so the thread setting `FAINDER_NUM_THREADS` is silently ignored — measured wall time is flat across thread counts with a 2% spread.

**AoS vs SoA.** Array-of-Structs stores records as (value, id)(value, id)...; Structure-of-Arrays stores all values contiguously and all ids contiguously. Binary search touches only values, so AoS wastes half of every 64-byte cache line on ids nobody reads. SoA is the Rust default; the `aos` build is the deliberate negative control. Its regime flip (+17% at t=8, −4% at t=64) is evidence the binding ceiling changes with t.

**f16.** Half-precision (16-bit) floats for the cumulative densities, halving the footprint, at the cost of a dequantisation (f16→f32 conversion) on every comparison. Correctness is preserved because comparisons are validated bitwise against the reference.

**Eytzinger layout.** Storing a binary-search array in breadth-first order so the hot top-of-tree elements share cache lines. One of the layout axes.

**PGM learned index.** A structure that fits piecewise-linear models to the data so a lookup jumps near the target position and only searches a small residual window. One of the four latency-side (ceiling-i) ablations; null result.

**AVX-512 / SIMD.** Single-Instruction-Multiple-Data: one instruction processes 16 f32 values at once. Used in the leaf stage of the search; standalone effect is null (latency was never the wall), but it rides along in the best-combo bundle.

**Rayon / work-stealing.** Rust's data-parallelism library. Each thread has a queue of tasks; idle threads steal from busy ones, balancing load automatically. The cluster loop runs under Rayon.

**PyO3 / Maturin.** PyO3 lets Rust functions be called as a normal Python module; Maturin builds and installs it into the virtualenv. This is what keeps the Rust engine behind the existing Python API — a hard integration constraint, since the rest of the pipeline (K-means, loading) stays in Python.

**Cargo feature flags.** Compile-time switches in Rust's build system. Every optimisation axis is a flag, so every ablation is a separate reproducible binary rather than a runtime branch.

**Allocator arena / glibc arena mutex.** malloc keeps per-thread memory pools (arenas) guarded by mutexes. When many threads allocate result vectors simultaneously, they serialise on those mutexes. This — not L3 capacity — is what actually binds at t=16 on the dense primary workload, and it is what `pooled` fixes.

**pooled.** Pre-allocates one output buffer per query instead of one vector per matching cluster. Standalone: −46.9% at t=1, −34.1% at t=8, −20.2% at t=16 on the primary workload. The single biggest standalone win.

**mimalloc.** A drop-in replacement allocator. Standalone it *hurts* at low t (+22%, arena warmup cost) and wins −10% at t=32. Only useful inside the bundle.

**pin-cores.** Pins Rayon workers to physical cores so the OS scheduler cannot co-locate two workers on one core's SMT siblings. −19% at t=32 standalone; useless at t≥64 where SMT contention is unavoidable.

**best-combo (bcombo).** The bundle: pooled + f16 + simd + pin-cores + cluster-prefetch + mimalloc. At t=16 on the primary workload it runs at 0.773× the default build's wall (22.7% faster). Important nuance you must be able to say: inside the bundle at t=16, `pooled` carries essentially the whole win and `f16` is a drag the others absorb.

**packed-ids.** Bit-packs the emitted IDs to cut emit-phase bandwidth. Regime-best at t=64 standalone, but composes negatively with bcombo (12/18 cells).

**local-ids / per-cluster reindexing.** Renumbers histogram IDs within each cluster so they need fewer bits (bw≈13 instead of ≈20). Pre-registered prediction said it would help; measured +186–245%. The falsified-prediction story of the thesis, and your best example of the pre-flight methodology's value. Mechanism: dTLB misses up 52×.

**query-batch (qbatch).** Processes K queries (64 or 128) per cluster visit, amortising the cost of pulling a cluster into cache ("cold-load") across the batch. Regime-best at t=96. Composes negatively with f16 (which already halved the cold-load size).

**morsel-driven scheduling.** Splits work into small "morsels" handed to workers dynamically, coordinating phases across workers (the design from HyPer). Composes negatively on top of qbatch: the shared 105 MiB L3 already absorbs cross-task cold-loads, so the coordination is pure overhead (+8–12%).

**Column-centric engine.** Alternative engine organisation that iterates columns first rather than rows/clusters. Wins 2.17–2.63× at t=1, loses ~2× at t≥8 due to cross-cluster load imbalance. In the dispatch policy at low t on big data.

**Work-fragmentation regime.** At high t on big data, work per thread becomes too small/fragmented; scheduling overheads surface. The regime qbatch and morsel address.

**Dispatch policy.** A piecewise-constant function: input (n_hists, n_threads), output build string + env flags. Boundaries read off the calibration grid. Validation: 17/18 exact, 18/18 within 5% in-distribution; at the OOD point 6/6 within 5%, all within 1%. Combined 23/24.

**In-distribution vs out-of-distribution (OOD).** The policy's boundaries were derived from the three c256 datasets (calibration = in-distribution). c1024_56gb changes cluster density by 3.2× without changing data scale — a point the policy was never tuned for. Testing there is the real test.

**Rebinning kernel.** The index-construction step that aligns each cluster's histograms onto the shared grid. Ported to Rust as one fused parallel call per cluster (rebin, cumulative sum, stable sort). 4.72×/4.77× faster at the two smaller scales, 2.18× at 5M. The drop is the kernel's own parallelism ceiling (~2 effective cores of 96; ~46% of kernel time on a shared per-cluster allocation) — explicitly *not* "NumPy is good at bulk ops", an earlier hypothesis that was tested and refuted.

---

## Part 3: Slide-by-slide script

Format: what to say, in speaking register — adapt freely. These scripts explain every technical term in plain words the moment it first appears, so the talk carries a non-expert listener while the slides stay committee-grade. Times are the targets from the cheat sheet.

### Slide 1 — Title (0:30)

Say: "Good morning. My thesis is about hardware-conscious performance engineering of Fainder, an index for distribution-aware dataset search. The short version: I rewrote its query engine in Rust, and used that engine to characterise how this workload actually interacts with a modern two-socket server. The interesting results are structural, and the speedup — while large — is the least interesting of them."

That last sentence sets the frame for the whole talk. Everything after it delivers on it.

### Slide 2 — Outline (0:20)

Say: "I will spend the first minutes on the problem and the baseline, then the method, then the bulk of the time on results in three parts — four hardware ceilings, negative composability and the methodology that follows from it, and the comparison with Python — before positioning against related work and concluding."

Do not read the section names off the slide one by one; the sentence above covers them faster.

### Slide 3 — Distribution-Aware Dataset Search and Fainder (1:00)

Say: "Imagine millions of datasets where you cannot open the raw data — privacy, licensing, or plain scale. What you get instead is, for every column, a histogram: the column boiled down to 'how many values fall in each range'. Search has to run over those summaries. The queries we care about are percentile predicates — in plain words: find all columns where, say, the 90th percentile is above some threshold. Fainder, published at VLDB 2024, is an index that makes this fast. It groups similar histograms, aligns each group onto one shared set of ranges, and precomputes running totals, so that answering a query becomes a binary search — jumping into a sorted list instead of reading everything. On five million real histograms it is two orders of magnitude faster than scanning, in three gigabytes instead of a terabyte. My question: how do we make its query phase run well on a modern server with a hundred cores?"

Have ready: Fainder is your advisor's paper (Behme et al.). Anything about clustering quality or index construction internals is the original paper's territory; you inherit the index as given.

### Slide 4 — Fainder in Plain Words (1:30)

Walk the diagram left to right. Say: "Before any hardware talk, the whole system in one picture. Five million column summaries. K-means — a standard grouping algorithm — sorts them into about two hundred families of similar shape. Why families? Because histograms in a family can share one x-axis, and once they share an x-axis, the same question lands at the same position in every one of them. At every point on that shared x-axis, the index stores one number per column — the fraction of that column's values below that point — and it stores those numbers sorted, together with the column IDs. Sorted is the whole trick. A sorted list can be binary-searched: cut it in half, again and again, instead of reading it end to end. So a query never looks at five million summaries. It jumps within about two hundred short sorted lists."

Then the two beats that used to be their own slide — do not skip them: "One equivalence makes this concrete: asking whether a column's median is above 20 is the same as asking whether the fraction of its values at or below 20 is under one half. So the threshold picks which sorted list to open, and the percentile picks where to cut it. And two properties to carry through the talk: clusters are independent, so this parallelises; and searching is a few dependent reads while emitting — writing out the matching IDs — is many writes. They stress different hardware, and we measure them separately."

This slide is your insurance: every later term (bin boundaries, cumulative densities, cluster loop) maps back to this picture. If a question later confuses you, come back to this picture and answer from it. The full worked example (toy tables, median > 20 traced step by step) is now the FIRST backup slide — jump to it for any "how does a query actually execute" question and walk it exactly as in Part 9.

### Slide 5 — The Python Baseline (1:15)

Say: "The reference implementation is Python with NumPy, and it has a structural problem: the Global Interpreter Lock. Python only ever executes one thread at a time — that is what the lock enforces — and the specific NumPy search routine in the hot loop never releases it. So the loop over clusters, which should parallelise perfectly, runs strictly one cluster after the other, no matter how many threads you configure. We measured it: wall time is flat across every thread count, a two percent spread. Ten thousand queries take about two and a half hours. One number worth pausing on: Python's IPC — instructions completed per clock cycle, a measure of how smoothly the processor pipeline flows — is actually *higher* than Rust's. NumPy's bulk operations pipeline beautifully. It is still 378 times slower on the same cell, because it executes six times the instructions, almost all bookkeeping, funnelled through one effective core. Rust wins by doing less work on more cores, not by using the processor more elegantly."

The IPC point routinely surprises committees; deliver it slowly.

### Slide 6 — Goal and Scope (0:30)

Say: "The goal: close the gap between what the algorithm can do and what the implementation delivers, without changing a single result. I re-implemented the query phase in Rust — a compiled language with real threads — behind the existing Python interface, and used it to test more than twenty optimisation ideas. One hard rule throughout: every build must return bit-for-bit identical results to the original. Out of scope: algorithm changes, GPUs, distribution. And the framing that matters: the port is the instrument. The findings are the thesis."

### Slide 7 — Experimental Setup (1:00)

Say: "The machine is what a search service would actually deploy on: two processor sockets, 96 physical cores, a terabyte of RAM. Two numbers to keep: each socket has 105 megabytes of L3 — the last cache before main memory, shared by all cores on the socket — and 48 cores, so up to 48 threads we live on one socket, and beyond that we span two. Four workloads, all sharing the same ten thousand queries: three sizes of the same corpus — 324 thousand, a million, and five million histograms — plus a fourth that keeps the five million but re-clusters them into families three times sparser. That fourth one is held out to test whether the findings generalise. Protocol: every configuration measured five times, medians reported, and the processor's own event counters — hardware that counts cache misses, stalls, instructions — recorded on every cell. 2,658 runs, every number traceable to a database row."

### Slide 8 — The Rust Engine (1:00)

Say: "The engine is a compiled module that Python calls like any other library — clustering and data loading stay in Python, nothing else changes for the user. Parallelism comes from Rayon, a Rust library where idle threads steal work from busy ones, so no core sits idle while another has a queue. The design decision that made the whole study possible: every optimisation is a compile-time switch, so every variant is its own reproducible binary — different memory layouts, half-precision values, vector instructions, different schedulers, different allocation strategies. And every build validates bit-identical against the Python reference before its numbers count for anything."

(Rebinning is deliberately not on this slide — its one appearance in the talk is the result line on the speedup slide, with backup B8 behind it.)

### Slide 9 — Finding 1: Four Performance Ceilings (1:30)

Say: "First finding. This is search wall time as threads increase, and the shaded regions mark where four different limits — I call them ceilings — take over. Up to eight threads, the candidate is the classic one for binary search: each read has to wait for the previous read. We refuted it here — more on that in a moment. Around sixteen threads, the shared cache: all cores on a socket compete for the same 105 megabytes. Between 32 and 48 threads, something uglier appears: adding cores makes the run *slower* — congestion on the path to memory. And past 48 threads we spill onto the second socket, and the link between the sockets becomes the fourth ceiling. The point of the slide: each ceiling binds in its own regime — its own region of thread counts and data sizes — and each responds to a different class of fixes."

Point at the figure regions as you name them.

### Slide 10 — Ceiling (i): Refuted (0:45)

Say: "First, what this ceiling is: binary search is a chain of reads where each read depends on the previous comparison — the processor cannot start read five before read four returns. 'Reads waiting on reads' is the textbook diagnosis for in-memory search, so it had to be candidate number one. The table is the refutation: four independent attacks on latency — vectorising the last steps, overlapping eight searches' reads, running sixteen queries in lockstep, and a learned index that predicts the position instead of searching. Every cell of every one lands between 0.90 and 1.13 — indistinguishable from noise. The counters say why: at one thread the loop misses the fastest cache on half a percent of loads — the arrays simply live there. The sharpest evidence is the learned index: the counters confirm it really does collapse the chain depth, and the wall still does not move. Conclusion: the wall is the *number* of chains — one per cluster per query — not the depth of any single one. No latency-side trick changes the count."

### Slide 11 — Ceiling (ii): Shared L3 Capacity (1:30)

Say: "Ceiling two comes with a claim, two probes, and a verdict. The claim: between 8 and 32 threads, the threads' combined data overflows the 105-megabyte L3 — the last cache before RAM, shared by every core on the socket — and the scaling curve bends. First probe, top row: the AoS layout. It changes exactly one thing — every cache line it loads is half wasted — so it is a pure capacity probe. Look where its penalty lives: plus 17 percent at eight threads, inside the claimed window, and it vanishes outside it. So capacity pressure is real, and it is real exactly where the claim says. But now the second probe: the single biggest win in that same window is pooled buffers — and what pooled fixes is not capacity at all. It removes per-cluster allocations, so it removes the queue of threads waiting on the memory allocator's lock. And watch its win fade — 0.66, 0.80, 0.95 — exactly as the next ceiling takes over. Third piece: f16 halves the bytes per value, the pure footprint fix — and it wins nothing on the dense primary workload, but pays about twenty percent at the sparse out-of-distribution density, where the aggregate footprint genuinely binds. So the verdict: one regime, two mechanisms. On dense clusters the allocator lock binds first; on sparse ones it really is L3 footprint."

The table is your defense against "how do you know the window is [8,32]": the AoS penalty sits inside it and vanishes outside — that placement is the evidence. If pushed harder, the four-ceilings figure's regime shading comes from the same scaling-curve bend.

### Slide 12 — Ceiling (iii): On-Socket Memory-Traffic Pressure (1:00)

Say: "Ceiling three needs its mechanism spelled out, because it is not a bandwidth story. All cores on a socket share the queues on the path to memory — level-three cache, the on-chip mesh, the memory controller. Every core you add lengthens those queues, so every access from every core waits a little longer. That can strangle you long before bandwidth runs out — and it does: total traffic sits at half a percent of what this machine's memory can stream. Congestion, not saturation. The table is the signature: on the medium dataset, going from 64 to 96 threads makes the default build 42 percent *slower* — anti-scaling — and the counters agree: instructions per cycle collapse from 1.9 to 0.55, cache misses up 60 percent. The fix class follows from the mechanism: put fewer bytes into the queues. Packed IDs — emitting results as 20-bit instead of 32-bit integers, about a third fewer emit bytes — takes the same thread step at half the damage, and wins 20 percent at the worst cell."

### Slide 13 — Ceiling (iv): Cross-Socket UPI Interconnect (1:00)

Say: "Ceiling four is isolated by one controlled experiment: the identical workload under four memory placements. Row A is the default — the operating system places memory wherever a thread first touches it. Row B forces cores *and* memory onto one socket, so no data ever crosses the link between the sockets: 11 to 13 percent faster, and that saving *is* the link cost, measured. Row C is the placement that sounds fairest — spread the pages evenly, alternating sockets every four kilobytes — and it is the disaster of the table, 26 to 41 percent slower everywhere: half of all accesses land on the far socket, and the per-page alternation breaks the prefetcher, the hardware that pre-loads what you'll read next. Row D is the deliberate worst case — all memory on socket zero, all cores on socket one, every single access remote — and it lands where the default already is. Which tells you the default was already paying the link cost. Together: the link is a real ceiling, placement is the lever, and naive balancing moves it the wrong way."

### Slide 14 — Finding 2: Negative Composability (1:45)

Say: "Now the heart of the thesis. First, one definition: best-combo is the bundle of the six features that won individually — pooled, f16, SIMD, core pinning, cluster prefetch, and the mimalloc allocator — and at sixteen threads it runs at zero point seven seven times the default wall, so twenty-three percent faster. Now, five pairs of optimisations, each pair on a different hardware resource — output bandwidth, cache loading, thread coordination, ID encoding, memory placement. In every pair, both ideas are individually sensible, and several win on their own. Layered together, every single pair loses. Always the same shape: the first optimisation already absorbed the headroom, so the second one pays its overhead and recovers nothing. The extreme case: re-numbering IDs within each cluster so they need fewer bits — sounds strictly better, and it cost up to three and a half times the runtime, because the decoder's memory access pattern multiplied address-translation misses fifty-two-fold. Every one of the five had a plausible argument for composing positively. Every argument was falsified by the hardware counters. Five different resources, one shape — that is structure, not coincidence."

This is your longest slide. Own it; slow down.

### Slide 15 — Finding 3: Pre-Flight Ceiling Identification (1:15)

Say: "If negative composability is the disease, this is the treatment. The normal performance loop — build it, measure it, keep it if faster — silently assumes improvements are independent. Here they are not: whether idea B helps depends on what the bottleneck is *after* everything already applied, and each applied optimisation moves the bottleneck. So, before building B: read the processor's event counters in exactly the configuration B would join. If B's target bottleneck no longer binds there, do not build it. If it does, predict the saving arithmetically, then measure in the cells where it matters, and count a negative result as a result. Five out of five times in this thesis, that check would have predicted failures that were instead discovered by paying the implementation cost. Nothing in the procedure is specific to Fainder."

### Slide 16 — Dispatch on Regime (1:00)

Say: "The deployment consequence: if optimisations do not stack, there is no single best build — so we ship a policy instead of a build. Give it the data size and the thread count, and it returns which build to run with which settings. Validation: on the grid it was derived from, it picks the measured best in 17 of 18 cells exactly, all 18 within five percent. The honest test is the held-out dataset it was never tuned on: six out of six cells within one percent of the best. Combined, 23 of 24. The table is specific to this machine and workload; the procedure that produces the table is not."

### Slide 17 — Speedup over the Python Baseline (1:15)

Say: "Only now the headline number, because it needs decomposing to be honest. End-to-end, two and a half hours become sixteen seconds — 530 to 598 times. But about 99 percent of that ratio comes from Rust *not doing* something: Python builds a result dictionary for every query-cluster pair, and that bookkeeping is 97 to 99.8 percent of its wall time. Compare only the search engines — both with output turned off — and the picture is sober: 22.7 times on the small dataset, 4.6 in the middle, 1.34 on the largest, shrinking because both engines converge on the same hardware ceilings. Both columns are true, and the thesis never conflates them. Separately, the construction-side kernel we ported cuts the alignment step by about four point seven times at the smaller scales."

If a committee member looks alarmed at 1.34, invite the question — backup slide B1 is exactly that.

### Slide 18 — Positioning Against the State of the Art (1:00)

Say: "Positioning, briefly. The memory-access tradition — Manegold's result that memory, not compute, dominates in-memory databases — motivates our data layout. The compilation tradition — Neumann — motivates the port itself. The scheduling literature motivates work-stealing. Closest to the thesis: every composability tradition, from Selinger's additive cost models to modern interference-managing schedulers, assumes improvements combine. To our knowledge, nobody has documented what we found: five mechanism-grounded negative pairs, plus a check that predicts them. And the concrete gap we fill: nobody had characterised the hardware bottlenecks of histogram-based percentile search."

Have ready if pushed on approximate systems (T-digest, HdrHistogram): those approximate quantiles over streams; Fainder answers exact predicates over precomputed histograms. Complementary, not competing.

### Slide 19 — Contributions (0:30)

Say: "Five contributions. Two engineering: the validated engine and the dispatch policy. Three findings: the four ceilings, the negative-composability pattern, and the pre-flight check. The engineering is the staging ground; the findings are what generalises."

### Slide 20 — Future Work (0:45)

Say: "Three follow-ups fall straight out of the findings. Huge memory pages — one address-translation entry covering five hundred times more memory — target exactly the mechanism that sank the ID re-numbering. A two-socket-aware build that keeps each cluster's data and its workers on the same socket is the path past ceiling four. And adaptive precision: full precision at low thread counts, half precision at high counts and sparse data — pick at runtime. Beyond those, widening the alternative engine's win region and validating the dispatch policy outside its tested density range."

### Slide 21 — Closing Remark (0:30)

Say: "The speedups belong to this codebase, this processor, this workload. The structural finding travels: on hardware-near workloads, whether optimisation B helps depends on which ceiling optimisation A has already collected — and per-operator cost models cannot see that. So: identify the binding ceiling at the target composition before committing the implementation cost of the next optimisation. Thank you."

### Slide 22 — Questions?

Breathe. The backup slides are behind this one, in the order of Part 4.

---

## Part 4: Backup slides — how to use each

Navigate past the Questions slide to reach them. Say "I have a slide on exactly that" and jump.

**B0 — One Query, End to End (the worked example, now first in backup).** For any "how does a query actually execute" question. Walk it exactly as Part 9 describes: equivalence first (median > 20 ⟺ CDF(20) < 0.5), then τ picks the column, p picks the cut, operator picks the side, emit the ID slice; cluster B shows the out-of-range fast path.

**B1 — Why is end-to-end 530× if search is only 1.34×?** The most likely question in the room. Answer: Python spends 96.9 to 99.8 percent of its wall on materialising result dicts per (query, cluster) — measured directly by differencing with-results and suppress runs. Rust does not have that cost structure at all. Both comparisons are reported; conflating them would credit Rust's search for Python's bookkeeping. If pushed on "so was the port even worth it?": yes — the user experiences end-to-end, and 2.5 hours versus 16 seconds is the deployed reality; the decomposition is about attributing the credit correctly, not shrinking it.

**B2 — Why does f16 win nothing standalone?** The prediction assumed halving footprint moves you inside a cache level. On the dense primary workload the per-cluster slice was already L2-resident, so nothing was unlocked, while every comparison pays dequantisation. On the sparse OOD workload the aggregate footprint does bind, and f16 carries a fifth of the bundle win. Punchline: footprint optimisations are density-conditional.

**B3 — Why "memory-traffic pressure" and not "DRAM bandwidth"?** STREAM Triad: ~330 GB/s aggregate. The workload's LLC-miss traffic computes to ~0.5% of that. Saturation is not the mechanism; queue pressure is. The name matters because it predicts the fix: fewer bytes per probe/emit, not more bandwidth.

**B4 — The local-ids regression.** Your falsified pre-registered prediction, and your favourite story: narrower IDs should have cut read bandwidth; instead +186–245%. A direct perf probe found dTLB misses up 52× — the bw≈13 decoder walks the packed buffer in a pattern that thrashes address translation, and 100-cycle page walks drown the saving. THP (2 MiB pages) is the natural follow-up, future work F1. If asked why you report a failure: pre-registered predictions that fail are how the methodology earns its keep.

**B5 — What generalises?** Thresholds no, methodology yes. One machine (say it plainly). Different micro-architectures would move every threshold and boundary. The probe procedure is machine-agnostic; the four-ceiling set becomes a hypothesis list to re-test. Dispatch is only validated inside the 8,200–26,300 hists/cluster density range; outside it, the policy is a prediction. Multi-machine adds a network ceiling.

**B6 — Correctness.** Bitwise-identical on every workload, checked inside the harness on every measured configuration, precision = recall = 1.000. Rebinning: 200-query verification; Rust rounds half-away vs NumPy's banker's rounding, max cumulative difference 1e-4, no effect on sort order or results; falls back to Python for cubic-spline estimation.

**B7 — Why Rust?** Requirements: no GIL, explicit layout/allocation control, safe shared-memory parallelism, maintainable Python integration. Rust+PyO3 covers all four; Cargo feature flags made the ablation matrix reproducible. Concede C++ could match the performance — the ablation infrastructure and safety at 96 threads is where Rust paid off. Numba/Cython keep allocator and layout in Python's hands, and those layers are the measured cost.

**B8 — Rebinning drop at 5M.** The kernel's own parallelism ceiling: ~2 effective cores of 96, ~46% of kernel time on a shared per-cluster allocation. Explicitly refute the "NumPy bulk ops" explanation — it was tested and it is wrong. Construction-time cost, paid once.

---

## Part 5: Likely questions with no backup slide

**"Why did you pick these four datasets?"** Three calibration scales vary histogram count at fixed clustering (K=256); the OOD point varies cluster density at fixed scale (K=1024 → 610 effective clusters, 3.2× sparser). Two independent axes: scale and density.

**"What are 'effective clusters'?"** K-means targets k, but some clusters end up empty or merged. What is populated at query time: 129/184/191 for the c256 datasets, 610 for c1024.

**"Why median and not mean?"** Robustness to outlier runs. The campaign standard is 5-rep median; borderline claims were re-measured at 10 reps (e.g. the f16 fine-t sweep) to tighten the confidence interval.

**"What happens above 96 threads?"** HT-sibling contention: two logical threads share one physical core's execution units. A regime observed on top of the four ceilings; pin-cores mitigates placement, but at t≥64+ sharing is unavoidable.

**"Why does Python's search get *faster* from 10gb to 30gb (18.8s → 11.9s)?"** Python has a per-cluster fast path: if a query's reference value falls outside a cluster's bin range, searchsorted is skipped entirely. More histograms spread over more clusters means more skips. A good example of why per-engine mechanism matters before comparing walls.

**"How does the dispatch policy know n_hists and threads?"** Both are known at deployment: the index knows its own size and the operator sets the thread budget. The policy is a lookup, not a runtime optimiser.

**"Could the policy mispredict?"** Inside the validated density range, worst observed gap is +4.7% (one cell, within that cell's noise). Outside the range it is explicitly labelled a prediction — that is the density-scope limitation.

**"Is this negative-composability claim falsifiable?"** Yes, and say it exactly this way: an ablation that composes positively against a baseline whose binding ceiling it does not address would falsify the pattern. The claim is "this pattern exists and recurs on hardware-near compositions", not "all optimisations compose negatively".

**"What was the OOD structural verdict beyond dispatch?"** Eight pre-registered claims re-tested at c1024: 4 strong reproductions, 2 clean reproductions, 2 mechanism-coherent refinements, 0 falsifications.

**"Single-thread comparison with Python?"** One paired cell exists: c256_10gb at t=1, end-to-end 114× (610.2s vs 5.37s). Larger datasets have no single-thread Python pairing in the campaign.

**"Why not GPU?"** Out of scope by design: the thesis isolates CPU micro-architecture effects. A GPU port changes the memory system entirely and would restart the ceiling characterisation from zero.

**"Future work?"** Three concrete probes: (F1) THP across all builds — targets the dTLB mechanism directly; (F2) NUMA-aware build for t>48 — shard clusters across sockets at load time, pin workers node-locally; (F3) adaptive f16/f32 precision selection by thread count, and widening the column-centric engine's win region by fixing its cross-cluster load imbalance.

**"Who are the examiners / logistics?"** Reviewers: Prof. Volker Markl, Prof. Matthias Böhm. Advisor: Lennart Behme. Check the second-reviewer line on the title slide against the final paperwork before presenting.

---

## Timing cheat sheet

Target times (the scripts in Part 3 are written to these):

| # | Slide | Time | Cumulative |
|---|-------|------|-----------|
| 1 | Title | 0:30 | 0:30 |
| 2 | Outline | 0:20 | 0:50 |
| 3 | Fainder | 1:00 | 1:50 |
| 4 | Fainder in plain words | 1:30 | 3:20 |
| 5 | Python baseline | 1:15 | 4:35 |
| 6 | Goal and scope | 0:30 | 5:05 |
| 7 | Setup | 1:00 | 6:05 |
| 8 | Rust engine | 1:00 | 7:05 |
| 9 | Four ceilings | 1:30 | 8:35 |
| 10 | Ceiling (i) | 0:45 | 9:20 |
| 11 | Ceiling (ii) | 1:30 | 10:50 |
| 12 | Ceiling (iii) | 1:00 | 11:50 |
| 13 | Ceiling (iv) | 1:00 | 12:50 |
| 14 | Negative composability | 1:45 | 14:35 |
| 15 | Pre-flight | 1:15 | 15:50 |
| 16 | Dispatch | 1:00 | 16:50 |
| 17 | Speedup | 1:15 | 18:05 |
| 18 | Related work | 1:00 | 19:05 |
| 19 | Contributions | 0:30 | 19:35 |
| 20 | Future work | 0:45 | 20:20 |
| 21 | Closing | 0:30 | 20:50 |

Fifty seconds over on paper; you report reaching the end of the ceilings in ~13:00 spoken, which matches slide 13's 12:50 target almost exactly. The recovery slides if needed: 18 (Related work) compresses to 0:40 and 19 (Contributions) to a sentence. Rehearse against a timer; the dry run with Lennart is the place to calibrate.

---

## Part 6: Questions from the read-through, answered

**K-means, and K-means on histograms.** K-means picks k centroids, assigns every point to its nearest centroid, recomputes each centroid as the mean of its members, and iterates until assignments stop changing. Here a "point" is a histogram treated as a vector of bin densities, so histograms with similar shapes land in the same cluster. The pipeline uses MiniBatchKMeans, a variant that updates centroids from small random batches so it scales to 5M vectors.

**Shared bin grid.** Histograms arrive with arbitrary, mutually incompatible bin edges. Within a cluster, rebinning projects every histogram onto one common set of bin boundaries, so all histograms in the cluster are expressed over the same x-axis and become comparable column-by-column. Rebinning introduces a small alignment error near bin boundaries; Fainder also has a higher-accuracy "conversion" strategy at 2× memory, but the thesis uses rebinning throughout.

**Cumulative densities, and why precomputed.** For one histogram, the cumulative density at boundary b is the fraction of the column's values at or below b — a running sum over the bins. The percentile predicate reads directly off it: the p-th percentile relates to τ exactly as the cumulative density at τ's bin relates to p. They are precomputed at construction so query time never touches raw bin counts, and — the key move — at each boundary, the cluster's histograms' cumulative values are stored *sorted*, with a parallel array of histogram IDs in matching order. Sorted is what makes binary search possible.

**Why the query becomes binary search.** Two sorted arrays, two searches. Search 1: the bin boundaries are sorted floats, so locating τ's bin b* is a binary search. Search 2: at b*, the cumulative densities of all histograms in the cluster form a sorted array; every histogram satisfying the predicate sits on one side of a cut point, so one `partition_point` call finds the cut and everything beyond it matches.

**Scanning profiles.** The naive baseline: for every query, visit all 5M histograms and compute the percentile answer from each histogram's bins directly. That is what Fainder's index beats by two orders of magnitude.

**Bin-boundary array, and the ~142.** It is the cluster's shared grid: a sorted array of f32 bin edges. The rebinning target caps the grid at 256 bins, and on the primary workload the populated grid comes out at roughly 142 edges — the thesis cites the measured size. What matters for the ceiling analysis is that it is a few hundred bytes and permanently cache-resident. (If an examiner drills into where exactly 142 comes from, the honest answer is that it is the measured grid size of this workload's rebinned index; verify against the index metadata if needed.)

**The two arrays and their purposes.** Per cluster: (a) the bin-edge array, ~142 sorted floats, locates the bin. (b) The SubIndex, column-major: for n histograms and b boundaries, `values` holds n×b f32s where column k — the *column slice* `values[k*n .. (k+1)*n]` — is all n cumulative densities at boundary k, sorted; `indices` holds the histogram IDs in the same order. Search 2 walks one column slice; the IDs are only touched at emit time.

**Why clusters are independent, and the cluster loop.** Each cluster has its own grid and its own SubIndex; answering a query on cluster c reads nothing from any other cluster, and the final answer is the union over clusters. So the loop "for each cluster: two searches, then emit" — the cluster loop — parallelises with no synchronisation. That independence is why Rayon can spread clusters across cores.

**Why the chains are dependent, and short.** Each binary-search step loads `arr[mid]`, and the *next* mid depends on the outcome of the comparison — the CPU cannot issue load i+1 before load i returns. That defeats out-of-order execution, which normally hides memory latency by overlapping independent loads. Short: log2(142) ≈ 7 steps for the first search, log2(hists-per-cluster) ≈ 15 for the second.

**Why search and emit stress different hardware.** Search performs a handful of dependent reads over cache-resident data: latency- and cache-sensitive, few bytes moved. Emit writes out potentially thousands of matching IDs per (query, cluster): allocation-heavy and write-bandwidth-heavy. Different resources, different ceilings, which is why the campaign measures them separately (suppress mode cuts emit off).

**Serialised per-cluster loop.** The cluster loop *could* run in parallel, but under the GIL only one thread executes Python bytecode at any instant, so cluster i+1 always waits for cluster i no matter how many threads exist. Parallelism in name only; the measured flat thread sweep is this.

**Retiring an instruction.** Modern CPUs execute instructions speculatively and out of order; an instruction *retires* when it completes and its result is made permanent, in program order. Retired-instruction counts therefore measure how much work the program really did. Python retires 6.2× the instructions for the same logical work — that surplus is interpreter dispatch and bookkeeping.

**Regime.** A region of the operating space — (dataset scale or density, thread count) — where one mechanism dominates the wall time. t≈16 on dense clusters is the arena-mutex regime; t∈[32,48] is the memory-pressure regime; t>48 is the UPI regime. Optimisations are judged per regime, and the dispatch policy is a map from regime to build.

**Arena mutex, glibc allocator, pooled buffers.** The glibc allocator is the malloc implementation in Linux's C library; Rust's default allocator forwards to it. It manages memory in arenas — pools, each protected by a mutex (a lock). When many threads simultaneously allocate and free small result vectors, they queue on those locks: allocation itself becomes the serial bottleneck. `pooled` pre-allocates one reusable output buffer per query and emits into it, instead of allocating a fresh vector per matching cluster — allocations per query drop from "number of matching clusters" to about one, and the contention disappears. Hence −20.2% at t=16 standalone.

**Ceiling (ii) slide, in easy words.** The L3 is the last cache before RAM, shared by all 48 cores on a socket. The expectation was: threads' combined data overflows it at moderate thread counts, misses go up, so shrinking the data (f16) should help. The measurement said otherwise. The biggest win was not a cache effect at all — threads were fighting over the allocator's lock, and pooled buffers fixed that. f16, the textbook cache optimisation, won nothing on the dense workload and actually dragged the bundle down, yet saved 20% on the sparse workload — because only there does halving the data actually move it into a cache level it previously missed. The lesson: "the L3 ceiling" is two different mechanisms depending on workload shape.

**STREAM peak.** STREAM is the standard memory-bandwidth benchmark (its Triad kernel streams three large arrays: a[i] = b[i] + q·c[i]); the number it reports is the machine's practical maximum RAM throughput — here ~330 GB/s aggregate. Our workload's cache-miss traffic computes to ~0.5% of that, which is why "bandwidth-bound" would be the wrong claim.

**numactl probe.** `numactl` is a Linux tool that controls which socket's cores and memory a process may use. The four-configuration probe runs the identical workload under four placements — default, everything bound to one socket, memory interleaved across sockets, and so on — and compares walls. The differences isolate how much of the wall time is cross-socket traffic, which is what separates ceiling (iv) from ceiling (iii).

**Prefetcher.** A hardware unit that watches the pattern of memory accesses and fetches the predicted next cache lines before the program asks for them. It works on contiguous streams. Interleaved placement alternates the physical location of data between sockets every 4 KB page, so the stream keeps breaking — that is why interleave regresses 26–41%.

**The five axes, one by one.** Each negative-composability pair lives on its own hardware resource. (1) Emit-phase bandwidth: bytes written when outputting matching IDs; packed-ids shrinks them, but pooled had already removed the allocator pressure that was the real cost there. (2) Cluster cold-load size: the cost of pulling a cluster's data into cache on first touch; query-batch amortises it across K queries, but f16 had already halved the bytes, leaving too little to amortise against the batching overhead. (3) Cross-worker coordination: morsel scheduling makes workers reuse each other's cached clusters explicitly, but the shared 105 MiB L3 was already doing that implicitly, so the coordination is pure overhead. (4) Decoder access pattern (read-side bandwidth): local-ids narrows IDs from ~20 to ~13 bits, but the 13-bit decoder's walk over the packed buffer multiplies dTLB misses 52×. (5) Memory-locality placement: interleave balances bytes across sockets but destroys contiguity and defeats the prefetcher, where first-touch had kept each cluster node-local.

**packed-ids.** An emit optimisation. The default writes each matching histogram ID as a 32-bit integer. packed-ids writes them bit-packed at the minimum width the ID range requires (~20 bits here), cutting emit bytes by roughly a third. It wins standalone at t=64, where memory traffic binds, and regresses inside best-combo, where pooled has already collected that headroom.

**Pre-flight slide, in easy words.** The normal way to do performance work: have an idea, build it, measure it, keep it if it is faster. That works when improvements are independent. On this workload they are not: whether idea B helps depends on what the *current* bottleneck is after everything already applied — and each applied optimisation can move the bottleneck somewhere else. So before building B, use the CPU's built-in event counters to check what the bottleneck actually is in exactly the configuration B would join. If B targets a bottleneck that is no longer there, do not build it. Five times out of five in this thesis, that check would have predicted the failures that were instead discovered by building and measuring.

**How the dispatch validation was measured, and 17/18 of what.** The calibration grid is 3 datasets × 6 thread counts {1, 8, 16, 32, 64, 96} = 18 cells. Every candidate build was benchmarked in every cell: 5 repetitions, median wall, suppress mode. The "regime-best" for a cell is simply the build with the lowest median wall there. The policy is a fixed lookup table derived from that same grid, so in-distribution validation asks: in each cell, does the policy's pick equal the measured best build? Yes in 17 of 18; the one miss (c256_30gb at t=64) costs +4.7% over the best, inside that cell's noise band. Because the boundaries were read off the same grid, this only proves the table was derived consistently — the real test is the OOD dataset the policy was never tuned on: five candidate builds at six thread counts, five reps each, 150 fresh measurements, and the policy's pick lands within 1% of the measured best in all six cells. Combined record: 23/24 within 5%.

---

## Part 7: Fainder end-to-end, precisely — with a worked example

**What a histogram is, concretely.** GitTables is ~1M CSV tables from GitHub, ~120M columns. For each numeric column with at least 100 rows, a histogram is computed: two arrays, `bin_edges` (the range boundaries, sorted floats) and `counts` (how many values fell in each range). That pair *is* the histogram; the raw values are gone. 5,017,619 of these survive the filter.

**Clustering, precisely.** Each histogram is fed to K-means as a vector describing its shape. K-means groups vectors that are close together, so histograms with similar value ranges and similar shapes land in the same cluster. (The pipeline uses MiniBatchKMeans, which updates centroids from small random batches so it scales to 5M.) Your phrasing "the more their boundaries overlap" is a decent intuition for the *effect* — clusters end up containing histograms whose ranges overlap — but the mechanism is vector similarity, not an overlap test. **Effective clusters** is not a threshold: K-means targets k clusters, but some come out empty and small ones get merged; whatever remains populated is the effective count (191 of 256 on the primary workload, 610 of 1024 on OOD).

**Alignment (rebinning), precisely.** After clustering, each histogram in a cluster still has its *own* bin edges — they can't be compared position-by-position. Rebinning fixes that: the cluster gets one shared grid of bin edges, and each member histogram is re-expressed on it. For each shared bin, take every original bin that overlaps it and assign the overlapping *portion* of its count, splitting counts proportionally where an original bin straddles a shared edge. That proportional split is where the small alignment error comes from (values inside a bin aren't actually uniform). Fainder also has a second, more accurate alignment called conversion, at 2× memory and 10–15% slower queries; the thesis uses rebinning throughout. The shared grid is the **bin-boundary array**: one sorted f32 array per cluster — literally something like `[0.0, 3.1, 7.9, …, 4812.0]` — about 142 entries on the primary workload.

**Cumulative densities, precisely.** For one rebinned histogram, normalise the counts (so they sum to 1) and take the running total. The value at shared edge b is then "the fraction of this column's values that are ≤ b" — its CDF sampled at the shared edges. "Cumulative density at boundary b" is that number. They are *of* the histogram's value distribution, and they are precomputed because they never change after construction.

**The index structure and the column slice.** Per cluster, picture a matrix: one row per histogram (n rows), one column per shared bin edge (b columns), each cell the cumulative density of that histogram at that edge. Fainder stores it column-major — all n values for edge k are contiguous — and, crucially, each column is stored *sorted*, with a parallel array holding the histogram IDs in the same order. The **column slice** is one such column: `values[k*n .. (k+1)*n]`, the n sorted cumulative densities at edge k. That's 10 KiB on the small dataset and ~105 KiB on the primary one.

**A worked query.** Query: "90th percentile > 1000", i.e. (p=0.9, >, τ=1000). Key equivalence to have cold: *the 90th percentile of a column exceeds 1000 exactly when fewer than 90% of its values are ≤ 1000* — that is, when its cumulative density at 1000 is below 0.9. Per cluster: (1) binary-search the bin-boundary array for 1000 → say it lands in bin k=37. (2) Take the column slice at edge 37 — n sorted fractions — and binary-search for 0.9: `partition_point` finds the cut where values reach 0.9. Every histogram *before* the cut has cumulative density < 0.9, so all of them match. (3) Emit: copy the ID array entries for that prefix. Union the per-cluster answers; done. Two binary searches and a copy, per cluster, per query.

**Why the cluster loop parallelises naturally.** The cluster loop is the outer loop "for each cluster: search, search, emit". Cluster c's answer depends only on cluster c's arrays — no shared mutable state, no ordering requirement, and the final union doesn't care who finished first. Embarrassingly parallel; Rayon just hands clusters (or queries, in the row-centric engine) to idle threads.

**If suppress doesn't emit, how was correctness checked?** Suppress mode is a *stopwatch* configuration, not a correctness configuration. Correctness is validated in with-results mode: the engine produces its full result sets and the harness compares them against the Python reference — bitwise-identical, precision = recall = 1.000, on every workload and build. Suppress exists only to time the search phase without the emit cost mixed in.

**The rebinning kernel (construction side), re-explained.** Construction has to do, per cluster: (1) rebin every member histogram onto the shared grid, (2) cumulative-sum each one, (3) per shared edge, sort the histograms by their cumulative value and record the ID order (that's what makes the columns sorted). Python does step 1 per-histogram under `multiprocessing.Pool`, then steps 2–3 as NumPy `cumsum` + `argsort` per cluster — three passes, with process-spawning and data-shipping overhead. The Rust kernel fuses all three into one parallel call per cluster under Rayon. Result: 4.72× and 4.77× faster at the two smaller scales, 2.18× at 5M. The drop at 5M is the kernel's own parallelism ceiling — at that scale it effectively uses ~2 cores of 96, with ~46% of kernel time in one shared per-cluster allocation (and not "NumPy is good at bulk ops"; that hypothesis was tested and refuted). Why port construction at all: at 5M histograms the Python rebinning takes ~54 minutes (3,220 s) per index build — long enough to be the pipeline's own bottleneck — and the same fused-kernel engineering that fixed the query phase applied directly. Correctness: verified on 200 queries; Rust rounds half-away vs NumPy's banker's rounding, max cumulative difference 1e-4, no effect on any sort order or result.

**A mutex.** Mutual-exclusion lock: a flag around a shared resource that only one thread may hold at a time; everyone else waits in line until it's released. The glibc allocator guards its internal arenas with mutexes — that's the line threads were waiting in.

---

## Part 8: Every optimisation — what it does, an example, and why it won or lost

Grouped by the ceiling it targeted. "Standalone" = feature vs default build; "in bundle" = added to or removed from best-combo.

### Latency side (ceiling i) — all four null, and that is the finding

**simd (AVX-512 leaf stage).** Binary search halves the window until it's small; the last ~4 halvings cover ≤16 values. This feature replaces those last iterations with one vector instruction: load 16 f32s into one 512-bit register, compare all 16 against the query value at once (`_mm512_cmp_ps_mask`), get a 16-bit mask, count its bits — that count is the cut position. One load+compare instead of four dependent load-compare-branch rounds. **Verdict: null (0.90–1.13× everywhere).** Why: those last iterations hit L1 — a few cycles each. There was nothing slow to replace.

**batch-search (8-way interleaving).** Run 8 *independent* searches over the same column simultaneously, round-robin: issue search 1's load, then search 2's, … so while search 1's read is in flight the CPU works on the others (the hardware supports ~dozens of outstanding misses per core via MSHRs). Classic latency-hiding for hash joins (Kocberber et al.). **Verdict: null.** Why: latency hiding pays when reads miss cache; these reads hit L1/L2, so there was no latency to hide, only interleaving bookkeeping to pay.

**horizontal-simd (16-query lockstep).** Sixteen queries walk their binary-search trees in lockstep through one column, sharing the loads at each level (Polychroniou-style). **Verdict: null — and per the related-work chapter, the first such measurement on Sapphire Rapids at cache-resident scale.** Same reason: the shared loads were already cheap.

**pgm (learned index).** Instead of searching, *predict*: fit piecewise-linear segments to the sorted column, compute the approximate position from the model, then scan a small window around the prediction. Replaces the dependent-load chain with one multiply-add plus a local scan. **Verdict: null/marginal.** Why: the chain it replaces was ~15 cache-resident steps; the model's residual scan costs about the same, and the segments occupy cache too.

**(eytzinger and 4-way k-ary search: earlier-campaign variants, dropped from the final build.** Eytzinger reorders the array so the search tree's top levels share cache lines — its advantage exists on *cache-cold* data, and Fainder's columns are cache-resident after warm-up. k-ary shortens the chain by cutting in 4 instead of 2 — the slack it recovers only exists at t=1.)

### Footprint / layout (ceiling ii)

**aos (negative control — built to *lose*).** Interleaves (value, ID) pairs, so every cache line fetched during search carries a never-read 32-bit ID next to each value — half the line is waste. **Verdict: +17% penalty at t=8 on the primary workload (as designed) — then a small *win* (−4 to −6%) at t=64/96.** Why the flip: at moderate t the wasted line halves effective cache capacity, exactly when L3 is the constraint. At high t the constraint is memory traffic during *emit* — and there AoS's adjacency (the ID sits right next to the value you just matched) saves a separate fetch. The flip is evidence the binding ceiling itself moves with t.

**f16 (half precision).** Store cumulative densities as 16-bit floats instead of 32-bit — half the footprint — converting back to f32 at each comparison. **Verdict: no standalone win anywhere on the primary workload; +15.6% drag inside the bundle at t=16; but saves 20.9% inside the bundle on the sparse OOD workload.** Why: on the dense workload the ~105 KiB column slice was already L2-resident — halving it unlocks no new cache level, while every comparison pays conversion. On the sparse workload the *aggregate* working set (610 clusters) is the constraint, and halving it genuinely relieves it. Footprint optimisations are density-conditional.

### Allocation / memory management (ceiling ii's real mechanism on dense data)

**pooled (pre-allocated output buffers).** Default emit allocates a fresh vector for every (query, matching cluster) — up to millions of little malloc/free calls. Pooled allocates one reusable buffer per query and appends into it. **Verdict: −46.9% at t=1, −34.1% at t=8, −20.2% at t=16 standalone; but its bundle contribution collapses to +4.4% at t=16 and flips negative (−9.4%) at t=32.** Why it wins at t=1 (your question — there's no lock contention single-threaded): the win there is the *allocation work itself* — malloc/free per cluster, page faults, allocator metadata churn — removed. At t=8–16 a second mechanism stacks on top: threads queue on the allocator's arena mutex, and pooling removes the queue. Why it flips at t=32–64: there the binding ceiling is memory-traffic pressure, which pooling doesn't address — and its retained buffers add footprint to an already-pressured system.

**mimalloc (replacement allocator).** Swaps glibc malloc for Microsoft's mimalloc, which has per-thread heaps and less lock contention. **Verdict: *hurts* at low t (+22% at t=1/8), wins −10% at t=32.** Why: mimalloc pays per-thread arena warm-up; at low t that dominates, at t=32 its reduced contention pays.

**pin-cores.** Pins each Rayon worker to its own physical core so the OS can't co-schedule two workers on one core's SMT siblings. **Verdict: −19% at t=32; neutral-to-negative at t≥64.** Why: at t=32 pinning prevents accidental sibling-sharing; at t≥64 there are more workers than physical cores, sharing is unavoidable, pinning has nothing left to prevent.

**cluster-prefetch.** Bundle feature that starts pulling the next cluster's data toward the caches while the current one is processed. Carried inside best-combo; no standalone headline claim in the campaign.

### Emit path (ceiling iii)

**packed-ids.** Matching IDs are written bit-packed at the minimum width the ID space needs (~20 bits for 5M IDs) instead of 32 bits — roughly a third fewer emit bytes. **Verdict: regime-best standalone at t=64 (where memory traffic binds); negative in 12/18 cells layered on best-combo (up to +24%).** Why the split: standalone at high t, emit bytes are the binding cost, so cutting them pays. Inside the bundle, pooled had already defused the emit-side pressure — the packing/unpacking overhead found no residual saving to offset it.

**local-ids (per-cluster reindexing) — the falsified pre-registration.** Renumber histograms *within* each cluster (0…n_c) so IDs need only ~13 bits instead of ~20, shrinking the packed stream further; keep a per-cluster table to translate back to global IDs at the end. "It's just renumbering" — the renumbering is indeed cheap; the cost is on the *read* side. Every consumer of the packed stream now runs a 13-bit decoder, and its access pattern over the packed buffer drives the dTLB (the cache of virtual-to-physical page mappings) to a **52× higher miss rate per instruction** — each miss is a ~100-cycle page-table walk — plus the local→global translation touches the per-cluster tables on top. **Verdict: +186 to +245% at t∈[8,64].** The bandwidth saved was real; the address-translation stalls it bought cost multiples more. This is the thesis's showcase for pre-flight checking: the prediction was pre-registered, plausible, and wrong in a way one perf probe would have caught.

### Scheduling / work shape (work-fragmentation regime)

**column-centric engine — how to visualise it.** Default (row-centric): *queries* are the parallel units. A thread grabs a query and walks all ~191 clusters with it — so each cluster's data gets pulled into cache once per query, 10,000 times over the run. Column-centric inverts it: *clusters* are the parallel units. A thread grabs a cluster, pulls its data into cache once, and runs all 10,000 queries against it while it's warm, then moves on. **Verdict: wins 2.17–2.63× at t=1; loses ~2× at t≥8.** Why it wins at t=1: pure cache reuse — each cluster is loaded once total instead of once per query. Why it loses with threads: clusters are wildly unequal in size, and with only ~191 lumpy work units, the thread holding the biggest cluster becomes the long pole while others finish and idle. Row-centric has 10,000 uniform work units — work-stealing balances those effortlessly.

**query-batch (K=64/128).** The middle ground: keep queries as the outer parallel dimension, but in *chunks* of K; inside a chunk, visit clusters outer-loop so each cluster's cold-load is amortised over K queries instead of 1. **Verdict: regime-best standalone at t=96; negative at every cell layered on best-combo (+8 to +32%).** Why it wins standalone at t=96: at extreme thread counts, per-query tasks are tiny and fragmented, and batching restores meaty work units. Why it regresses on the bundle: best-combo contains f16, which already halved every cluster's cold-load size — the thing query-batch amortises shrank below the batching overhead (route preprocessing, per-batch state) it pays.

**morsel (morsel-driven phase coordination).** On top of query-batch, coordinate *across* workers so different workers visit the same cluster around the same time and share its cache residency (HyPer-style morsel scheduling). **Verdict: negative at every cell (+8 to +12%).** Why: the 105 MiB shared L3 was already absorbing cross-worker cold-loads implicitly — a cluster one worker loaded was still resident when another arrived. Explicit coordination duplicated a service the hardware provides free, and billed for it.

### NUMA placement (ceiling iv)

**first-touch (default).** Memory pages land on the socket of the thread that first writes them — each cluster's data ends up contiguous on one socket. **single-socket placement:** run everything (cores + memory) on socket 0 — saves 11–13% at t≤48 by eliminating cross-socket traffic entirely. **interleave:** alternate pages round-robin between sockets in 4 KB units — "fair", and −26 to −41% *worse*: every cluster's data is shredded across both sockets in 4 KB stripes, the stride breaks the hardware prefetcher's pattern detection, and half of all accesses are remote. The negative-composability instance: interleave layered on (already node-contiguous) first-touch.

### The bundle

**best-combo = pooled + f16 + simd + pin-cores + cluster-prefetch + mimalloc.** At t=16 on the primary workload it runs at 0.773× the default's wall (22.7% faster). Internal accounting to have ready: pooled carries essentially the entire win at that cell; f16 is a drag the other five absorb; the rest contribute at their own regime cells. That internal tension is itself evidence for the composability finding.

**Bandwidth-budget arithmetic (the pre-flight prediction step, since you asked).** Count the bytes an optimisation saves per event, multiply by the event rate, compare to the measured traffic at the binding ceiling. Example for packed-ids: 12 bits saved per emitted ID × measured emits/second = GB/s saved; set against the cell's measured memory traffic, that predicts at most a few percent of wall — so if the measured composition shows no memory-traffic headroom anyway, the optimisation cannot pay for its own decode cost. Arithmetic first, implementation second.

---

## Part 9: A complete worked example, with the data at every stage

Toy scale — 6 histograms, 2 clusters, 4 shared bins — but every mechanism is the real one.

### Stage 0: GitTables

Six numeric columns from various CSVs. The raw values exist only at the publisher; what gets published is one histogram per column.

### Stage 1: histograms (what is actually stored)

A histogram is two arrays: bin edges and counts.

| ID | column | bin edges | counts | n |
|----|--------|-----------|--------|---|
| H1 | temperature_c | [0, 10, 20, 30, 40] | [100, 400, 300, 200] | 1000 |
| H2 | cpu_temp | [10, 20, 30, 50] | [50, 100, 50] | 200 |
| H5 | water_temp | [0, 15, 30, 45] | [60, 90, 50] | 200 |
| H3 | salary_eur | [20000, 40000, 60000, 100000] | [300, 500, 200] | 1000 |
| H6 | price_eur | [10000, 50000, 90000] | [400, 100] | 500 |
| H4 | humidity_pct | [0, 25, 50, 75, 100] | [10, 40, 30, 20] | 100 |

Note: every histogram has its *own* edges. H1's third bin is 20–30, H5's second is 15–30. You cannot compare them position-by-position yet.

### Stage 2: K-means clustering

Each histogram becomes a shape vector; K-means groups similar ones. Small-range temperature-like shapes land together, huge-range money shapes land together:

| Cluster | members |
|---------|---------|
| A | H1, H2, H5 (ranges within 0–50) |
| B | H3, H6 (ranges 10,000–100,000) |

(H4 would land wherever its shape fits; drop it from here for brevity. If K-means had produced an empty or tiny third cluster, it would vanish or merge — that is why "effective clusters" < target k.)

### Stage 3: rebinning cluster A onto a shared grid

Cluster A gets one shared grid: edges [0, 10, 20, 30, 50]. Each member is re-expressed on it. H1 and H2's edges already align, so their counts just move over. H5's do not — its bins straddle the shared edges, so counts split *proportionally*:

H5 original: [0,15)=60, [15,30)=90, [30,45)=50.

| shared bin | contribution from H5's bins | count |
|------------|------------------------------|-------|
| 0–10 | 10/15 of the [0,15) bin = 40 | 40 |
| 10–20 | 5/15 of [0,15) = 20, plus 5/15 of [15,30) = 30 | 50 |
| 20–30 | 10/15 of [15,30) = 60 | 60 |
| 30–50 | all of [30,45) | 50 |

That proportional split assumes values are spread evenly inside a bin — this is the alignment error, and the reason the higher-accuracy "conversion" variant exists.

### Stage 4: cumulative densities

Per histogram: normalise counts by n, take the running total. Value at edge b = fraction of the column's values ≤ b.

| ID | ≤10 | ≤20 | ≤30 | ≤50 |
|----|-----|-----|-----|-----|
| H1 | 0.10 | 0.50 | 0.80 | 1.00 |
| H2 | 0.00 | 0.25 | 0.75 | 1.00 |
| H5 | 0.20 | 0.45 | 0.75 | 1.00 |

### Stage 5: the index (what the engine actually holds)

Per shared edge, the column of cumulative densities is stored **sorted**, with the IDs in matching order. This is the SubIndex; one column of it is a *column slice*:

| edge | sorted values (column slice) | ids |
|------|------------------------------|-----|
| ≤10 | [0.00, 0.10, 0.20] | [H2, H1, H5] |
| ≤20 | [0.25, 0.45, 0.50] | [H2, H5, H1] |
| ≤30 | [0.75, 0.75, 0.80] | [H2, H5, H1] |
| ≤50 | [1.00, 1.00, 1.00] | [H1, H2, H5] |

Column-major storage means these four columns sit back-to-back in one flat array. The *bin-boundary array* is just [0, 10, 20, 30, 50]. Cluster B has its own grid and its own SubIndex, completely separate — that separateness is why clusters parallelise.

### Stage 6: a query, end to end

**Query: "find all columns whose median is above 20"** = (p=0.5, >, τ=20).

The equivalence that drives everything: *median > 20 ⟺ fewer than half the values are ≤ 20 ⟺ cumulative density at 20 is < 0.5.*

**Cluster A:**
1. Binary search τ=20 in [0, 10, 20, 30, 50] → edge index 2 (the ≤20 column). ~2 probes.
2. Binary search p=0.5 in the ≤20 column slice [0.25, 0.45, 0.50] → `partition_point(< 0.5)` returns cut = 2: the first two entries are below 0.5. ~2 probes.
3. Emit: the first two IDs of that column's ID array → **H2, H5**. (H1 sits exactly at 0.50 — half its values are ≤20, so its median is not *above* 20. The cut excludes it. Boundary cases live or die on the partition_point semantics; this is why bitwise validation against the reference matters.)

**Cluster B:** τ=20 is below the cluster's entire range [10,000–100,000]. The range check short-circuits *before any search*: every salary value exceeds 20, so cumulative density at 20 is 0 for every member — all match. Emit all of cluster B → **H3, H6**. (This is the fast path that also explains Python's inverted scaling: more out-of-range queries = more skipped searches.)

**Union: {H2, H5, H3, H6}.** Two binary searches and a copy for cluster A, a range check for cluster B. At real scale: same thing, ~191 clusters, 142-edge grids, 26,000-entry column slices, 10,000 queries.
