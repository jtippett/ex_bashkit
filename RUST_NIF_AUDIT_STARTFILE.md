# Rust NIF Security & Correctness Audit Startfile

> Give an auditing agent this instruction: **Read this file in full, then execute
> it as the task specification. Audit the whole repository, fix confirmed bugs,
> add regression tests, and do not stop at a checklist or report.**

This file is a reusable startfile for Elixir/Erlang libraries backed by Rust NIFs,
especially Rustler and RustlerPrecompiled projects. It is intentionally more
demanding than an ordinary code review. Copy it into another repository as-is;
the auditor must discover that repository's layout and replace the local profile
rather than assuming it matches this project.

## Mission

Perform a hostile-input, failure-oriented security and correctness audit of the
entire library. Treat every value crossing the BEAM/native boundary, every
callback crossing back into the BEAM, every asynchronous lifecycle transition,
and every security promise delegated to an upstream crate as a potential fault
line.

The objective is not merely to identify bugs. Safely fix every confirmed,
in-scope defect; add a regression test that would have caught it where practical;
search for sibling instances of the same mechanism; update inaccurate contracts
or maintenance documentation; and run the strongest relevant validation gates.

Work from a visible plan and keep a finding ledger while investigating. A useful
ledger records the surface, invariant, evidence inspected, candidate failure,
reproducer, disposition, fix, and test. Continue across the entire map after the
first finding; do not let one productive bug fix prematurely end the audit. Make
reasonable, reversible in-scope fixes without waiting for confirmation, and ask
the owner only when a choice would materially alter public policy or scope.

The audit must answer all of these questions with evidence:

1. Can any public input, callback result, corrupt state, race, or resource failure
   panic native code, crash the VM, kill an unrelated BEAM process, deadlock a
   scheduler, silently corrupt data, leak a capability, or bypass a default-deny
   policy?
2. Do validation, error, timeout, cancellation, and cleanup semantics remain
   correct at their exact minimum, maximum, and race boundaries?
3. Does the wrapper actually provide the contract it documents, including when
   the upstream crate warns, skips, defaults, truncates, coerces, or partially
   succeeds instead of returning an error?
4. Are the locally built NIF, shipped precompiled NIFs, feature flags, ABI,
   checksums, package contents, CI jobs, and dependency locks describing the same
   product?
5. Would the tests catch the next bug from the same family rather than only the
   exact payload from the last incident?

## Authority and guardrails

The auditor is authorized to inspect and modify code, tests, locks, and
documentation inside this repository to fix confirmed security or correctness
problems. Keep public compatibility unless changing it is necessary to make an
unsafe or misleading contract safe. Prefer explicit construction-time errors to
deferred, opaque, or silently ignored failures.

Do not:

- publish packages, create releases, push branches, tag versions, alter external
  services, or rotate credentials;
- rewrite unrelated code or user changes;
- weaken a test, validation rule, sandbox boundary, or default-deny policy merely
  to make a gate pass;
- trust generated docs, comments, type specs, wrapper checks, or upstream
  documentation without comparing them to executable code;
- call an audit complete because scanners and the existing test suite are green;
- run a suspected VM-crashing reproducer in a long-lived development VM when it
  can be isolated in a short-lived OS subprocess.

Use temporary directories, loopback test servers, synthetic callbacks, and
disposable subprocesses. Never test destructive filesystem or network behavior
against real sensitive resources.

Preserve the initial worktree state. Record pre-existing changes and do not
attribute them to the audit. Do not use destructive Git commands to prove a
regression; use a focused reproducer, existing history, or reasoned before/after
evidence.

## Non-negotiable audit principles

- **The NIF boundary is a safety boundary.** A normal application bug may crash a
  process; a native bug may crash or corrupt the VM. Validation deserves defense
  in depth where malformed data could reach unsafe or assumption-heavy code.
- **Failure paths are first-class product paths.** Review allocation failure,
  send failure, callback death, caller death, timeout, cancellation, partial
  initialization, poisoned state, malformed upstream output, and cleanup.
- **Fault containment has two directions.** Upward faults must not escape into an
  unrelated caller or supervisor. Downward cancellation must still terminate
  in-flight work and prevent late side effects.
- **A success value must mean the promised operation happened.** A warning,
  skipped upstream operation, substituted empty buffer, default enum branch, or
  coincidental postcondition is not success.
- **Bounds must be checked where configured.** Do not defer an invalid timeout,
  size, integer, path, or option until a rare runtime branch executes.
- **Conversions are semantic code.** Signedness, width, UTF-8, NULs, atoms,
  lists, binaries, paths, enum tags, lengths, and error mappings all require
  explicit review.
- **Cancellation is part of memory and capability safety.** Every request-table
  slot, monitor, task, native future, resource reference, mailbox message, and
  callback child needs an owner and cleanup path.
- **Upstream security policy is versioned code.** If the wrapper duplicates or
  strengthens upstream behavior, record the exact invariant and review it on
  every dependency update.
- **Tests must prove survival and absence.** For failures, assert not just an
  error result but also VM/caller survival, session reuse where promised, no late
  side effect, no leaked pending state, and bounded completion.

## Phase 1: establish the baseline

Before editing:

1. Read all repository instructions and architecture/release documents. Inspect
   `README`, changelog, security policy, handoff/porting/update notes, `mix.exs`,
   every `Cargo.toml`, lockfiles, NIF loader/stubs, CI/release workflows, and
   packaging configuration.
2. Inspect `git status`, the recent commit history, recent bug fixes, open
   incident reports, TODO/FIXME comments, and blame/history around dangerous
   boundaries. Start with the bug that motivated the audit, but do not anchor on
   it.
3. Discover the command that forces a local source build of the NIF. Never let a
   cached or downloaded precompiled artifact accidentally stand in for the code
   being audited.
4. Record toolchain versions, supported OTP/Elixir/Rust versions, enabled Cargo
   features, target ABIs, baseline test count, warnings, failures, and skipped
   tests.
5. Run the existing fast gates before changing code. If the baseline is already
   failing, distinguish pre-existing failures from audit regressions.

Useful discovery commands include:

```sh
git status --short
git log --oneline --decorate -20
rg --files -g 'AGENTS.md' -g '*SECURITY*' -g '*AUDIT*' -g '*BUG*' -g '*INCIDENT*'
rg -n \
  -e '#\[rustler::nif|rustler::init|ResourceArc|OwnedEnv|OwnedBinary' \
  -e 'spawn|Task\.|Process\.|timeout|callback' \
  -e 'unsafe|unwrap\(|expect\(|panic!|unimplemented!|todo!' \
  .
cargo tree --manifest-path path/to/Cargo.toml -e features
```

Adapt commands to the repository; do not mechanically run a path that does not
exist.

## Phase 2: build an executable architecture map

Inventory the complete boundary before judging individual functions. Produce a
working map, in notes or the final report, containing:

- each public Elixir/Erlang entry point;
- each Elixir validation/normalization layer;
- each native stub and `#[rustler::nif]` export, including load/upgrade callbacks;
- its accepted BEAM term shape and returned term shape;
- scheduler class: normal, dirty CPU, dirty I/O, or asynchronous handoff;
- every `ResourceArc`/resource type and its ownership/lifetime rules;
- every BEAM-to-Rust and Rust-to-BEAM callback/message path;
- every global runtime, request table, registry, atom, lock, channel, monitor,
  atomic counter, or once-cell;
- every filesystem, network, subprocess, environment, clock, random, snapshot,
  deserialization, or host-capability surface;
- the upstream crate/API each wrapper path relies on;
- compile-time features and runtime gates controlling those capabilities;
- precompiled artifact targets, NIF ABI, checksums, and package/release flow.

Check bidirectional parity. Native exports and BEAM stubs must match in name,
arity, argument order, return contract, scheduler annotation, and feature gate.
Dead exports, callable-but-undocumented exports, conditional stubs, or loader
fallbacks deserve investigation.

For each asynchronous path, draw or describe the whole ownership chain, for
example:

```text
caller -> API process -> handler -> worker -> user callback
                                      |
native future <- pending request <- reply NIF/message
```

Mark who owns every link, monitor, timer, pending-table entry, and cancellation
signal. Then trace normal reply, callback error, callback uncatchable exit,
callback timeout, native timeout, caller death, handler death, late reply,
duplicate reply, VM shutdown, and resource drop.

## Phase 3: perform incident-family analysis

For every known crash or serious bug:

1. Reconstruct the complete cause chain from public input to final failure.
2. Identify the invalid assumption, not merely the line that crashed.
3. Explain why existing validation and tests missed it.
4. Reproduce it in isolation when safe. Suspected native crashes belong in a
   subprocess with an external timeout so the parent test runner can assert the
   child failed cleanly rather than losing the whole suite.
5. Add the narrow regression, then expand along five sibling axes:

   - adjacent values: empty, one-byte, max, max+1, invalid encoding, embedded
     NUL, unknown enum, wrong nesting;
   - adjacent operations: read/write, create/delete, encode/decode, init/use,
     list/stat, request/reply;
   - the same mechanism elsewhere in the wrapper;
   - the reverse direction across the NIF/callback boundary;
   - lifecycle variants: cancellation, race, caller death, repeated use, and
     concurrent sessions.

Do not overfit the fix to the original example. Convert the root cause into a
general invariant and enforce it at the earliest reliable boundary, retaining a
native backstop when violating the invariant could endanger the VM.

## Phase 4: threat model and invariants

Assume the library may receive:

- arbitrary BEAM terms despite typespecs;
- binaries that are empty, huge, invalid UTF-8, or contain NUL;
- integers at and beyond every native and BEAM representation boundary;
- maps/lists/tuples with missing, duplicated, extra, improper, or malformed
  members;
- malicious or simply buggy user callbacks that raise, throw, exit, brutal-kill
  themselves, block forever, return enormous values, return the wrong shape,
  reply twice, or produce late side effects;
- caller and owner processes that die at every point in an operation;
- concurrent calls against the same and different resources;
- upstream functions that return warnings, partial state, default values, or
  success without applying the requested operation;
- corrupt, truncated, oversized, stale, or cross-version serialized state;
- filesystem races, symlinks, aliases, platform-specific path forms, and mount
  targets that already exist for unrelated reasons;
- DNS changes, redirects, unusual IP representations, proxy environment
  variables, and URL parser edge cases;
- memory pressure and failed native allocations.

At minimum, establish and test these invariants where applicable:

- no untrusted input can panic across native code or crash/corrupt the VM;
- one session/callback failure cannot kill an unrelated caller or session;
- timeouts are bounded, accepted over their documented range, and rejected
  outside it before work starts;
- timed-out/cancelled work cannot later commit a write, reply, or external side
  effect;
- pending state is removed exactly once on success, failure, cancellation, send
  failure, and dropped future;
- malformed callback/upstream output becomes a bounded documented error;
- input bytes are either preserved exactly or the operation reports failure;
- default-deny host, filesystem, network, subprocess, and environment policies
  remain default-deny in every feature/build combination;
- a returned success cannot be inferred from a postcondition that may already
  have been true;
- resource use is bounded or explicitly documented.

## Phase 5: audit every boundary class

### BEAM term decoding and encoding

Review every decoder and encoder, including derives and helper functions.

- Enforce exact tuple/list/map shapes where ambiguity is unsafe. Decide
  deliberately whether extra fields are accepted.
- Treat atoms used as enum tags as a closed set. Never silently map an unknown
  tag to a permissive/default variant.
- Avoid creating atoms from untrusted strings. Atoms are not garbage collected
  under normal BEAM semantics.
- Test booleans versus atoms, charlists versus binaries, improper lists, missing
  keys, duplicate semantic keys, and unexpected `nil`.
- Test `i32`, `u32`, `i64`, `u64`, `usize`, timeout, length, offset, exit-code,
  and allocation-size boundaries: min, max, one beyond, negative-to-unsigned,
  and narrowing conversions.
- Test empty binaries, invalid UTF-8, embedded NUL, very large binaries, and
  non-normalized Unicode where identity matters.
- Review all length arithmetic for overflow and truncation before allocation.
- Never substitute an empty/default term after allocation, conversion, or send
  failure while returning success.
- Cap formatting/inspection of adversarial callback return values; `inspect`
  implementations can ignore ordinary pretty-print limits.
- Ensure internal details and secrets are not unintentionally exposed in errors.

Malformed data produced by a callback is still untrusted. Validate it before
encoding it for native code, and validate again natively when downstream Rust
assumes structural invariants.

### Native safety, scheduler safety, and memory

Manually review every `unsafe`, `unwrap`, `expect`, `panic!`, index operation,
unchecked conversion, FFI call, pointer/lifetime assumption, and impossible
branch. Classify whether untrusted input, allocation failure, race, version skew,
or resource drop can reach it.

Also inspect:

- terms or environments retained beyond their valid NIF lifetime;
- `OwnedEnv`, `OwnedBinary`, binary/resource ownership, `Send`/`Sync`, and drop
  order;
- panics while holding locks and poisoned-lock recovery;
- locks held across `await`, blocking work, callback sends, or reentrant calls;
- unbounded copies and memory amplification crossing the boundary;
- runtime initialization/shutdown and fork/load/upgrade behavior;
- native threads that can outlive the code/resource they reference;
- resource registration/takeover and NIF load, reload, upgrade, and unload
  behavior;
- regular NIFs that perform filesystem/network I/O, wait on locks/channels,
  initialize a runtime, or do unbounded CPU work;
- dirty NIFs that incorrectly assume the BEAM can kill them on timeout;
- nested runtime/blocking calls (`block_on`, `spawn_blocking`) and starvation;
- whether a panic is caught and translated at every native entry point. Panic
  catching is a last defense, not a replacement for removing reachable panics.

A regular scheduler NIF must be predictably short. Classify blocking I/O as dirty
I/O where the library supports it, CPU-heavy work as dirty CPU, or hand work to a
well-owned asynchronous path. Measure or stress questionable paths rather than
trusting typical input.

Review target-conditional behavior (`target_os`, architecture, pointer width,
endianness, libc/platform APIs) even when only one target is locally runnable.
Pay special attention to `usize` conversions, binary/snapshot formats, paths, and
resource loading on 32-bit, ARM, macOS, Linux, Windows, and musl targets actually
claimed by the project. Unsupported combinations should fail clearly rather than
silently shipping a different security posture.

### Callback, process, timeout, and cancellation lifecycle

Test callbacks which:

- succeed with minimum and maximum valid results;
- raise, throw, `exit/1`, receive an exit signal, and brutal-kill themselves;
- return every malformed shape and oversized printable/opaque values;
- never return, return just before/after timeout, and reply twice;
- re-enter the same session, call a different session, or contend concurrently;
- die while constructing or sending a reply.

Test the caller/owner dying before send, while native work is pending, during the
callback, and after the native timeout but before a late reply. Verify:

- upward process links/monitors do not propagate an uncatchable callback exit to
  the API caller unless that is the explicit contract;
- downward teardown still kills or cancels callback children;
- a timeout does not merely abandon a dirty NIF that continues mutating state;
- no late callback side effect lands after the API reports timeout;
- pending-table entries, monitors, tasks, and timers return to baseline;
- unknown, late, and duplicate replies are harmless and bounded;
- the session remains usable after per-command failures if promised;
- all timeout values are validated against both public contract and BEAM/native
  runtime ceilings before starting handler processes.

Use synchronization barriers or observable state instead of fragile sleeps where
possible. Repeat race-focused tests enough to expose lifecycle mistakes while
keeping them deterministically bounded.

### Shared state, resources, and concurrency

- Verify request IDs cannot collide in live state; reason about counter wrap.
- Check every insertion has cleanup on all exits, including a dropped future.
- Check lock ordering, reentrancy, same-resource serialization, and cross-resource
  independence.
- Stress concurrent construction, use, timeout, drop, and garbage collection.
- Verify resource destruction cannot race a native call or callback using it.
- Verify one process cannot use stale or cross-session handles unexpectedly.
- Check clone/reference semantics and whether snapshots duplicate capabilities or
  mutable state unintentionally.
- Look for mailbox growth, orphaned workers, leaked native tasks, and global state
  that survives tests or code reload.

### Filesystems, paths, archives, and mounts

For every path accepted or returned:

- test empty, root, `.`, `..`, repeated separators, trailing separators,
  absolute/relative mismatch, embedded NUL, invalid UTF-8, long components,
  Unicode aliases, and platform-specific prefixes;
- distinguish lexical normalization from filesystem canonicalization;
- use component-aware containment checks, not string prefix checks;
- test symlinks both inside and escaping a root, including intermediate
  components and time-of-check/time-of-use windows;
- test read-only enforcement for every mutating operation;
- test mount-source and mount-target overlap, duplicate targets, nested mounts,
  target collisions with pre-existing/default directories, and disappearing
  sources;
- reject malformed directory entries: empty names, `.`, `..`, separators, NUL,
  invalid encoding, unknown type tags, and inconsistent stat/list results;
- bound cycles, no-progress recursion, infinite depth/breadth, huge listings, and
  recursive operations;
- verify byte-for-byte read/write/append behavior and partial-failure reporting.

Read the pinned upstream mount/filesystem implementation. If it warns and skips a
refused mount, filters invalid allowlist entries, or returns partial success, the
wrapper must not advertise successful construction. A post-build existence check
is insufficient when the target may already exist independently.

### Network and other host capabilities

Where network access exists, verify default denial and test:

- hostname, exact host, port, and scheme allowlist semantics;
- redirects at every hop;
- DNS resolving to private/link-local/loopback/multicast/unspecified addresses;
- IPv4, IPv6, IPv4-mapped IPv6, integer/hex/octal-looking hosts, IDNs, trailing
  dots, userinfo, percent encoding, and parser disagreement;
- DNS rebinding or resolution-use gaps where feasible;
- cloud metadata addresses and Unix/local transports;
- proxy environment variables and inherited credentials/cert settings;
- response/time/redirect/body limits and cancellation.

Use a controlled local server and resolver seams; do not probe real protected
systems. Apply the same default-deny review to subprocess execution, host
environment, dynamic library loading, databases, Git/SSH, and optional plugins.

### Serialization, snapshots, and persistence

- Test empty, truncated, corrupt, oversized, trailing-data, wrong-version, and
  cross-feature snapshots.
- Bound declared lengths, nesting, allocation, decompression ratio, and parsing
  time before allocating.
- Verify corruption is an error rather than a panic or partial restore.
- Verify restore is atomic: failure leaves no half-initialized live resource.
- Document integrity versus authenticity; do not imply signatures/encryption that
  do not exist.
- Ensure snapshots do not persist live callbacks, host mounts, descriptors,
  secrets, or capabilities unless explicitly designed to do so.

### Upstream semantic and feature review

Do not audit only wrapper code. Read the exact pinned source for every
security-sensitive upstream call. Compare:

- defaults and feature-gated behavior;
- error versus warning/skip/fallback behavior;
- validation order and canonicalization;
- limit enforcement and whether futures are dropped on timeout;
- unsafe code and documented invariants the wrapper can violate;
- changes between the previous and current pinned versions.

Search for duplicated security policy in the wrapper. Either remove unnecessary
duplication or document exactly why it exists, where the upstream source lives,
and what update procedure keeps it synchronized.

Inspect the actual Cargo feature graph. Ensure a wrapper `cfg(feature = "x")`
refers to a feature of the wrapper crate, not merely a dependency feature. Test
the shipped feature set and meaningful reduced/optional sets. Confirm dangerous
capabilities are runtime-gated even if compiled into prebuilt binaries.

### Dependencies, build, package, and release

- Run current RustSec and Hex advisory/retirement checks. Investigate warnings,
  not just nonzero exits.
- Inspect duplicate versions of security-critical crates and unexpected feature
  activation with `cargo tree`.
- Review pinned Git revisions, yanked crates, exact pins, MSRV, and lockfile drift.
- Confirm CI builds native code from source and does not accidentally test a stale
  downloaded NIF.
- Compare NIF ABI and target names across Rustler config, workflows, artifact
  filenames, checksums, and documentation.
- Verify checksums fail closed and correspond to all supported artifacts.
- Verify the package includes all native source/lock/checksum files needed by its
  documented installation modes and excludes secrets/build output.
- Check optional dependencies compile both absent and present where supported.
- Check release ordering cannot demand a checksum/artifact before it exists.
- Review CI action versions/permissions and release credentials at the workflow
  level without exposing secret values.

## Phase 6: adversarial test design

For each high-risk surface, maintain or create a compact matrix with columns:

```text
surface | valid boundary | malformed input | callback/upstream failure |
timeout/cancel | concurrency/reuse | expected containment | test evidence
```

Every confirmed bug should normally receive:

1. a focused regression reproducing the original failure;
2. adjacent boundary cases;
3. an assertion that the caller/VM survives;
4. an assertion that the operation is bounded by an external test timeout;
5. an assertion that no late side effect or leaked state remains;
6. a follow-up success using the same session/resource when reuse is promised.

Use subprocess tests for payloads that may abort, segfault, SIGBUS, deadlock, or
otherwise take down the VM. The parent test should assert bounded child behavior
and retain useful stderr/status evidence. Do not normalize an actual VM crash as
an acceptable application error.

Property tests or fuzzing are especially valuable for term decoders, path/listing
validation, snapshot parsers, and encode/decode round trips. If adding a durable
fuzz harness is disproportionate, still perform a bounded generated-input probe
and report what was and was not covered. Never claim exhaustive fuzzing from a
small sample.

For concurrency tests, prefer deterministic barriers, monitors, and counters.
Stress only after proving the state transition with a deterministic test. Check
process counts, table sizes, or test-visible counters before and after repeated
timeouts when practical.

## Phase 7: implementation rules for findings

For each finding:

1. Minimize and confirm the reproducer.
2. Determine severity and affected contracts.
3. Search the whole repository for the same primitive or assumption.
4. Fix at the earliest boundary that has enough information.
5. Retain a native defense when malformed terms/data could threaten VM safety.
6. Make failure explicit; never report success with substituted or skipped data.
7. Add regression and family tests.
8. Review docs/typespecs/changelog/update procedure for the changed invariant.
9. Re-run focused tests immediately, then the full gate.
10. Inspect the final diff for unintended API or generated-file changes.

Suggested severity model:

- **Critical:** VM memory corruption/crash reachable by ordinary input; sandbox
  escape; arbitrary host file/network/process capability; native code execution.
- **High:** reliable VM abort/DoS, default-deny bypass, cross-session isolation
  failure, uncontained process-tree death, deadlock, or secret exposure.
- **Medium:** silent data corruption, timeout/cancellation side effects, resource
  leak, misleading success, panic contained to a call, or important contract
  mismatch.
- **Low:** narrow validation inconsistency, misleading diagnostics/docs, or
  defense-in-depth weakness without a demonstrated harmful outcome.

Severity does not decide whether to fix a safe in-scope correctness bug. It sets
review and reporting priority.

## Phase 8: validation gates

Discover project-specific commands first. A typical Rustler project should run
the equivalent of all applicable gates below against a source-built NIF:

```sh
# Elixir/BEAM
NIF_BUILD_FROM_SOURCE=1 mix compile --warnings-as-errors
NIF_BUILD_FROM_SOURCE=1 mix test
mix format --check-formatted
NIF_BUILD_FROM_SOURCE=1 mix docs
mix deps.unlock --check-unused
mix hex.audit

# Rust (run in or point at every native crate)
cargo fmt --check
cargo clippy --all-targets -- -D warnings
cargo test
cargo audit

# Repository hygiene
git diff --check
git status --short
```

`NIF_BUILD_FROM_SOURCE=1` is a placeholder, not a universal variable. Replace it
with this repository's real build mode. Run Clippy/tests with the actually shipped
features; additionally run `--all-features` or reduced feature combinations only
when they are supported and meaningful. If a gate is unavailable or inapplicable,
record that explicitly with the reason and the compensating review/test.

Also consider, based on risk and toolchain support:

- repeated focused race tests;
- tests under every supported OTP/Elixir/Rust version via CI or local containers;
- `cargo deny`, targeted sanitizers, Miri for pure-Rust components, Loom for
  synchronization, and `cargo fuzz`/property tests for parsers;
- package dry-runs and compiling from the packaged artifact;
- source-built versus precompiled smoke-test parity.

Do not install heavyweight tools or mutate global environments without need.
Temporary isolated tooling is acceptable; record versions and remove temporary
artifacts from the worktree.

## Phase 9: completion criteria

Do not declare the audit complete until:

- every public API and native export is accounted for in the architecture map;
- the motivating incident has been generalized into sibling searches/tests;
- all applicable boundary classes above have been reviewed;
- high-risk async paths have explicit upward-fault and downward-cancellation
  evidence;
- security-sensitive upstream semantics have been checked against pinned source;
- all confirmed in-scope defects are fixed or clearly reported as blocked with a
  concrete reason;
- each practical fix has regression coverage;
- source-built full tests, formatting, compilation warnings, Clippy, dependency
  audits, and repository hygiene gates are clean;
- docs and release/update procedures match the implemented invariants;
- the final diff has been manually reviewed;
- residual risks, skipped gates, and untested platform/feature combinations are
  explicit.

The final handoff must lead with outcomes and include:

1. findings by severity, root cause, impact, fix, and regression-test location;
2. sibling classes examined even when no further bug was found;
3. exact validation commands and results, including test counts;
4. dependency advisory results and any lockfile changes;
5. residual risks/skipped checks with reasons;
6. the final changed-file list and whether changes are committed;
7. confirmation that nothing was published, pushed, tagged, or released.

A “no additional findings” result is acceptable only with the same architecture
map, adversarial evidence, upstream review, and validation record. Green existing
tests alone are not evidence of a comprehensive audit.

## Failure archetypes this protocol must catch

These are real classes seen in Rust NIF wrappers. They are prompts for sibling
searches, not an exhaustive list:

- A malformed directory entry makes a recursive native walker make no path
  progress until it crashes the host VM.
- A user callback brutal-kills a linked task, propagating through handler links
  and killing the API caller despite a “command-local error” contract.
- A timeout value fits an unsigned native integer but exceeds the BEAM receive
  ceiling, so construction succeeds and a handler crashes only when that rare
  path runs.
- An upstream builder warns and skips a refused mount; a wrapper checks only that
  the target path exists, which was already true in a default filesystem, and
  falsely reports successful secure construction.
- Native binary allocation fails and bridge code silently substitutes an empty
  binary while reporting that the original write/send succeeded.
- An unknown enum/type tag falls through to a permissive default.
- A native timeout drops a future without removing its pending callback entry.
- A dirty NIF times out at the BEAM level but keeps running and commits a late
  side effect.
- Local tests exercise a stale precompiled NIF instead of newly edited Rust code.
- A wrapper compiles a dangerous dependency feature but its own `cfg` gate is
  never enabled because dependency features and crate features were confused.

For each archetype, ask: **Where else does this repository make the same kind of
assumption?**

## Current repository profile: ExBashkit

This section seeds the first run in this repository. **When this file is copied,
the auditor must replace this profile after discovery if the repository is not
ExBashkit. Never apply these facts blindly to another project.**

- BEAM API and callback orchestration: `lib/ex_bashkit/session.ex`
- Native stubs/loader: `lib/ex_bashkit/native.ex`
- Rust crate: `native/ex_bashkit`
- Force source build: `EXBASHKIT_BUILD=1`
- Primary local test command: `EXBASHKIT_BUILD=1 mix test`
- Important upstream: exact `bashkit` pin and selected features in
  `native/ex_bashkit/Cargo.toml`
- High-risk surfaces: persistent session resource; dirty async execution;
  builtins and Python callbacks; Elixir-backed virtual filesystem callbacks;
  host mounts and path allowlists; network allowlisting/SSRF policy; limits and
  timeouts; snapshot/restore; shared Tokio runtime and pending-request tables;
  precompiled NIF checksum/release flow.
- Prior crash report: `BUGREPORT-empty-dirname-recursion-sigbus.md`
- Porting and invariant notes: `PORTING.md`, `HANDOFF.md`, and
  `UPDATE_PROCEDURE.md`

Minimum ExBashkit final gate:

```sh
EXBASHKIT_BUILD=1 mix test
EXBASHKIT_BUILD=1 mix compile --warnings-as-errors
mix format --check-formatted
EXBASHKIT_BUILD=1 mix docs
mix deps.unlock --check-unused
mix hex.audit
cargo fmt --check --manifest-path native/ex_bashkit/Cargo.toml
cargo clippy --manifest-path native/ex_bashkit/Cargo.toml --all-targets -- -D warnings
cargo test --manifest-path native/ex_bashkit/Cargo.toml
(cd native/ex_bashkit && cargo audit)
git diff --check
git status --short
```

The profile is a starting point, not a scope limit. Refresh it from current code,
features, history, and workflows before auditing.
