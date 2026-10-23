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

---

## Session 2 (2026-10-23) — M2 bundled-runtime pivot

### D-08 · `make LDFLAGS=-static` silently strips the Makefile's own link flags
**Where:** `tools/build_runtime_pack.sh` · **Severity:** CI-blocking (2 cycles).
proot's static link failed with `undefined reference to talloc_*` — but
`-ltalloc` was never missing: a make **command-line** variable overrides
EVERY assignment in the makefile, including `LDFLAGS += $(pkg-config --libs
talloc)`. proot's own CI passes LDFLAGS via the ENVIRONMENT
(`LDFLAGS="…" make …`) for exactly this reason. One-character-class fix:
`LDFLAGS=-static make …` instead of `make … LDFLAGS=-static`.

### D-09 · proot embeds Python when python3-config is visible
**Where:** same · **Severity:** CI-blocking (cycle 1).
`undefined reference to PyExc_TypeError` — ubuntu-24.04-arm runners ship
python3-dev, which flips proot's GNUmakefile into building its Python
extension, and glibc-static-libpython does not resolve its own symbols
under -static (documented in a comment in proot's own GNUmakefile).
Fix: `WITHOUT_PYTHON=1` — upstream's own switch for "don't want it".

### D-10 · Phase-0 assumption "all BDS deps are Box64-wrapped" was WRONG
**Where:** whole runtime design · **Severity:** would have shipped dead.
On real arm64 hardware box64 exits 255 with `Error: Loading needed libs in
elf ./bedrock_server` — bedrock_server needs REAL x86-64 libstdc++/libgcc
that box64 does not wrap. Fix: box64's official
`box64-bundle-x86-libs` (34 MB, sha-pinned) inside the rootfs +
`LD_LIBRARY_PATH=.:/usr/lib/box64-x86_64-linux-gnu`. Lesson: a dependency
list read off `ldd` on x86-64 is NOT evidence about what the translator
needs at load time — only a real boot is.

### D-11 · Dart has no `0o` octal literals
**Where:** `tar.dart` + tests · **Severity:** compile-blocking.
`0o644` parses as `0` followed by identifier `o644` → cascading weird
errors. All modes are hex now (`0x1A4` = 0644, `0x1ED` = 0755).

### D-12 · `BundledRuntimePaths.box64` pointed at `$runtime/opt/...` not `$rootfs/opt/...`
**Where:** `bundled_runtime.dart` · **Severity:** caught by unit test.
The installer laid the tree down correctly; only the PATH CONSTANT was
wrong — verify() reported "box64 missing" while the file sat one level
deeper. Path constants deserve their own test the moment they are written.

### D-13 · installedManifest() parsed the marker WRAPPER, not the inner manifest
**Where:** same file · **Severity:** silent "not installed" → needless
reinstalls. The marker is `{"installedAt":…, "manifest":{…}}`; parse()
expected the manifest at top level. Found by scratch-debugging (printed
marker, tried parse, read the FormatException).

### D-14 · tar entries named `./usr/bin/...` leaked "./" into paths
**Where:** `tar.dart` · **Severity:** assertion mismatches vs system tar.
`tar -C dir .` prefixes every entry with `./` — execPaths and comparisons
must normalize. Also: `Uint8List.indexOf` searches for a single int
ELEMENT (no sub-array search exists) — the tamper test needed its own
`_indexOfSub`.

### D-15 · fake-async hang, rediscovered + a second layer
**Where:** `app/test/widget_test.dart` · **Severity:** test hang (~87 s).
Layer 1 (known from M1): awaiting real IO (sha256OfFile!) in the
testWidgets body never completes — fixture prep must run inside
`tester.runAsync`. Layer 2 (new): an indeterminate spinner's animation
ticker outliving the test → "(did not complete)" — dispose the tree with
`pumpWidget(const SizedBox())` at the end. Also: `find.textContaining` is
case-sensitive ("Sekali saja" vs "sekali saja").

### D-16 · asset name prefix confusion
**Where:** `pack_source.dart` · **Severity:** fallback path broken in tests.
The Android AssetManager needs `flutter_assets/<name>`; rootBundle needs
the plain pubspec name. Mapping belonged in ONE place (PackSource), not
at call sites — the controller was passing the prefixed form and the
test fallback could never load it.

---

## Session 2 (2026-10-24) — first on-device bug report (owner's phone)

### D-17 · "Kehilangan proses (crash)" with zero output — three stacked observability bugs
**Where:** `bds_process.dart`, `server_controller.dart`, `home_screen.dart`
· **Severity: the shipped APK was undebuggable on device.**

**Report (owner, verbatim):** start button always ends in "Kehilangan
Proses (crash)", "tidak ada log error atau apapun yang tampil".

**Chain reconstruction** (targetSdk 28 + the `crashed` state proves the
child WAS spawned and died instantly — a spawn refusal would have shown
"Gagal menyala"):

1. **Exit race.** `_onExit` ran straight off `exitCode` and closed the
   line stream immediately; the dying process's stderr bytes were still
   in the pipe (Dart delivers pipe data asynchronously — the kernel can
   reap the child BEFORE the pipe bytes reach the event loop). The one
   message that explained the death was dropped. Reproduced on Linux
   with `sh -c 'echo boom >&2; exit 7'` — pre-fix, `boom` vanished.
2. **Swallowed exception.** The Start button called `server.start()`
   un-awaited; the `BdsStartupException` carrying the reason became an
   unhandled async error (invisible in release builds).
3. **Nothing rendered.** `BdsExit.detail` was `'pid N'` — the exit code,
   signal, and output tail were never surfaced anywhere.

**Fixes** (ADR-005): drain-before-finalize with per-pipe EOF completers
(bounded 5 s), signal-decoded exit details, `BdsStartupException` as the
uniform start() contract (the old `rethrow` leaked the raw
ProcessException — callers keyed on the wrapper missed it; found by the
new unit test), failure box + probe ladder + persistent log + one-tap
bug report in the UI, DIRECT fallback profile, `direct-ld` CI gating.

**Honest status:** the ON-DEVICE root cause (why proot died on that
phone) remains UNKNOWN — the sandbox has no Android hardware. The new
build either runs (DIRECT fallback), or prints exactly which layer died
with what evidence (#19 remains open until the owner runs it).

### D-18 · `android.os.SELinux` is not in the public SDK
**Where:** `MainActivity.kt` · **Severity:** CI-only compile failure
(`Unresolved reference 'SELinux'` — local `flutter analyze` cannot see
Kotlin, so nothing caught it before the runner). Despite being documented
in some places, `android.os.SELinux` is a hidden/SystemApi surface. Same
treatment as `Os.sysconf`: reflection inside try/catch — diagnostics must
compile on every SDK level and degrade to `"unknown"`, never break the
build. Lesson re-confirmed: Kotlin changes are only proven by the CI
build, so keep platform-facing Kotlin minimal and reflective.
