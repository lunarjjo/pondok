#!/usr/bin/env bash
# ==========================================================================
# pondok · runtime stack verification on REAL arm64 hardware.
#
# Unpacks the built runtime_pack.zip into the SAME directory layout the
# Android installer produces, then drives the full translated stack:
#
#   proot (static) → ubuntu rootfs → box64 (dynarec) → bedrock_server (x86_64)
#
# Two modes, sequential:
#   1. "direct" — box64 + bedrock_server straight on the host (diagnostic;
#      isolates the emulation layer). Non-blocking for the verdict.
#   2. "proot"  — the exact shipped launch path. MUST pass.
#
# Usage: tools/test_runtime_stack.sh <pack_dir>   (arm64 host required)
# ==========================================================================
set -euo pipefail

PACK_DIR="${1:?usage: test_runtime_stack.sh <pack_dir containing runtime_pack.zip>}"
HERE="$(cd "$(dirname "$0")" && pwd)"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

[ "$(uname -m)" = "aarch64" ] || { echo "FATAL: arm64 host required" >&2; exit 1; }
[ -f "$PACK_DIR/runtime_pack.zip" ] || { echo "FATAL: $PACK_DIR/runtime_pack.zip missing" >&2; exit 1; }

# --- unpack pack into the app-like layout ---------------------------------
mkdir -p "$STAGE/pack" "$STAGE/runtime/rootfs" "$STAGE/server"
unzip -q "$PACK_DIR/runtime_pack.zip" -d "$STAGE/pack"

echo "== member integrity (manifest sha256) =="
python3 - "$STAGE/pack" <<'PYEOF'
import hashlib, json, os, sys
pack = sys.argv[1]
m = json.load(open(f"{pack}/manifest.json"))
ok = True
for name, info in m["members"].items():
    h = hashlib.sha256()
    with open(f"{pack}/{name}", "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    match = h.hexdigest() == info["sha256"]
    size = os.path.getsize(f"{pack}/{name}")
    print(f"  {'OK ' if match and size == info['size'] else 'BAD'} {name} "
          f"({size / 1e6:.1f} MB)")
    ok = ok and match and size == info["size"]
sys.exit(0 if ok else 1)
PYEOF

tar -xf "$STAGE/pack/rootfs.tar" -C "$STAGE/runtime/rootfs"
unzip -q "$STAGE/pack/bds.zip" -d "$STAGE/server"
install -m 0755 "$STAGE/pack/proot" "$STAGE/runtime/proot"
chmod +x "$STAGE/server/bedrock_server"

# Product-managed default, applied identically by the app installer:
#   transport=raknet — the 1.26.x default (nethernet) is signaling-service
#     based, never answers LAN unconnected pings, and its services
#     dependency can kill the server at boot.
#   online-mode=false — VERIFIED locally (proot discriminator script):
#     plain proot breaks the online-mode Minecraft-services connection
#     (60 s timeout then the server STOPS ITSELF). Offline mode + open
#     allowlist is the correct default for a LAN phone server anyway
#     (vanilla LAN behavior); M3 will surface the security toggles.
sed -i -e 's/^transport=nethernet/transport=raknet/' \
       -e 's/^online-mode=true/online-mode=false/' \
       -e 's/^allow-list=true/allow-list=false/' \
       "$STAGE/server/server.properties"
echo "managed properties:"
grep -E '^transport=|^online-mode=|^allow-list=' "$STAGE/server/server.properties"

# Diagnostics: prove DNS + resolution work INSIDE the proot rootfs on this
# host before blaming the server. The 'Minecraft services' check failing
# under proot while succeeding in direct mode points here.
echo "== proot environment diagnostics =="
"$STAGE/runtime/proot" -R "$STAGE/runtime/rootfs" /bin/sh -c '
  echo "-- resolv.conf:"; cat /etc/resolv.conf 2>&1
  echo "-- gai.conf (precedence):"; grep -v "^#" /etc/gai.conf 2>/dev/null | head -5 || echo "(default RFC3484)"
  echo "-- resolve www.minecraft.net:"; getent hosts www.minecraft.net 2>&1 | head -2 || echo "getent FAILED"
  echo "-- resolve login.live.com:"; getent hosts login.live.com 2>&1 | head -2 || echo "getent FAILED"
' || echo "!! proot diagnostics themselves failed rc=$?"

echo "== layout =="
ls "$STAGE/runtime/rootfs/opt/box64/"
ls "$STAGE/server/" | head -8

# --- mode 1: direct (diagnostic) ------------------------------------------
echo
echo "######## MODE 1: direct (box64 without proot — diagnostic) ########"
python3 "$HERE/stack_supervisor.py" "$STAGE" direct \
  || echo "!! direct mode reported issues — diagnostic only, NOT gating"

# --- mode 2: proot (the shipped path — MUST pass) --------------------------
echo
echo "######## MODE 2: proot (the shipped stack — gating) ########"
python3 "$HERE/stack_supervisor.py" "$STAGE" proot

echo
echo "STACK VERIFICATION: GREEN"
