# Architecture Decision Records — Pondok

Short, dated records of the decisions that shaped the architecture. Each
one states context → decision → consequences. Superseded records stay in
place (struck through) so the reasoning trail survives.

---

## ADR-005 · 2026-10-24 · Diagnostic-first failures + DIRECT launch fallback

**Status: ACCEPTED.** The first on-device start attempt (owner's phone,
2026-10-24) died with the UI showing only "Kehilangan proses (crash)" and
zero output — three stacked observability bugs (D-17: exit-race swallowed
stderr; the start button dropped the only exception carrying the reason;
exit detail was never rendered) meant even WE could not tell which layer
died, let alone the user. Without hardware in the sandbox, blind fixes are
guesses; so failures must be self-explaining AT the point they happen.

Decision, in four parts:

1. **Drain-before-finalize** in `BdsProcess`: exit is classified only
   after stdout AND stderr reach EOF (bounded) — the dying message can no
   longer lose the race; exit codes decode signals (SIGILL vs SIGSYS vs
   plain exit) into Indonesian hints.
2. **Probe ladder on device** (`StackDiagnostics`): sh → exec-proot →
   proot-rootfs → proot-box64 → direct-box64, each bounded, each
   interpreting its own failure; results render in the UI and append to a
   persistent rotating `logs/pondok.log`.
3. **DIRECT fallback profile** (`directRuntimeProfile`): launch box64 via
   the ROOTFS'S OWN ld.so with `--library-path` — no ptrace, no proot, no
   host glibc. A device whose kernel/OEM breaks proot still gets a
   server; the mode is tried automatically and persisted
   (`launch_mode.json`). CI's stack verification gates a third mode,
   `direct-ld`, mirroring this command line on real arm64 hardware.
4. **One-tap bug report**: failure box → clipboard report with device
   facts, exit, output tail, ladder, log tail.

Consequences: slightly longer failure path (up to ~5 s drain bound), one
more CI mode (~8 min), and the honest admission that the on-device root
cause is still UNVERIFIED until the owner runs the new build (#19 stays
open). The ladder converts that unknown into evidence on the next run.

---

## ADR-004 · 2026-10-23 · Fully-bundled zero-setup runtime

**Status: ACCEPTED (supersedes the download-at-setup part of ADR-003).**

**Context.** Owner directive, verbatim: the previous design "masih ribet
karena perlu setup setup hal lain, seperti runtime dan lain lain — buat
agar aplikasi siap pakai, semua sudah ada saat aplikasi di install, saya
tidak peduli ukuran aplikasi akan sangat besar, user tinggal pakai."

**Decision.** Ship EVERYTHING inside the APK as a single Flutter asset
(`assets/runtime_pack.zip`):

| Member | Content | Size class |
|---|---|---|
| `manifest.json` | recipe + sha256 of every member | KB |
| `proot` | proot v5.5.0, statically linked (aarch64) | ~2 MB |
| `rootfs.tar` | ubuntu-base 24.04.5 arm64 + box64 v0.4.4 (dynarec) @ `/opt/box64/box64` + box64's official x86-64 lib bundle @ `/usr/lib/box64-x86_64-linux-gnu` | ~70 MB tar |
| `bds.zip` | the UNMODIFIED official Bedrock server distribution | ~95 MB |

First launch: copy asset → file (streamed via Kotlin channel, 64 KiB
buffer — never in heap) → verify member sha256s → extract (staging) →
activate. After that the server runs forever from local storage; a
damaged tree self-heals by re-extracting from the APK (worlds/ and
server settings preserved). **No download, no setup step, no Termux.**

**Consequences.**
* APK ~170–200 MB. Accepted by the owner explicitly ("ukuran tidak
  peduli"). Distribution stays GitHub-releases/sideload (not Play).
* **Legal posture** (R-17): the proprietary BDS zip is fetched at BUILD
  time by CI from minecraft.net, pinned by sha256+size, and never
  committed to git; it exists only inside build artifacts. The app shows
  the Mojang EULA gate before the first server start.
* Runtime updates become app updates (Phase 4 pipeline still applies to
  in-place BDS upgrades).
* The pack is **built and verified on real arm64 hardware in CI**
  (`runtime-pack` workflow on `ubuntu-24.04-arm`): proot → box64 →
  bedrock_server must boot, answer a RakNet protocol ping, run a console
  round-trip, stop with exit 0, and persist a world across restart —
  before any APK is allowed to embed the pack.

---

## ADR-003 · 2026-10-23 · Official BDS binary, downloaded — **SUPERSEDED by ADR-004** (distribution channel only)

**Status: superseded.** ~~Download the official BDS zip from minecraft.net
at setup time~~ → now fetched by CI at build time into the pack. The
parts that survive unchanged: only minecraft.net over TLS, browser UA,
sha256+size pinned, CRC-validated members, no mirrors, no modifications,
EULA gate before first start.

## ADR-002 · 2026-10-23 · proot + box64 execution stack

**Status: ACCEPTED.** Official BDS ships Linux x86-64 binaries only; arm64
phones need userspace translation: static `proot` hosts a glibc rootfs,
`box64` (ARM_DYNAREC) translates the server. Community-proven stack
(BedrockServerTermux, Box64Droid), now also proven on our CI's arm64
hardware. `BdsProcessConfig` keeps argv abstract so the profile stays
swappable (Termux-integration remains the documented escape hatch, R-01).

## ADR-001 · 2026-10-23 · targetSdk 28 (sideload-only)

**Status: ACCEPTED.** Executing binaries extracted into app-private
storage requires the legacy SELinux domain; targetSdk 28 is the Termux
pattern. Trade-off: Play-store distribution impossible — this app is
sideload-only by design. Monitor Android minimum-installable-SDK drift
(R-01).
