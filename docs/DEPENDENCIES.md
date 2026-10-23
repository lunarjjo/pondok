# Dependency Inventory — Pondok

Everything the system depends on, what it is for, how it is obtained, and its license.
Versions are **pinned**; bumps are deliberate commits recorded here.

## A. Downloaded at setup (never bundled, never committed)

| Component | Source | Version policy | License | Purpose |
|---|---|---|---|---|
| Minecraft Bedrock Dedicated Server | `https://www.minecraft.net/bedrockdedicatedserver/bin-linux/bedrock-server-<v>.zip` | latest release, or user-pinned | Minecraft EULA (proprietary, free) | The server itself |
| Debian minimal arm64 rootfs (proot profile only) | official Debian cloud image / docker rootfs tarball | Debian 12 stable | DFSG-free | distro environment for proot runtime |
| playit.gg agent | `https://github.com/playit-cloud/playit-agent/releases` (`playit-linux-aarch64`) | 1.0.12 (non-deprecated lines: 0.17.1, 1.0.x) | proprietary freeware (binary) | UDP tunnel; source available for parts (Rust) |

## B. Bundled in the APK (open-source, exec'd from `nativeLibraryDir`)

| Component | Version | License | Purpose |
|---|---|---|---|
| Box64 | pinned release build, arm64 | LGPL-2.1 (libs) / GPL where applicable | x86_64→ARM64 translation to run the official BDS ELF |
| proot | pinned release build, arm64 | GPL-2.0 | user-space rootfs virtualization (fallback profile) |

These ship as `lib/arm64-v8a/libpondok_box64.so`, `libpondok_proot.so`. Sources and
build instructions recorded in `THIRD_PARTY_NOTICES.md` (repo) and the in-app About screen.

## C. Flutter / Dart packages (app)

| Package | Version | License | Purpose |
|---|---|---|---|
| flutter | 3.24.5 (Dart 3.5.4) | BSD-3 | app framework |
| provider | 6.1.2 | MIT | state management |
| path_provider | 2.1.5 | BSD-3 | app storage locations |
| archive | 3.6.1 | MIT | backup/world zip handling (create, extract, CRC) |
| http | 1.2.2 | BSD-3 | version checks + downloads |
| intl | 0.19.0 | BSD-3 | formatting |
| shared_preferences | 2.3.2 | BSD-3 | lightweight app settings |
| (dev) flutter_test, test, flutter_lints | SDK-pinned | BSD-3 | testing / linting |

`pondok_core` itself is **zero-dependency pure Dart** (stdlib only) — deliberate: the
management core must stay testable on bare CI runners and portable to any future host.

## D. Build / CI

| Tool | Version | Purpose |
|---|---|---|
| GitHub Actions ubuntu-latest | — | unit + integration (real BDS x86_64) tests, analyzer |
| GitHub Actions ubuntu-latest + Flutter | 3.24.5 | widget tests, release APK build |
| actions/cache | v4 | BDS zip cache keyed by version + SHA-256 |

## E. External services

| Service | Use | Failure mode |
|---|---|---|
| minecraft.wiki MediaWiki API | version discovery | fallback: manual version entry + URL probe; app remains usable |
| minecraft.net CDN | BDS downloads | setup blocked (degrades to manual zip import if local file provided) |
| playit.gg | public UDP tunnel | LAN-only mode (NullProvider) — all management features unaffected |
| (none other) | — | no analytics, no telemetry, no accounts of ours |
