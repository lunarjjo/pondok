# Risk Register — Pondok

Legend: **L**ikelihood / **I**mpact (H/M/L). Every risk carries a mitigation and — where
honest — an explicit "acceptance" of what we will NOT claim.

| ID | Risk | L | I | Mitigation / honest acceptance |
|---|---|---|---|---|
| R-01 | **targetSdk 28 required for exec of downloaded binaries** (SELinux legacy domain). Future Android versions could raise the installable minimum above 28, breaking distribution. | L | H | Monitor Android release notes each cycle; keep an alternative **Termux-integration profile** documented (app drives Termux via RUN_COMMAND intents, which targets modern SDK) — not planned for v0.x, but the architecture leaves `RuntimeProfile` swappable exactly for this. Accept: sideload-only app, install warning shown to user. |
| R-02 | **Box64 translation fails or is unusably slow on a given device/SoC.** Verified on CI arm64 hardware (boot + protocol + stop exit 0); per-DEVICE behavior still varies. | M | H | Lean profile auto-falls back to proot profile; onboarding runs a real smoke-start before declaring the device compatible; diagnostics screen exposes box64 version + measured startup time. Accept: we publish a **verified-devices** table from real reports only — no blanket "works on all phones" claim. |
| R-03 | **OEM battery management kills the foreground service/processes** (Samsung/Xiaomi/etc. aggressive killers). | H | M | FGS + wake lock + persistent notification; first-class battery-setup guide per OEM; detect abnormal termination on next launch and tell the user exactly what happened. **Never promise 24/7 operation.** |
| R-04 | **Mojang changes distribution URLs / adds bot protection** (we already observed the 308/UA quirk). | M | M | URL patterns are config constants, not hardcoded logic; downloader handles redirects + browser UA; version discovery has two independent sources (wiki API + HEAD probe) and the runtime degrades to "manual zip import" mode if both fail. |
| R-05 | **BDS protocol/transport drift** (e.g., NetherNet-only future, RakNet deprecation). | L | H | Phase 0 verified 1.26.x still binds classic UDP; tunnel provider abstraction anticipates provider-side changes (playit premium already covers NetherNet if ever needed). Track each BDS release via CI version check workflow. |
| R-06 | **playit.gg free-tier changes / agent abandonment** (agent is third-party closed service; binary is theirs). | M | M | `TunnelProvider` interface keeps providers swappable; documented free-tier limits; agent pinned + hash-logged at download; LAN-only mode always available (NullProvider). |
| R-07 | **RAM exhaustion on mid-range devices** (BDS ~1–2 GB + translation overhead + Android itself). | M | H | Onboarding checks total RAM and warns below 4 GB (community table: 2 GB = 1–2 players); dashboard shows live RSS; `max-threads`/`view-distance` guidance surfaced in the performance screen. |
| R-08 | **No first-party checksums for BDS zips** → a corrupted/malicious mirror is indistinguishable by hash alone. | L | H | We download **only** from `minecraft.net` over TLS (never mirrors); zip CRC validation of every member; staging smoke-run before activation; our own SHA-256 recorded in the ledger for auditability. Accept and document: this is the best available verification without publisher checksums. |
| R-09 | **Update pipeline interrupted mid-swap** (power loss/process death during activation). | L | H | State machine persists each phase; swap is two renames with a journaled intent file; on boot, any non-DONE update record triggers automatic rollback to `previous/`. |
| R-10 | **World data loss** during backup/restore/update. | L | H | Never-delete-last-backup guard; restore writes to a temp dir then swaps; update preserves worlds via copy-then-verify, not move; backups are CRC-validated at creation and at restore time. |
| R-11 | **Malicious world/pack imports** (zip bombs, path traversal, giant files). | M | M | Import quarantine: size caps, member count caps, decompression-ratio guard, path canonicalization + containment, extension allowlist. |
| R-12 | **Console command injection / log secret leakage.** | L | M | Command sanitizer (no control chars, length cap); redactor strips tokens matching secret patterns from all persisted logs; tunnel secret never printed. |
| R-13 | **Multiple instances → port conflict or duplicate process.** | M | M | Port registry + bind probe before start; pid ledger with liveness check; start refused with actionable error. |
| R-14 | **GPL compliance** (bundling box64/proot). | L | M | Both are GPL/LGPL open-source; ship sources/notice + licenses in the About screen and repo; agent (playit) binary is downloaded, not bundled. |
| R-15 | **On-device (phone) testing still impossible in CI.** | H | M | ARM64 translation is now verified on REAL arm64 hardware (ubuntu-24.04-arm runner: full proot→box64→bedrock_server stack + RakNet round-trip + world persistence). What remains open is phone-specific: bionic/SELinux exec, OEM quirks, real touch of the network stack — tracked as DoD items. |
| R-16 | **Storage bloat** (multiple instances × ~1 GB each + backups). | M | L | Storage usage monitor per instance; retention policies; backup pruning UI; update cleanup keeps only current + previous. |

## Explicit non-goals / honest statements

- We do **not** claim the server runs on every Android device — only on verified ones.
- We do **not** promise uninterrupted hosting; Android can and will kill us sometimes.
- We do **not** expose remote administration; admin stays local by design.
- We do **not** bundle Mojang binaries; the app downloads them at setup from the official
  source, and the EULA is surfaced during onboarding.

| R-17 | **Redistribution of the proprietary BDS zip inside release APKs** (Mojang EULA forbids redistribution; owner explicitly accepted this posture for a private/hobby distribution via GitHub releases). | M | H | BDS zip is fetched at BUILD time by CI straight from minecraft.net (TLS, sha256+size pinned), never committed to git, never modified; Mojang EULA gate shown before first server start; THIRD_PARTY_NOTICES + README state the posture. If ever asked to stop by the rights holder: remove release APKs, switch back to first-run download (ADR-003 path is one CI flag away). |
| R-18 | **glibc-static proot on Android bionic** — static binaries generally run on Android kernels, but device-level exec/SELinux behavior is unverified (R-15's phone gap). | M | H | proot is fully static (CI-verified on arm64 Linux); musl-static alternative recipe documented if glibc-static misbehaves on a device; fallback = Termux-integration profile (R-01). |
