# Roadmap — Pondok

Milestones with **verifiable acceptance criteria**. A milestone is done only when its
criteria pass in CI or are verified on-device with evidence linked in the issue.
"No bug" is approached by: every feature ships with tests; every failure mode ships with
an observable state; nothing is claimed working that CI or a device has not proven.

---

## M0 — Phase 0 complete ✅ (2026-10-23)

- [x] Official BDS distribution inspected; URL patterns, UA quirk, version sources verified
- [x] Real BDS 1.26.52.3 process driven start→console→stop→restart on x86_64 with evidence
- [x] Android ARM64 execution stack researched (Termux/proot/Box64; community-verified,
      marked UNVERIFIED-by-us for on-device)
- [x] Tunnel provider evaluated (playit.gg aarch64 agent, free UDP, Bedrock support)
- [x] Architecture, risk register, dependency inventory, this roadmap written
- **Evidence:** `docs/PHASE0_REPORT.md` + `docs/evidence/`

## M1 — Runtime core on CI (Phase 1) ← current

The process-management layer, proven against the real BDS binary on every push.

- [ ] `pondok_core` package: `ConsoleParser` (real log format), `ServerProperties`
      (typed registry from the real 1.26.52.3 file), `Allowlist`, `BdsProcess` supervisor
      (start / command / graceful stop ladder / crash classification / startup watchdog)
- [ ] CI job "bds-integration" (x86_64): downloads official zip (cached), then a test
      suite that **actually starts the server**, runs `list`, edits properties, verifies
      port change + world persistence + clean stop exit code 0 + crash detection via
      abnormal exit code
- [ ] `UpdatePipeline` state machine + `BackupManager` with unit tests (mock FS) and
      real-BDS staging smoke-run in CI
- [ ] `VersionManifest`: wiki API parse + official URL probe, tested live in CI (marked
      `@network` — skips gracefully offline)
- [ ] Flutter app skeleton compiles; CI builds APK artifact
- **Acceptance:** green CI run containing a real BDS log excerpt as test output; APK
  artifact attached; zero analyzer issues.

## M2 — Fully-bundled zero-setup runtime (Phase 1, ADR-004) ← current

Owner pivot (2026-10-23): no setup steps, no downloads — everything ships
inside the APK ("user tinggal pakai").

- [x] Runtime pack builder (CI, arm64 runner): proot static + ubuntu-base
      rootfs + box64 dynarec + official BDS — pinned, hashed, manifest'd.
- [x] Full-stack verification on REAL arm64 hardware: boot, RakNet ping →
      pong, console round-trip, stop exit 0, world persistence across
      restart (workflow `runtime-pack`, gating for every APK).
- [x] pondok_core: streaming tar reader + BundledRuntime installer
      (staging → sha-gate → activate; self-heal preserves worlds/ +
      server.properties/allowlist) — 119 unit tests green.
- [x] App: zero-setup first-launch flow (runtime card + EULA gate +
      Start/Stop + live console), streaming asset copy via Kotlin channel.
- [ ] CI green end-to-end with the pack embedded in the APK (in progress).
- [ ] On-device smoke test on a real phone (needs hardware — offer to
      owner; also the playit tunnel E2E DoD item).

## M3 — Management features (Phases 2+3)

- [ ] Screens: dashboard (status/uptime/RAM/connection), live console with filtering +
      command input, file manager (path-guarded), player management (allowlist, ban via
      console `ban`/`pardon`), properties editor with validation, version manager
- [ ] Every console command round-trip tested (send → observe response line) in CI
- [ ] Loading/error/empty/recovery states for every screen; Material 3 DayNight theme
      following device preference
- **Acceptance:** widget tests green; CI integration suite covers each management
  feature against real BDS; APK usable on a 6" phone screen.

## M4 — Safe updates (Phase 4)

- [ ] Full pipeline: check→approve→backup→download→CRC-verify→stage→smoke-run→preserve→
      activate→health-check→record; rollback on failure; journaled resume after interrupt
- [ ] Never-delete-last-good-version + never-delete-last-backup guards (unit tested)
- [ ] Update history UI; unattended policy setting (default off)
- **Acceptance:** CI test performs a controlled downgrade+upgrade cycle on a real world
  directory and verifies the world survives; simulated failure mid-pipeline rolls back.

## M5 — Public connectivity (Phase 5)

- [ ] `TunnelProvider` + `PlayitProvider` (agent download/pin, claim-code capture UI,
      secret persistence + redaction, bounded backoff reconnect, public address display)
- [ ] Connectivity self-test (RakNet ping through the tunnel from the app's perspective;
      full external join remains an on-device DoD item)
- [ ] Free-tier limits + "admin stays local" guarantees documented in-app
- **Acceptance (CI):** mocked-agent tests pass — claim URL parse, backoff schedule,
  disconnect→reconnect transitions, secret never appears in captured logs.

## M6 — Reliability & security hardening (Phases 6+7)

- [ ] Reboot receiver with opt-in auto-restart; duplicate-process + port-conflict guards
- [ ] Battery optimization guide per OEM; storage monitor; crash reports + log rotation
- [ ] Security audit pass: path traversal corpus tests, command sanitizer, redactor,
      import quarantine (zip bomb guards)
- **Acceptance:** adversarial unit corpus green; manual kill/reboot test script on device.

## M7 — First usable release (Definition of Done)

The 12-point checklist from the project brief, each closed with evidence:
runtime install on verified device · real BDS start/stop · LAN join from second device ·
tunnel join from other network · console command round-trip · allowlist + ban ·
property change visible in game · backup+restore · controlled update without world loss ·
crash recovery · green CI + APK · documented unverified items & limitations.
Release: tagged `v0.1.0`, changelog, install/troubleshooting/backup/restore guides.

---

## Continuous cross-cutting (every milestone)

GitHub Issues per milestone (labels: `phase-N`, `core`, `app`, `ci`, `docs`, `device`),
meaningful commits on feature branches, `flutter analyze` + format + tests on every PR,
dependency review on every bump, no secrets/world data/binaries ever committed.
