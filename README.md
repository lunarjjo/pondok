# Pondok 🛖

**Bedrock Mobile Server Manager** — turn a compatible Android phone into a
managed Minecraft Bedrock Dedicated Server (BDS) host.

> Production-oriented engineering project. Every claim in this repository is
> either **verified with evidence** (PoC logs, CI runs against the real
> server binary) or **explicitly marked unverified** with the reason.
> Nothing is simulated; nothing is faked.

[![CI](https://github.com/lunarjjo/pondok/actions/workflows/ci.yml/badge.svg)](../../actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

## What it will do (when finished)

- Install and manage the **official** Mojang BDS distribution on the device
  (downloaded at setup — never bundled).
- Run the x86_64 BDS binary on ARM64 Android through the proven
  **Box64/proot** translation stack, no root required.
- Full management panel: live console, allowlist/bans/ops, typed
  server.properties editor, world backups & restore, packs, multi-instance.
- **Safe update pipeline**: backup → download → CRC-verify → staging
  smoke-run → activate → health-check, with rollback — journaled so an
  interrupted update can never half-activate.
- Public internet play through a UDP tunnel (playit.gg agent) without router
  port forwarding — administration stays local-only by design.
- Follows the device dark/light theme (Material 3 DayNight).

## Current state — milestone M2 (bundled zero-setup runtime)

| Area | Status |
|---|---|
| Phase 0 research + PoC against the real BDS binary | ✅ done — [docs/PHASE0_REPORT.md](docs/PHASE0_REPORT.md) |
| `pondok_core` pure-Dart management engine | ✅ 119 unit tests green |
| Real-binary integration suite (start/console/allowlist/stop/persist/port/crash/watchdog) | ✅ 6/6 green in CI |
| **Fully-bundled zero-setup runtime (ADR-004)** — proot + box64 + official BDS *inside the APK* | ✅ pack builder + installer + first-launch flow |
| **Full translated stack verified on REAL arm64 hardware in CI** (boot → RakNet pong → console → exit 0 → world persistence) | ✅ `runtime-pack` workflow gates every APK |
| On-device smoke test on a physical phone | ⏳ open DoD item (needs hardware) |
| Tunnel provider end-to-end (M5) | ⏳ planned — [docs/ROADMAP.md](docs/ROADMAP.md) |

The integration suite in CI **actually downloads and runs the official
Bedrock server** on every push — the same evidence discipline as the Phase 0
PoC, automated. See a sample of what that proves in
[docs/evidence/](docs/evidence/) and the bugs it already caught in
[docs/DEBUG_LOG.md](docs/DEBUG_LOG.md) (including a supervisor bug where
every "graceful stop" silently degraded to SIGTERM).

## Documentation

- [Architecture](docs/ARCHITECTURE.md) — system design, runtime profiles,
  update pipeline state machine, security model.
- [Phase 0 Report](docs/PHASE0_REPORT.md) — feasibility research with
  verified/unverified separation and PoC evidence.
- [Risk Register](docs/RISK_REGISTER.md) — 16 risks with mitigations and
  honest non-goals.
- [Dependencies](docs/DEPENDENCIES.md) — full inventory, pinned, licensed.
- [Roadmap](docs/ROADMAP.md) — milestones with acceptance criteria.
- [Debug Log](docs/DEBUG_LOG.md) — the real bugs, the evidence, the fixes.

## Repository layout

```
packages/pondok_core/   pure-Dart engine (zero dependencies)
  lib/src/              supervisor · parsers · pipeline · backup · tunnel
  test/                 103 unit tests
  test/integration/     6 real-binary tests (run in CI with cached BDS)
app/                    Flutter application (Android)
  lib/                  Material 3 DayNight shell (grows each milestone)
  android/              Gradle config (targetSdk 28 — see architecture §2)
docs/                   engineering record
.github/workflows/      CI: analyze · test · real-BDS integration · APK
```

## Development

```bash
# core (pure Dart)
cd packages/pondok_core && dart pub get && dart test

# real-binary integration (needs an extracted BDS distribution)
PODOK_BDS_DIR=/path/to/extracted/bds dart test test/integration/

# app
cd app && flutter pub get && flutter analyze && flutter test
```

CI handles the rest, including downloading the official BDS zip (cached by
version + SHA-256) for integration runs and building the release APK.

## Honest limitations (read before relying on this)

- No first-party checksums exist for BDS zips; integrity is TLS + per-member
  ZIP CRC validation + staging smoke-run (documented substitution).
- ARM64 translation performance varies per device; verified-devices table
  comes only from real reports. No "works everywhere" claim.
- Android can kill any app; uninterrupted 24/7 hosting is never promised.
- The game port is public by design; **all administration remains local**.

## License

MIT for this repository's own code. Third-party components (downloaded or
bundled) are inventoried in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
Mojang's Bedrock Dedicated Server is proprietary and is never redistributed
by this repository — the app downloads it from the official source at setup
time, with the EULA surfaced during onboarding.
