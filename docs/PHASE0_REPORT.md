# Phase 0 Report — Technical Feasibility & Proof of Concept

**Project:** Pondok — Bedrock Mobile Server Manager
**Date:** 2026-10-23
**Status:** Phase 0 complete. PoC executed against the real BDS binary.

This report separates **VERIFIED** results (executed and observed by us, with evidence in
`docs/evidence/` or reproducible commands) from **UNVERIFIED** assumptions (documented or
community-reported, not executed by us). No claim below is presented as verified unless we
actually ran it.

---

## 1. Official BDS distribution (VERIFIED)

| Item | Result |
|---|---|
| Current release version | **1.26.52.3** (source: minecraft.wiki, cross-checked against AUR package `minecraft-bedrock-server 1.26.52.3-1`, updated 2026-09-26) |
| Current preview version | **1.26.70.20** |
| Official download page | https://www.minecraft.net/en-us/download/server/bedrock |
| Official Linux URL pattern | `https://www.minecraft.net/bedrockdedicatedserver/bin-linux/bedrock-server-<version>.zip` |
| Official preview pattern | `https://www.minecraft.net/bedrockdedicatedserver/bin-linux-preview/bedrock-server-<version>.zip` |
| Distribution size | 94,927,522 bytes (release Linux zip) — matches wiki's "≈ 92.7 MB" |
| SHA-256 (1.26.52.3 linux) | `f6348d84fa714d04ca194f207e89453ca6bba0a1359396475271a52a150471c6` |
| Official checksums published | **No.** Mojang does not publish checksums for BDS zips (see §6 for our verification strategy) |
| System requirements (page) | Ubuntu 22.04+ LTS; 4 GB RAM recommended; 180 MB–1 GB disk |
| License | Minecraft EULA — free redistribution of the zip is common practice (AUR, itzg/docker-minecraft-bedrock-server) but we download from the official source at setup time and bundle nothing proprietary |

Practical download notes (VERIFIED, matters for the runtime manager):

- A plain `curl` without a browser-like `User-Agent` receives **HTTP 308** and no body.
  With a browser UA and redirect-following, the download succeeds (200, full body).
- The download page itself does **not** embed the zip URLs in static HTML; they are
  assembled client-side. Version discovery must come from another source (§5).

## 2. BDS runtime behavior on Linux x86_64 (VERIFIED — PoC)

We downloaded the official 1.26.52.3 Linux distribution and drove the real server process
from a supervisor script in a sandbox (x86_64, Debian 13, glibc 2.41). Evidence:
`docs/evidence/bds_run1.log`, `docs/evidence/bds_run3.log`.

**Executable analysis (VERIFIED):**

- `bedrock_server` is a 256 MB stripped ELF x86-64 PIE, dynamically linked.
- Runtime library dependencies are minimal and all standard:
  `libc.so.6`, `libpthread.so.0`, `libdl.so.2`, `libm.so.6`, `libgcc_s.so.1`, `librt.so.1`
  plus the dynamic loader. **No OpenSSL/libcurl dependency.** This matters greatly for
  Box64 compatibility (§3): every dependency is covered by Box64's built-in wrapped
  libraries.
- Startup does not prompt for EULA acceptance in this version; it runs directly.

**Process control semantics (VERIFIED):**

| Operation | Observed behavior |
|---|---|
| Start to "Server started." | ~2 seconds (06:11:48 → 06:11:50 in run 1) |
| World creation | First run prints `CREATING VANILLA WORLD`, creates `worlds/Bedrock level/` (db/, level.dat, levelname.txt) |
| Subsequent runs | `Opening level 'worlds/Bedrock level/db'` — world persists, no recreation |
| Console input | Commands written to stdin are executed; output lines on stdout with `[timestamp LEVEL]` prefix |
| `list` | `There are 0/10 players online:` — respects `max-players` |
| `stop` | `Server stop requested.` → `Stopping server...` → `Quit correctly` → **exit code 0** (graceful) |
| `kill -9` | Process dies with signal; supervisor observes non-zero/abnormal exit (crash detection via exit code is reliable) |
| Port change | Editing `server-port=19140` in `server.properties` → server binds `[::]:19140` on next start |
| Allowlist | `allowlist add PoCPlayer` on stdin rewrites `allowlist.json` to `[{"ignoresPlayerLimit":false,"name":"PoCPlayer"}]` |
| Defaults in 1.26.x | `online-mode=true`, `allow-list=true` (server warns when allowlist is empty) |
| Signaling | `Signed in to signaling service successfully` — the NetherNet signaling service connects on its own; classic RakNet UDP on `server-port` still binds normally |

**Console line format (VERIFIED):** `[YYYY-MM-DD HH:MM:SS:mmm LEVEL] message`, e.g.
`[2026-10-23 06:11:48:175 INFO] Starting Server`. Levels observed: `INFO`, `WARN`.
This exact format is what the console parser must handle.

## 3. Android ARM64 execution path (community-verified; NOT executed by us)

The official BDS Linux binary is **x86_64 only**. There is no official ARM64 build. The
established no-root execution stack on Android is:

```
Termux (API 28 target → legacy SELinux domain, exec from app-data allowed)
  └── proot-distro (Debian/Ubuntu arm64 rootfs — user-space "chroot" via ptrace)
        └── Box64 (x86_64 → ARM64 translation with dynarec)
              └── bedrock_server (official x86_64 binary, unmolested)
```

Key findings from research (sources: BedrockServerTermux project — 112 commits, active
through Oct 2026; minara control panel; multiple community writeups):

- **Box64 wrapped libraries cover the entire BDS dependency list** (§2). This is why the
  stack works without shipping any x86_64 system libraries — Box64 services libc/pthread/
  dl/m/gcc_s/rt calls through its built-in wrappers against the host's arm64 glibc.
- Reference project reports this works on Android 7.0+, no root, minimum 2 GB RAM
  (4 GB+ recommended), ~2 GB storage for a full Debian proot install.
- Reported performance for a phone-hosted server through translation: 1–2 players on
  2–3 GB RAM devices, 2–5 players on 4–6 GB, 5–10 players on 8 GB+ (with lowered
  `view-distance` 4–6 and `max-threads` 5–6). CPU usage is inherently higher than native.
- Known caveats from the community: older specific BDS versions can be incompatible with
  Box64 on ARM (use latest stable); battery optimization kills background Termux
  (`termux-wake-lock` + disable optimization required); device must stay plugged in for
  sustained hosting.

**UNVERIFIED by us:** we have no ARM64 Android hardware in the development sandbox. The
Box64-on-device path, its performance on specific SoCs, and Android OEM process-kill
behaviors are **not verified first-hand**. The architecture therefore treats the runtime
layer as a swappable "runtime profile" (see `ARCHITECTURE.md`) and ships on-device
diagnostics to verify the stack in the field. The Definition-of-Doned hardware checklist
(README) explicitly lists on-device verification as a required step that remains open
until a physical device is available.

## 4. UDP tunneling provider (researched; agent behavior to be verified on device)

Bedrock multiplayer's classic transport is **RakNet over UDP** (default port 19132) —
still first-class in 1.26.x (verified: server binds UDP `server-port` and accepts
clients). The newer NetherNet/signaling transport also connected during our PoC, but
public-internet hosting for arbitrary clients is served by the classic UDP path.

Provider evaluation:

| Provider | UDP | Bedrock support | Linux ARM64 agent | Auth model | Fit |
|---|---|---|---|---|---|
| **playit.gg** | Yes (free) | Yes — "Minecraft Bedrock" tunnel type in free tier (NetherNet transport requires premium; classic UDP does not) | Yes — `playit-linux-aarch64` static binary in official releases (v1.0.12, 2026-10-01) | Claim code on first run (URL printed to agent stdout), or `SECRET_KEY` for unattended | **Primary provider** |
| ngrok | Paid tiers only | TCP/UDP gated | aarch64 agent exists | authtoken | Secondary (later) |
| Tailscale/ZeroTier | UDP (WireGuard) | Works but requires all players to join the VPN | Yes | account | Not "public internet" — excluded |
| bore/localtunnel | TCP only | No | — | — | Excluded (transport mismatch) |

playit.gg specifics (VERIFIED from official pages/repos):

- Agent releases include static `playit-linux-aarch64` (plus deb/rpm/apk and amd64/armv7
  builds). Non-deprecated release lines: `0.17.1` and `1.0.X`.
- First-run claim flow: the agent prints a claim URL to stdout; the user opens it and
  attaches the agent to a (free) playit.gg account. This is directly parseable by our
  supervisor from the agent's stdout.
- Unattended operation: `SECRET_KEY` environment variable (documented for the official
  Docker image) — suitable for persisting across restarts after initial claim.
- Free tier includes UDP tunnels and the Bedrock tunnel type; agent disconnections are
  handled by the agent itself, and our supervisor adds bounded exponential backoff for
  process-level restarts.

**UNVERIFIED by us:** end-to-end tunnel round-trip from an outside network (requires a
public account claim and a second network — impossible from this sandbox). The tunnel
integration test in CI therefore runs against a **mocked agent process**, and the
Definition of Done keeps "join through the tunnel from a different network" as an
explicit open item pending real hardware/network access.

## 5. Version discovery & update checking (VERIFIED mechanisms)

Because the official download page assembles URLs client-side, version discovery uses two
complementary verified mechanisms:

1. **minecraft.wiki MediaWiki API** (`api.php?action=parse&page=Bedrock_Dedicated_Server&
   prop=wikitext`) — returns wikitext containing the current release/preview versions
   (verified live: contains "As of 1.26.52.3"). Community-maintained, stable API, used by
   many tooling projects.
2. **Official URL HEAD probe** — `HEAD https://www.minecraft.net/bedrockdedicatedserver/
   bin-linux/bedrock-server-<v>.zip` with browser UA returns 200 for existing versions,
   404 otherwise (verified for 1.26.52.3 release and 1.26.70.20 preview; used to validate
   any arbitrary version a user requests).

The update checker combines both: wiki for "what is latest", HEAD probe for "does this
specific version exist on the official CDN", then the downloader uses the same URL with
browser UA + redirect following (the 308 quirk in §1 is handled).

## 6. Distribution integrity verification strategy

Mojang publishes no checksums for BDS zips. Our pipeline (Phase 4) therefore verifies
integrity through layered, honest mechanisms:

1. **Transport integrity:** download over HTTPS from `minecraft.net` (TLS).
2. **Archive integrity:** every member file's CRC is validated during extraction
   (standard ZIP CRC32 per-member check; corrupt archives fail extraction loudly).
3. **Staging smoke-run:** the update is installed into a staging directory and the new
   `bedrock_server` is actually started and observed reaching a known-good startup line
   before activation.
4. **Recorded provenance:** each install records the URL, byte size, SHA-256 we computed
   ourselves, and date in an `installs.json` ledger — enabling later auditing and
   regression comparison.

This is documented as an engineering substitution, not as an equivalent of first-party
checksums. See RISK_REGISTER.md R-08.

## 7. Android platform constraints (documented; standard behavior)

- **Foreground service:** required to keep the host alive; persistent notification with
  explicit stop control. Because the app will ship via GitHub Releases (sideload, not Play
  Store) and needs to exec downloaded binaries, we adopt **targetSdk 28** (Termux's
  proven approach) which: (a) keeps the legacy SELinux domain that permits executing
  binaries from app-private storage, (b) exempts us from Android 14+ FGS-type and
  Android 15 dataSync-timeout restrictions, and (c) avoids scoped storage friction for
  world import/export. Trade-offs (install-time "built for older Android" warning, no
  Play distribution) are documented in the risk register.
- **Battery/Doze:** foreground service + partial wake lock while the server runs + an
  in-app guide for disabling battery optimization per OEM. We never promise 24/7.
- **Process death/reboot:** the app persists desired server state; on service restart it
  offers recovery (not silent auto-restart) and detects port conflicts / duplicate
  processes before starting.
- **Storage:** runtime + worlds live in app-private storage (exec-safe); large artifacts
  (backups, exports) can be shared to public storage on demand.

## 8. PoC verdict

| Question | Verdict |
|---|---|
| Can the official BDS binary be controlled programmatically (start/console/stop/crash-detect)? | **VERIFIED — yes**, on x86_64 Linux, with exit codes distinguishing graceful stop from crash |
| Does config editing flow through to runtime (port, allowlist)? | **VERIFIED — yes** |
| Can a managed world persist across restarts? | **VERIFIED — yes** |
| Can the x86_64 binary run on Android ARM64? | **Community-verified stack (Termux+proot+Box64), UNVERIFIED by us — no device available** |
| Can public connectivity be provided via UDP tunnel with a static aarch64 agent? | **Provider capability verified (playit.gg publishes aarch64 agent + free UDP Bedrock tunnels); end-to-end UNVERIFIED by us — needs real network/account** |

**Conclusion: feasible.** The core process-management layer can be built and *actually
tested* against the real BDS binary on x86_64 CI runners today; the ARM64 translation
layer and tunnel are community-proven but must be verified on real hardware before the
Definition of Done can be claimed. The architecture (next document) is designed so those
two unverified layers are isolated behind swappable interfaces with on-device diagnostics.

---

## Appendix A — PoC reproduction

```bash
# Download (browser UA required)
curl -L -o bds.zip "https://www.minecraft.net/bedrockdedicatedserver/bin-linux/bedrock-server-1.26.52.3.zip" \
  -H "User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36"
sha256sum bds.zip   # f6348d84fa714d04ca194f207e89453ca6bba0a1359396475271a52a150471c6
unzip -q bds.zip -d server/

# Run with console attached; then type: list   stop
cd server && LD_LIBRARY_PATH=. ./bedrock_server
```

Raw logs of our supervised runs are preserved in `docs/evidence/`.
