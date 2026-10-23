#!/usr/bin/env python3
"""Local discriminator: REAL BDS x86_64 (native, NO box64) under proot.

If 'Waiting for Minecraft services...' still fails after 60 s under plain
proot → proot itself breaks the online-mode services connection, and the
CI arm64 failure is NOT a box64 problem. If it connects → the problem is
specific to the box64+proot combination."""
import os
import shutil
import subprocess
import sys
import tarfile
import threading
import time
import urllib.request

CACHE = "/home/z/my-project/.cache"
PROOT = f"{CACHE}/proot_test"            # official v5.5.0 x86_64 static
ROOTFS = f"{CACHE}/proot_rootfs_amd64"
UB = f"{CACHE}/ubuntu-base-24.04.5-base-amd64.tar.gz"
UB_URL = "https://cdimage.ubuntu.com/ubuntu-base/releases/24.04/release/ubuntu-base-24.04.5-base-amd64.tar.gz"
SERVER = "/home/z/my-project/scripts/bds_probe"   # already extracted, world created

# Managed defaults under test: transport=raknet (ping path) AND
# online-mode=false — plain proot provably breaks the online-mode services
# connection (this script, SERVICES_FAILED verdict), and for a LAN phone
# server offline mode + allowlist is the right default anyway.
with open(f"{SERVER}/server.properties", "w") as f:
    f.write("transport=raknet\nonline-mode=false\n"
            "allow-list=false\nmotd=proot discriminator\n")

if not os.path.exists(UB):
    print("downloading ubuntu-base amd64...")
    urllib.request.urlretrieve(UB_URL, UB)

if not os.path.exists(f"{ROOTFS}/bin/sh"):
    shutil.rmtree(ROOTFS, ignore_errors=True)
    os.makedirs(ROOTFS)
    with tarfile.open(UB) as tf:
        tf.extractall(ROOTFS)

cmd = [
    PROOT, "-R", ROOTFS,
    "-b", f"{SERVER}:/srv/server",
    "-w", "/srv/server",
    "/bin/sh", "-c",
    "mkdir -p /tmp 2>/dev/null; export HOME=/tmp PATH=/usr/bin:/bin "
    "LD_LIBRARY_PATH=.; exec ./bedrock_server",
]
print("launch:", " ".join(cmd[:8]), "...")
proc = subprocess.Popen(cmd, cwd="/tmp", stdin=subprocess.PIPE,
                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
lines = []
def reader():
    for raw in iter(proc.stdout.readline, b""):
        l = raw.decode("utf-8", "replace").rstrip()
        lines.append(l)
        print("  srv|", l, flush=True)
threading.Thread(target=reader, daemon=True).start()

t0 = time.time()
verdict = None
while time.time() - t0 < 150:
    joined = "\n".join(lines[-60:])
    if "Server started." in joined:
        verdict = "STARTED"
        break
    if "Could not connect to Minecraft services" in joined:
        verdict = "SERVICES_FAILED"
        break
    if proc.poll() is not None:
        verdict = f"DIED exit={proc.returncode}"
        break
    time.sleep(0.5)

print(f"\nVERDICT: {verdict} ({time.time()-t0:.1f}s)")

if verdict == "STARTED":
    # Does the RakNet ping responder answer through plain proot?
    import socket, struct
    time.sleep(2)
    MAGIC = bytes.fromhex("00ffff00fefefefefdfdfdfd12345678")
    pkt = (b"\x01" + struct.pack(">q", int(time.time() * 1000)) + MAGIC
           + struct.pack(">q", 0x1111222233334444))
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(4)
    pong = None
    try:
        s.sendto(pkt, ("127.0.0.1", 19132))
        data, _ = s.recvfrom(4096)
        if data[0] == 0x1C:
            slen = struct.unpack(">H", data[33:35])[0]
            pong = data[35:35 + slen].decode("utf-8", "replace")
    except OSError as e:
        pong = f"ERR {e}"
    finally:
        s.close()
    print(f"PONG-under-proot: {pong!r}")
    proc.stdin.write(b"stop\n")
    proc.stdin.flush()
    print("stop exit:", proc.wait(timeout=60))
    sys.exit(0 if isinstance(pong, str) and pong.startswith("MCPE") else 1)
else:
    proc.kill()
    sys.exit(1)
