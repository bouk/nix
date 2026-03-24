---
name: research
description: Start an autonomous research loop to optimize nix eval performance. Modifies C++ source, builds, benchmarks warm eval time, keeps improvements, discards regressions. Runs indefinitely.
argument-hint: "[optional: run tag e.g. mar24]"
---

# autoresearch — nix eval performance

This is an experiment to have the LLM autonomously research and optimize nix evaluation performance.

## Setup

To set up a new experiment:

1. **Agree on a run tag**: If `$ARGUMENTS` is provided, use it as the tag. Otherwise propose a tag based on today's date (e.g. `mar24`). The branch `autoresearch/<tag>` must not already exist — this is a fresh run.
2. **Create the branch**: `git checkout -b autoresearch/<tag>` from current HEAD.
3. **Read the in-scope files**: Read these files for full context on the evaluator hot path:
   - `src/libexpr/eval.cc` — core evaluation loop, `forceValue`, `callFunction`, expression dispatch
   - `src/libexpr/eval-inline.hh` — inlined hot-path functions (thunk forcing, value allocation)
   - `src/libexpr/include/nix/expr/eval.hh` — `EvalState` class definition
   - `src/libexpr/include/nix/expr/value.hh` — `Value` type and representation
   - `src/libexpr/include/nix/expr/attr-set.hh` — attribute set data structure
   - `src/libexpr/attr-set.cc` — attribute set operations
   - `src/libexpr/primops.cc` — builtin primops
   - `src/libstore/daemon.cc` — daemon protocol (server side)
   - `src/libstore/remote-store.cc` — daemon protocol (client side)
   - `src/libstore/uds-remote-store.cc` — Unix domain socket store
   - `src/libutil/serialise.cc` — serialization primitives
   - `testsystem.nix` — the benchmark workload (do NOT modify)
   - `tests/nixos/eval-benchmark.nix` — the benchmark test (do NOT modify)
4. **Run the baseline benchmark** and record the result.
5. **Initialize results.tsv**: Create `results.tsv` with just the header row. The baseline will be the first entry.
6. **Confirm and go**: Confirm setup looks good.

Once you get confirmation, kick off the experimentation.

## Experimentation

The benchmark evaluates a NixOS system configuration (~5500 derivations). It measures **warm** evaluation time — the time after caches are populated.

**What you CAN modify:**
- `src/libexpr/` — the Nix expression evaluator (thunk forcing, function calls, attribute lookups, primops, etc.)
- `src/libstore/` — store operations, daemon protocol, client-daemon communication
- `src/libutil/` — utility functions, serialization, data structures
- `src/libcmd/` — command infrastructure
- `src/libmain/` — main entry points
- `src/nix/` — CLI commands
- `src/libfetchers/` — fetcher implementations
- Any meson build files needed to compile your changes

**What you CANNOT modify:**
- `testsystem.nix` — the benchmark workload is fixed
- `tests/nixos/eval-benchmark.nix` — the benchmark test is fixed
- `flake.nix` — the build infrastructure is fixed
- `.claude/skills/research/SKILL.md` — this skill file
- `results.tsv` contents of previous experiments (append only)

**The goal is simple: get the lowest benchmark time.** Everything in the C++ source is fair game: data structures, algorithms, caching, protocol changes, memory layout, parallelism. The only constraint is that the code compiles, passes tests, and produces correct output (the same drv path).

**Correctness constraint**: The eval must produce the exact same derivation path as the baseline. If the output changes, the experiment is invalid — discard it.

**Simplicity criterion**: All else being equal, simpler is better. A small improvement that adds ugly complexity is not worth it. Removing code and getting equal or better results is a great outcome. When evaluating whether to keep a change, weigh the complexity cost against the improvement magnitude.

## Benchmark procedure

The benchmark runs as a NixOS VM test at `tests/nixos/eval-benchmark.nix`. It builds nix from the local source tree (via the flake's overlay), boots a VM, performs 1 warmup eval followed by 3 timed evals, and reports the average.

### Running the benchmark

```bash
# Build and run the VM benchmark test
nix build .#checks.x86_64-linux.eval-benchmark -L 2>&1 | tee build.log
```

This single command:
1. Builds your modified nix from source
2. Creates a NixOS VM with that nix installed
3. Runs the benchmark inside the VM (1 warmup + 3 timed evals)
4. Reports results in the test log

### Extracting the metric

The benchmark prints results to the test log. Look for lines like:

```
BENCHMARK RESULT: average=X.XXXs runs=[...]
BENCHMARK_JSON: {"avg_seconds": X.XXX, "runs": [...]}
```

Extract from the build log:
```bash
grep "BENCHMARK_JSON" build.log
```

The key metric is **average wall-clock seconds** over 3 warm runs. Lower is better.

### Verifying correctness

The benchmark test evaluates the testsystem drv path. After each experiment, verify the output matches the baseline by checking the eval output in the log. If the drv path changes, the experiment is invalid.

## Logging results

When an experiment is done, log it to `results.tsv` (tab-separated).

The TSV has a header row and 5 columns:

```
commit	avg_seconds	build_seconds	status	description
```

1. git commit hash (short, 7 chars)
2. average eval time in seconds (e.g. 4.567) — use 0.000 for crashes/build failures
3. nix build time in seconds (approximate) — use 0 for crashes
4. status: `keep`, `discard`, `crash`, or `build-fail`
5. short text description of what this experiment tried

Example:

```
commit	avg_seconds	build_seconds	status	description
a1b2c3d	5.234	180	keep	baseline
b2c3d4e	4.891	185	keep	use flat_hash_map for env lookups
c3d4e5f	5.301	190	discard	prefetch attribute set sizes
d4e5f6g	0.000	0	build-fail	replace Boehm GC with arena allocator (compile errors)
```

## The experiment loop

The experiment runs on a dedicated branch (e.g. `autoresearch/mar24`).

LOOP FOREVER:

1. Look at the git state: the current branch/commit we're on, and the results so far
2. Think about what to try next. Consider:
   - What has worked/not worked so far
   - Profile data if available (use `nix eval --profile-eval --profile-eval-file profile.dat` or `--trace-function-calls`)
   - The evaluation hot path: thunk forcing, function calls, attribute lookups, string operations
   - Client-daemon communication overhead
   - Memory allocation patterns (Boehm GC, value allocation)
   - Data structure choices (attribute set representation, environment frames)
   - Caching opportunities
3. Edit the C++ source with your idea
4. git commit
5. Run the benchmark: `nix build .#checks.x86_64-linux.eval-benchmark -L > build.log 2>&1`
6. If build fails: read `tail -n 50 build.log`, attempt a fix. If you can't fix after a few attempts, give up on this idea.
7. Extract timing from the build log
8. Verify correctness (drv path must match baseline)
9. Record the results in the tsv (do NOT commit results.tsv — leave it untracked)
10. If avg_seconds improved (lower) AND correctness passes: keep the commit, advance the branch
11. If avg_seconds is equal or worse, or correctness fails: `git reset --hard HEAD~1`

**Timeout**: If a build exceeds 30 minutes, kill it and treat it as a failure. If an eval run exceeds 5x the baseline time, kill it.

**Crashes**: If a run crashes, use your judgment. If it's something easy to fix (typo, missing include), fix and re-run. If the idea is fundamentally broken, log "crash", discard, and move on.

**NEVER STOP**: Once the experiment loop has begun, do NOT pause to ask the human if you should continue. The human might be asleep or away. You are autonomous. If you run out of ideas, think harder — read the source more carefully, try combining previous near-misses, try more radical changes, use profiling to find new bottlenecks. The loop runs until the human interrupts you.
