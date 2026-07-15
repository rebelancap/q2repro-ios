# ANGLE (ES on Metal) — prebuilt iOS device frameworks (RESERVE substrate)

Built from ANGLE 2.1.1 for iOS arm64, Metal backend, during the Phase 0.4 substrate
spike. **Not used by the current port** (D3 chose native EAGL ES 3.0 + CPU-skinning
MD5, because ANGLE-Metal caps at ES 3.0 with no SSBO — see docs/substrate.md and
artifacts/angle-metal-caps.txt). Kept as a proven drop-in reserve.

Rebuild (re-clones depot_tools + fetches ANGLE, ~16 GB, ~an hour):
  scripts/build-angle-ios.sh device
