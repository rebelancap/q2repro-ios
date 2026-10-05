# Installing Quake II (q2repro) on Apple Vision Pro

This is an iOS and visionOS build of [q2repro](https://github.com/Paril/q2repro), Paril's Q2PRO fork with Quake II re-release support, rendering natively on Metal via ANGLE. On Apple Vision Pro it plays in a freely resizable 2D window, in a stereoscopic 3D mode on a world-locked panel in your room, and in a VR mode where you step inside the level and aim with your hands.

## What you need

- Apple Vision Pro on visionOS 26 or later
- Your own Quake II game files
- For the prebuilt app: SideStore on the headset, installed with [iloader](https://github.com/rebelancap/iloader/releases#release-visionos)
- To build from source: macOS with Xcode, plus `xcodegen` and `cmake` (`brew install xcodegen cmake`). `scripts/bootstrap.sh` also lists meson/ninja and nasm for the FFmpeg build.

## Your game files

Neither this repository nor the app contains any game content. You must own Quake II and provide your own files. Add them at first launch, or later in the Files app under *On My Vision Pro → q2repro* by picking your game folder. Use one of these:

- **Quake II (2023 re-release)** from Steam or GOG: pick the `rerelease` folder (containing `baseq2` + `Q2Game.kpf`). Recommended, especially for the 3D mode: you get the expansions as episodes, the high-detail models and the full soundtrack.
- **Original Quake II**: a classic `baseq2` folder (`pak0.pak` and friends).

If both are present, the re-release wins. Classic mods go in their own folders and appear in the in-game **Mods** menu. Action Quake II is built into the app: drop in your `action` folder and launch it from Mods. Settings and saves live in a separate `profile` folder, so you can swap data sets without losing them.

## Install the prebuilt app

1. Install SideStore on the headset with [iloader](https://github.com/rebelancap/iloader/releases#release-visionos). SideStore and AltStore can't be installed on visionOS the usual way; iloader is what gets SideStore there. No Xcode or Dev Strap is required.
2. In SideStore, go to *Sources → +* and paste this source, then install Quake II (listed as **q2repro**):

   ```
   https://raw.githubusercontent.com/rebelancap/quake-ports/main/apps-visionos.json
   ```

   The app updates from this source when new versions ship. The source also carries Quake (vkQuake) and Quake III.

To install by hand instead, download `q2repro-*-visionOS.ipa` from the [latest release](https://github.com/rebelancap/q2repro-ios/releases/latest) and install it through SideStore or AltStore.

## Build from source

From a checkout of this repo:

```sh
scripts/bootstrap.sh             # vendor q2repro @ pin + overlay + deps + project (once)
scripts/build-angle-visionos.sh  # visionOS dependencies (once)
scripts/build-ffmpeg-visionos.sh
scripts/build-curl-visionos.sh
scripts/build-visionos.sh        # the merged 2D + 3D visionOS app
```

`scripts/build-visionos.sh --install` also installs and launches the app on a connected Apple Vision Pro. The script passes a `DEVELOPMENT_TEAM` value on its `xcodebuild` line; change it to your own Apple Developer team ID before building.

Upstream q2repro is vendored unmodified and pinned by commit. Every local change is a patch in `overlay/patches/`, applied by `scripts/apply-overlay.sh`. The iPhone build steps are in [Building from source](README.md#building-from-source).

## Notes

- In VR: hand-tracked aiming and weapon wheel, a HUD floating around you (size, height and spread are adjustable), snap or smooth turn, head- or hand-relative movement, controller haptics, and a Render Quality slider that trades sharpness for frame rate.
- With re-release data, the expansions are under *Game → Singleplayer → Campaigns & Expansions*.
- Apps sideloaded with a free Apple account expire after 7 days (paid developer accounts last a year). SideStore refreshes them in the background; if the app stops launching, open SideStore and let it re-sign.
- QUAKE II is © id Software. Licensed under the GNU GPL v2 (see `LICENSE`), matching upstream Q2PRO.
