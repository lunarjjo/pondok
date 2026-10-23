# Third-Party Notices

This project's own code is MIT (see LICENSE). Components below are either
downloaded at setup time (never committed) or planned to be bundled as
native libraries from milestone M2 onward. Versions are pinned at adoption
time and recorded here.

## Downloaded at setup (never bundled, never committed)

| Component | License | Source |
|---|---|---|
| Minecraft Bedrock Dedicated Server | Minecraft EULA (proprietary, free) | minecraft.net/bedrockdedicatedserver |
| playit.gg agent (linux-aarch64) | proprietary freeware binary | github.com/playit-cloud/playit-agent releases |
| Debian minimal arm64 rootfs (proot profile only) | DFSG-free | Debian official images |

## Planned bundled native libraries (M2)

| Component | License | Obligation planned |
|---|---|---|
| Box64 | LGPL-2.1 (libs) / per-component | source link + license text in-app |
| proot | GPL-2.0+ | source link + license text in-app |

Bundling ships them as `lib/arm64-v8a/libpondok_*.so` inside the APK; the
license texts and exact pinned versions/builds will be listed here at
adoption time, and shown in the in-app About screen.

## Flutter / Dart packages

Flutter (BSD-3), provider (MIT), path_provider (BSD-3),
shared_preferences (BSD-3), intl (BSD-3), test (BSD-3),
flutter_lints (BSD-3). `pondok_core` itself has **zero** external
dependencies.
