#!/usr/bin/env bash
# ==========================================================================
# pondok · runtime pack builder (ADR-004: fully-bundled, zero-setup runtime)
#
# Produces ONE zip that the APK embeds as a Flutter asset. On first launch
# the app unpacks it into its private storage and the server is ready —
# no downloads, no setup steps, nothing else to install.
#
#   runtime_pack.zip (flat members)
#     manifest.json   recipe + sha256 of every member
#     proot           proot, statically linked (runs on any arm64 Linux
#                     userland — including Android's bionic)
#     rootfs.tar      ubuntu-base arm64 + box64 @ /opt/box64/box64
#     bds.zip         UNMODIFIED official Bedrock Dedicated Server distro
#
# Host requirements: linux/arm64 (CI: ubuntu-24.04-arm), root or sudo,
# network access.
#
# Legal posture: nothing proprietary is committed to git. The official BDS
# zip enters only at build time, straight from minecraft.net with its
# published sha256 + size pinned, and lives only inside build artifacts.
# ==========================================================================
set -euo pipefail

BDS_VERSION="${BDS_VERSION:?set in workflow}"
BDS_SHA256="${BDS_SHA256:?set in workflow}"
BDS_ZIP_BYTES="${BDS_ZIP_BYTES:?set in workflow}"
BDS_UA="${BDS_UA:?set in workflow}"

BOX64_TAG="v0.4.4"
PROOT_TAG="v5.5.0"
UBUNTU_BASE_VERSION="24.04.5"
UBUNTU_BASE_SHA256="a91d5a93010193712d346d761372b7c9db6dfcf093893161c64ca107f05914f2"
# box64's official x86_64 library bundle: bedrock_server needs real x86_64
# .so files (libstdc++, libgcc_s, …) that box64 does NOT wrap — verified
# the hard way: without them box64 dies with
# "Error: Loading needed libs in elf ./bedrock_server" (exit 255).
X86LIBS_URL="https://github.com/ptitSeb/box64/releases/download/${BOX64_TAG}/box64-bundle-x86-libs-${BOX64_TAG}.tar.gz"
X86LIBS_SHA256="1d4a8787a8a92267c1be673ec194c69e3bb33d14c800575d94131084142fcff0"
X86LIBS_BYTES="34368070"
PACK_VERSION="${PACK_VERSION:-2}"

OUT_DIR="${1:-build/runtime_pack}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

log() { printf '\033[1;36m[pack]\033[0m %s\n' "$*"; }
s() { if command -v sudo >/dev/null 2>&1; then sudo "$@"; else "$@"; fi; }

export BOX64_TAG PROOT_TAG UBUNTU_BASE_VERSION UBUNTU_BASE_SHA256
export BDS_VERSION BDS_SHA256 BDS_ZIP_BYTES PACK_VERSION X86LIBS_URL X86LIBS_SHA256 X86LIBS_BYTES

[ "$(uname -m)" = "aarch64" ] || { echo "FATAL: arm64 host required, got $(uname -m)" >&2; exit 1; }
log "host ok: aarch64 · $(nproc) cpu · $(free -h | awk '/^Mem:/{print $2}') ram"

# --- [1/5] proot (static) --------------------------------------------------
log "[1/5] proot $PROOT_TAG — static build (upstream dist recipe)"
s apt-get update -qq
s apt-get install -y -qq build-essential pkg-config libtalloc-dev >/dev/null
s apt-get install -y -qq uthash-dev >/dev/null 2>&1 || log "  uthash-dev n/a — relying on git submodule"
git clone --quiet --depth 1 --recurse-submodules --branch "$PROOT_TAG" \
  https://github.com/proot-me/proot "$WORK/proot-src"
# LDFLAGS must enter via the ENVIRONMENT: as a make command-line variable
# it would override the GNUmakefile's own `LDFLAGS += $(talloc libs)` and
# the link would miss libtalloc entirely (learned the hard way — CI cycle
# 2 of this workflow).
if ! LDFLAGS=-static make -C "$WORK/proot-src/src" -j"$(nproc)" \
     GIT=false WITHOUT_PYTHON=1 >"$WORK/proot.log" 2>&1; then
  tail -40 "$WORK/proot.log"; echo "FATAL: proot build failed" >&2; exit 1
fi
PROOT_BIN="$WORK/proot-src/src/proot"
file "$PROOT_BIN"
file "$PROOT_BIN" | grep -q 'statically linked' \
  || { echo "FATAL: proot not statically linked" >&2; exit 1; }
log "proot ok: $("$PROOT_BIN" --version 2>&1 | head -1)"
install -m 0755 "$PROOT_BIN" "$WORK/proot"

# --- [2/5] box64 (dynarec) --------------------------------------------------
log "[2/5] box64 $BOX64_TAG — source build with ARM_DYNAREC"
git clone --quiet --depth 1 --branch "$BOX64_TAG" \
  https://github.com/ptitSeb/box64 "$WORK/box64-src"
cmake -S "$WORK/box64-src" -B "$WORK/box64-build" \
  -DARM_DYNAREC=ON -DCMAKE_BUILD_TYPE=Release >/dev/null
if ! cmake --build "$WORK/box64-build" -j"$(nproc)" >"$WORK/box64.log" 2>&1; then
  tail -40 "$WORK/box64.log"; echo "FATAL: box64 build failed" >&2; exit 1
fi
BOX64_BIN="$WORK/box64-build/box64"
ldd "$BOX64_BIN"
"$BOX64_BIN" -v 2>&1 | head -3 || true

# --- [3/5] rootfs -----------------------------------------------------------
log "[3/5] ubuntu-base $UBUNTU_BASE_VERSION arm64 rootfs"
UB_NAME="ubuntu-base-${UBUNTU_BASE_VERSION}-base-arm64.tar.gz"
UB_URL="https://cdimage.ubuntu.com/ubuntu-base/releases/24.04/release/$UB_NAME"
curl -fsSL -o "$WORK/$UB_NAME" "$UB_URL"
echo "$UBUNTU_BASE_SHA256  $WORK/$UB_NAME" | sha256sum -c - >/dev/null \
  || { echo "FATAL: ubuntu-base sha mismatch" >&2; exit 1; }
mkdir -p "$WORK/rootfs"
tar -xzf "$WORK/$UB_NAME" -C "$WORK/rootfs"

# box64 lives INSIDE the rootfs — this is the binary the device executes.
mkdir -p "$WORK/rootfs/opt/box64"
install -m 0755 "$BOX64_BIN" "$WORK/rootfs/opt/box64/box64"

# Static DNS inside the rootfs. ubuntu-base ships a DANGLING resolv.conf
# symlink (systemd-resolved) — inside proot, name resolution then fails,
# online-mode's Minecraft-services check errors out after 60 s and the
# server STOPS ITSELF before ever printing "Server started." (CI cycle 5).
rm -f "$WORK/rootfs/etc/resolv.conf"
printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > "$WORK/rootfs/etc/resolv.conf"

log "[3b] box64 x86_64 libs bundle (the un-wrapped libs bedrock_server needs)"
curl -fsSL -o "$WORK/x86libs.tar.gz" "$X86LIBS_URL"
echo "$X86LIBS_SHA256  $WORK/x86libs.tar.gz" | sha256sum -c - >/dev/null \
  || { echo "FATAL: x86-libs bundle sha mismatch" >&2; exit 1; }
tar -xzf "$WORK/x86libs.tar.gz" -C "$WORK/rootfs"
# The bundle also ships i386 libs we never load — drop them (pack size).
rm -rf "$WORK/rootfs/usr/lib/box64-i386-linux-gnu"
ls "$WORK/rootfs/usr/lib/box64-x86_64-linux-gnu/" | wc -l

# Belt & suspenders: copy any box64 .so dep missing from ubuntu-base.
# The runner is the same distro+arch, so its copies are drop-in.
ldd "$BOX64_BIN" | awk '/=> \//{print $3}' | while read -r so; do
  real="$(readlink -f "$so")"
  if [ ! -e "$WORK/rootfs$real" ]; then
    log "  + rootfs$real (copied from host)"
    install -D -m 0755 "$real" "$WORK/rootfs$real"
  fi
done

log "re-packing enriched rootfs -> rootfs.tar (plain tar; outer zip deflates)"
tar -cf "$WORK/rootfs.tar" -C "$WORK/rootfs" .

# --- [4/5] official BDS -----------------------------------------------------
log "[4/5] official BDS $BDS_VERSION (minecraft.net)"
BDS_ZIP="bedrock-server-${BDS_VERSION}.zip"
mkdir -p "$HOME/bds"
if [ -f "$HOME/bds/$BDS_ZIP" ] && [ "$(stat -c%s "$HOME/bds/$BDS_ZIP")" = "$BDS_ZIP_BYTES" ]; then
  log "using cached $BDS_ZIP"
  cp "$HOME/bds/$BDS_ZIP" "$WORK/$BDS_ZIP"
else
  log "downloading $BDS_ZIP from the official source"
  curl -fsSL -H "User-Agent: $BDS_UA" -o "$WORK/$BDS_ZIP" \
    "https://www.minecraft.net/bedrockdedicatedserver/bin-linux/$BDS_ZIP"
fi
echo "$BDS_SHA256  $WORK/$BDS_ZIP" | sha256sum -c - >/dev/null \
  || { echo "FATAL: BDS sha mismatch" >&2; exit 1; }
[ "$(stat -c%s "$WORK/$BDS_ZIP")" = "$BDS_ZIP_BYTES" ] \
  || { echo "FATAL: BDS size mismatch" >&2; exit 1; }
cp "$WORK/$BDS_ZIP" "$WORK/bds.zip"

# --- [5/5] manifest + pack zip -----------------------------------------------
log "[5/5] manifest + pack zip"
python3 - "$WORK" <<'PYEOF'
import datetime, hashlib, json, os, sys
work = sys.argv[1]

def sha(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()

manifest = {
    "format": "pondok-runtime-pack/1",
    "packVersion": int(os.environ.get("PACK_VERSION", "1")),
    "createdAt": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
    "components": {
        "proot":  {"tag": os.environ["PROOT_TAG"], "sha256": sha(f"{work}/proot")},
        "box64":  {"tag": os.environ["BOX64_TAG"],
                   "sha256": sha(f"{work}/box64-build/box64"),
                   "path": "/opt/box64/box64"},
        "rootfs": {"base": "ubuntu-base-" + os.environ["UBUNTU_BASE_VERSION"] + "-arm64",
                   "sha256_gz": os.environ["UBUNTU_BASE_SHA256"]},
        "x86libs": {"source": "box64-bundle-x86-libs-" + os.environ["BOX64_TAG"],
                    "sha256": os.environ["X86LIBS_SHA256"],
                    "path": "/usr/lib/box64-x86_64-linux-gnu"},
        "bds":    {"version": os.environ["BDS_VERSION"],
                   "sha256": os.environ["BDS_SHA256"],
                   "zipBytes": int(os.environ["BDS_ZIP_BYTES"])},
    },
    "members": {
        "proot":      {"sha256": sha(f"{work}/proot"),   "size": os.path.getsize(f"{work}/proot")},
        "rootfs.tar": {"sha256": sha(f"{work}/rootfs.tar"), "size": os.path.getsize(f"{work}/rootfs.tar")},
        "bds.zip":    {"sha256": os.environ["BDS_SHA256"], "size": int(os.environ["BDS_ZIP_BYTES"])},
    },
}
with open(f"{work}/manifest.json", "w") as f:
    json.dump(manifest, f, indent=2)
print(json.dumps(manifest, indent=2))
PYEOF

mkdir -p "$OUT_DIR"
( cd "$WORK" && zip -X -q "$OLDPWD/$OUT_DIR/runtime_pack.zip" \
    manifest.json proot rootfs.tar bds.zip -n .zip )
cp "$WORK/manifest.json" "$OUT_DIR/manifest.json"

log "pack: $(du -h "$OUT_DIR/runtime_pack.zip" | cut -f1) · sha256 $(sha256sum "$OUT_DIR/runtime_pack.zip" | cut -c1-16)…"
ls -la "$OUT_DIR"
