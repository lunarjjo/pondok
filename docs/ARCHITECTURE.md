# Architecture — Pondok

**Scope:** full system design. Phase 0 findings (see `PHASE0_REPORT.md`) drive every
decision below. Terminology: **host** = the Android phone running the app; **BDS** =
official Mojang Bedrock Dedicated Server; **runtime** = the execution stack that runs
BDS on the host.

---

## 1. System overview

```
┌──────────────────────────────────────────────────────────────────┐
│ Android host (ARM64, no root)                                    │
│                                                                  │
│  ┌─────────────────────────── Flutter app ────────────────────┐  │
│  │  UI layer (Material 3, DayNight theme follows device)      │  │
│  │   onboarding · dashboard · console · files · players ·     │  │
│  │   config editor · versions · backups · tunnel · settings   │  │
│  ├────────────────────────────────────────────────────────────┤  │
│  │  pondok_core (pure Dart, fully unit-tested)                │  │
│  │   InstanceManager · BdsProcess supervisor ·                │  │
│  │   ConsoleParser · ServerProperties · Allowlist ·           │  │
│  │   VersionManifest · UpdatePipeline · BackupManager ·       │  │
│  │   TunnelProvider abstraction (+ PlayitProvider)            │  │
│  ├────────────────────────────────────────────────────────────┤  │
│  │  Platform channel (Kotlin)                                 │  │
│  │   ServerForegroundService · process lifecycle · wake lock  │  │
│  │   storage bridges · battery guidance                       │  │
│  └────────────────────────────────────────────────────────────┘  │
│                          │ exec / pipes                           │
│  ┌───────────────────────── Runtime layer ────────────────────┐  │
│  │  RuntimeProfile: "lean"  → box64 (bundled) + wrapped libs  │  │
│  │  RuntimeProfile: "proot" → proot + Debian arm64 rootfs     │  │
│  │                (bundled proot; rootfs downloaded)          │  │
│  │        box64 → bedrock_server (official x86_64 ELF)        │  │
│  │  playit agent (aarch64, downloaded) — UDP tunnel           │  │
│  └────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────┘
                             │ UDP 19132 (RakNet)
                    playit.gg edge network ─── public players
```

Design principles:

1. **Honest boundaries.** Everything that is only community-verified (Box64 translation on
   real devices, tunnel end-to-end) sits behind an interface with a diagnostics screen.
2. **The app is a supervisor, not a server.** BDS runs as a real child process; the app
   never simulates or fakes server state. Every UI state derives from observed process
   reality (stdout lines, exit codes, files).
3. **Pure-Dart core.** All management logic lives in `packages/pondok_core` with zero
   Flutter imports, so it is testable on any CI runner — including **integration tests
   against the real BDS binary on x86_64 runners**.
4. **Local administration only.** No administrative listener is ever exposed through the
   tunnel. The game tunnel forwards exactly one UDP port to the server process.

## 2. Runtime profiles

The single most important abstraction. A `RuntimeProfile` prepares an execution
environment and returns the exact argv + environment to run `bedrock_server`.

| | **Lean** (default target) | **Proot** (fallback) |
|---|---|---|
| Components | `box64` (arm64, bundled as jniLib) | `box64` + `proot` (bundled) + Debian arm64 minimal rootfs (~80 MB, downloaded at setup) |
| argv | `box64 <instance>/bedrock_server` | `proot -R <rootfs> -b <instance>:/server box64 /server/bedrock_server` |
| Why it can work | BDS deps are all Box64-wrapped libs (verified dependency list, Phase 0 §2) | Exact community-proven stack (BedrockServerTermux) |
| Risk | Least-tested configuration on real devices | Heavier; slower startup; larger storage |
| Selection | Onboarding runs a **runtime diagnostic** (exec `box64 --version`, then a BDS smoke-start in staging); auto-falls back to proot on failure | |

Bundling rule: `box64`/`proot` are GPL/LGPL open-source binaries shipped inside the APK
`lib/arm64-v8a/` as `libpondok_box64.so` / `libpondok_proot.so` (exec from
`nativeLibraryDir` is allowed on all Android versions and SELinux domains). The Debian
rootfs and BDS zip are **downloaded during setup** — never bundled.

**targetSdk 28 rationale** (sideload-only app): executing *downloaded* binaries (BDS after
updates, playit agent) from app-private storage requires the legacy SELinux domain that
targetSdk 28 apps run in — the same approach Termux uses today. The trade-offs and the
alternative (Termux integration) are recorded in `RISK_REGISTER.md` R-01.

## 3. Instance model & storage layout

```
<app-private>/files/
├── runtime/
│   ├── box64.version          # bundled component ledger
│   ├── rootfs/                # proot profile only
│   └── staging/               # update pipeline workspace
├── instances/
│   └── <instance-id>/
│       ├── instance.json      # name, created, runtime profile, port, tunnel binding
│       ├── server/            # extracted BDS distribution (this is the server CWD)
│       │   ├── bedrock_server
│       │   ├── server.properties
│       │   ├── allowlist.json
│       │   ├── worlds/<level-name>/db/...
│       │   ├── behavior_packs/ resource_packs/
│       │   └── logs/          # rotated stdout capture (pondok-YYYYMMDD.log)
│       └── backups/
│           ├── manifest.json  # index + retention policy
│           └── <timestamp>.zip
├── tunnels/
│   ├── playit/                # agent binary (downloaded), playit.toml, state
│   └── providers.json
└── ledger/
    ├── installs.json          # BDS install/update history + provenance
    └── updates.json           # update pipeline run records
```

Multi-instance: every instance owns a directory and a UDP port; `InstanceManager` refuses
port collisions and duplicate processes (port probe + pid ledger before start).

## 4. Core modules (`packages/pondok_core`)

| Module | Responsibility | Verified against |
|---|---|---|
| `BdsProcess` | Supervisor: spawn with env (`LD_LIBRARY_PATH`), stream stdout/stderr → `ConsoleLine`s, stdin command sending, graceful stop (`stop` + bounded wait → SIGKILL ladder), exit-code classification (0 = clean, signal/other = crash), startup watchdog (fail if no `Server started` within N s) | Real BDS in CI integration tests |
| `ConsoleParser` | Parse `[YYYY-MM-DD HH:MM:SS:mmm LEVEL] msg` (format verified in Phase 0 §2) into structured events; level filtering; regex search; player-join/leave extraction | Real log fixtures from evidence |
| `ServerProperties` | Typed reader/writer with comment preservation; per-key validation registry (allowed values extracted from the real 1.26.52.3 file) | Real file fixtures |
| `Allowlist` | JSON read/write/add/remove; also emits the console command form (`allowlist add X`) so both file and runtime stay in sync | Verified format + live command in PoC |
| `VersionManifest` | Latest release/preview via minecraft.wiki API; existence probe via official URL HEAD (browser UA, redirect handling — 308 quirk verified); returns candidates + verification | Live endpoints |
| `Downloader` | Streaming download with progress callback, resume, and CRC-validating zip extraction | Unit + integration |
| `UpdatePipeline` | §5 state machine | Unit (mock FS) + integration (real BDS staging smoke-run) |
| `BackupManager` | Zip worlds + configs; manifest with size, world name, BDS version; restore with pre-flight validation; retention (never deletes the last valid backup) | Unit + integration |
| `TunnelProvider` | Interface: `start/stop/status/publicAddress/healthStream`; implementations: `PlayitProvider` (process supervisor over the aarch64 agent; parses claim URL from stdout; persists secret; bounded exponential backoff restarts), `NullProvider` (LAN-only) | Mocked agent process in CI |
| `Security` | Command sanitizer (console input), path guard (no `..`, no absolute escape outside instance root), secret redactor for logs | Unit |

## 5. Safe update pipeline (state machine)

States persist to `updates.json` so an interrupted update resumes safely and never
half-activates. Worlds, packs, and user config are carried across by **directory
preservation + atomic rename**, never by in-place overwrite.

```
IDLE → CHECKED → APPROVED → BACKED_UP → DOWNLOADED → VERIFIED
     → STAGED → SMOKE_PASSED → PRESERVED → ACTIVATED → HEALTHY → DONE
                    (any failure from VERIFIED onward) → ROLLED_BACK → IDLE
```

- **CHECKED**: wiki + HEAD probe agree; proposed version + compat warnings surfaced.
- **BACKED_UP**: verified backup of worlds + configs (zip CRC + manifest entry).
- **DOWNLOADED**: zip to staging; own SHA-256 recorded.
- **VERIFIED**: extraction with per-member CRC validation.
- **SMOKE_PASSED**: staged `bedrock_server` started in staging dir, observed
  `Server started.` line, stopped cleanly. (Replaces first-party checksums — Phase 0 §6.)
- **PRESERVED**: `worlds/`, `behavior_packs/`, `resource_packs/`, `allowlist.json`,
  `permissions.json`, `server.properties` copied from current → staged instance.
- **ACTIVATED**: `server/` ⇄ `server.new/` atomic swap via rename; old version retained
  as `previous/` (rollback source; never auto-deleted).
- **HEALTHY**: post-activation real start + health check window.
- **ROLLED_BACK**: rename back, health check, record failure diagnostics.

Policy: manual approval (default) / automatic checks / explicit opt-in unattended updates.
Guardrails: never delete the last known-good version directory; never delete the only
valid backup; an update that fails while the server is running is deferred, not applied
live.

## 6. Foreground service & lifecycle (Kotlin)

- `ServerForegroundService` (specialized `Service`): holds the child processes, partial
  wake lock, persistent notification with uptime + RAM + Stop action, and is the only
  component allowed to start/stop instances.
- App death ≠ server death is NOT assumed: the service runs the processes; if the *service*
  is killed by the OS, child processes die with it — the app detects this on next launch
  ("server died with the app, here is the tail of the log") rather than pretending.
- Reboot: `BOOT_COMPLETED` receiver offers (does not force) restart of instances that were
  running before shutdown.
- Battery guidance is a first-class screen (OEM-specific instructions), not a footnote.

## 7. Security model

- **Trust boundary 1 — device**: administration (everything) is local-only; the app holds
  no network listener. The only listening sockets belong to BDS (game UDP) and the playit
  agent (its local control channel, bound to localhost — never port-forwarded).
- **Trust boundary 2 — tunnel**: the tunnel forwards exactly one UDP port to the BDS
  process. Console/file manager/config editor are unreachable through it.
- Credentials: playit agent secret stored in app-private storage, redacted from every log
  sink (redactor module), never committed.
- Inputs: console commands are length-capped and newline-sanitized; file operations go
  through the path guard (canonicalize + containment check); config editor validates
  against the typed registry before writing; uploads (world/pack imports) are quarantined
  (CRC-validated zip, size caps, extension allowlist) before touching a live instance.
- Documented limitations: the game server itself is exposed to the internet by design;
  malicious packs/worlds can affect the *game*, not the phone (BDS runs as the app's
  sandboxed uid with no Android permissions); translation layer (box64/proot) is trusted
  third-party code we bundle — versions pinned and recorded in the dependency inventory.

## 8. Testing strategy

| Layer | Where | What |
|---|---|---|
| Unit | local + CI (`dart test`) | parsers, properties, allowlist, pipeline transitions (mock FS/process), tunnel mock, security guards |
| Integration (real BDS) | CI x86_64 runner | download official zip (cached by version+sha), run `BdsProcess` suite: start→console→allowlist→stop; crash kill−9 → non-zero exit; restart → world persists; port change honored. This is the same evidence as Phase 0 PoC, automated. |
| Widget | CI (`flutter test`) | screen states: loading/error/empty/recovery |
| Build | CI (`flutter build apk`) | release APK per commit on main + artifacts; versioned GitHub Release with changelog on tags |
| On-device | manual checklist (Definition of Done) | runtime profiles, tunnel join from second network — tracked as open issues |

## 9. Milestone mapping

Phase 1 (runtime) → core modules + CI integration tests — **this repository starts here.**
Phase 2 (app UI) → after runtime + connectivity demos. Phase 3 (management features) →
core features + UI wiring. Phase 4 (updates) → pipeline. Phase 5 (tunnel) → provider.
Phases 6–8 (reliability/security/testing/GitHub workflow) run continuously as
cross-cutting requirements; see `ROADMAP.md` for acceptance criteria.
