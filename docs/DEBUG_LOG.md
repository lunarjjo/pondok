# Debug Log — development record

Durable record of real bugs found and fixed, in order of discovery. Every
entry states the evidence that exposed it. This file exists because the
project brief demands honest engineering records — and because two of these
bugs would have shipped silently without the real-binary integration suite.

---

## Session 1 (2026-10-23) — Phase 0 + core (M1)

### D-01 · SHA-256 test vectors written from memory were wrong
**Where:** `test/zip_test.dart` · **Severity:** test-only, but instructive.
Two FIPS vectors (56×'a', 64×'a') were written from recall and were wrong.
Caught by cross-checking against Python `hashlib` before ever running the
Dart suite — the lesson: never trust remembered constants; verify against an
independent implementation.

### D-02 · Dart 3.13.5 API drift (5 separate breaks)
**Where:** `lib/src/*` · **Severity:** compile-blocking.
The 2026-era Dart SDK removed/changed APIs that older muscle memory used:
`Process.kill(pid, sig)` → `Process.killPid(pid, sig)`;
`FileSystemEntity.resolveSymbolicLinks(path)` static → instance method;
`HttpClient.followRedirects` client-level setter → per-request on
`HttpClientRequest`; `RandomAccessFile.read(len, offset)` → position+read;
raw-string regexes containing `'` need non-raw strings.
All fixed; probes via `dart analyze` scratch files.

### D-03 · ZipWriter.addTree interpolated a null prefix
**Where:** `lib/src/zip.dart` · **Severity:** production bug.
`addFile('$prefix${rel}', …)` with `prefix == null` produced entries named
`nullserver.properties`. Exposed by the addTree round-trip test ("Set:
['nullserver.properties', …]"). Fixed with explicit `prefix ?? ''`.
**Catch value:** every backup created through the tree path would have been
silently mis-named and unrestorable.

### D-04 · ConsoleParser folding starved the live stream
**Where:** `lib/src/console_line.dart` + `bds_process.dart` · **Severity:** design flaw.
The first parser folded raw continuation lines into the previous entry and
returned `null` — but stream listeners had already received the original
entry, so folded updates never reached the console UI, and multi-line
artifacts like the `CREATING VANILLA WORLD` banner simply vanished from the
output. Exposed by integration test 5 expecting the banner. Redesigned: every
line emits immediately; folding removed.

### D-05 · `stop()` never sent the stop command — every stop degraded to SIGTERM
**Where:** `lib/src/bds_process.dart` · **Severity:** **critical** — data-loss adjacent.
`stop()` first transitioned the state to `stopping`, then called
`sendCommand('stop')`; but `sendCommand` required `isAlive`
(`starting|running`), so it threw `StateError` — which `stop()` swallowed in
its own `catch (_) {}`. Net effect: the graceful command was never written,
the 45 s window always expired, and every shutdown escalated to SIGTERM
(witness: exit code −15 instead of 0 in integration test 1; PoC scripts and
raw-pipe experiments proved the server itself stops in ~50 ms).
Fixed by allowing commands in the `stopping` state, with a comment
documenting the failure mode at the site.
**Catch value:** this is exactly the class of bug that only a real-binary
integration suite can expose — mocks happily "stop" when told.

### D-06 · Watchdog state race across the async exit gap
**Where:** `lib/src/bds_process.dart` · **Severity:** flaky-failure class.
Two related races: (a) `start()` rethrew the watchdog error before `_onExit`
had run, so the observed state was still `starting` instead of
`startupFailed`; (b) `_onExit` could resume after `dispose()` closed the
state controller (`Bad state: Cannot add new events after calling close`).
Fixed by setting `startupFailed` inside the watchdog callback before
completing the error, and guarding `_setState`/`dispose` for closed
controllers.

### D-07 · Escaping artifacts while patching tests
**Where:** `test/*` · **Severity:** tooling hygiene.
Python-driven edits wrote `\$` into Dart string interpolations (literal
dollar) and a `..`-cascade on a `void`-returning `createSync()`. Caught by
compile/test; kept here as a note to prefer the Edit tool for code changes.

---

**Resulting state:** 103 unit tests green · 6/6 real-BDS integration tests
green (start, console round-trip, allowlist sync, graceful stop exit 0,
world persistence, port change, crash classification, watchdog).
