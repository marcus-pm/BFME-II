# BFME II for macOS

A macOS app (`BFME II.app`, shipped as a DMG) that runs **your own copy** of
*The Lord of the Rings: The Battle for Middle-earth II* and *The Rise of the
Witch-king* on Intel and Apple Silicon Macs.

It is a Wine wrapper, not a port: the app bundles a Wine runtime
([Gcenx macOS Wine builds](https://github.com/Gcenx/macOS_Wine_builds)) and a
launcher that sets up a dedicated Windows prefix with the fixes this game
needs. **No game files are included or downloaded.**

## Why not a native port?

The game is closed-source; EA has not released its code (unlike C&C
Generals). A native port would mean reimplementing the SAGE engine —
[OpenSAGE](https://github.com/OpenSAGE/OpenSAGE) has worked on that for years
and BFME II is still not playable there. Running the original Windows binary
through Wine is the only route that produces a playable game today.

## Install & use

Download the DMG from the
[Actions artifacts](../../actions/workflows/build-dmg.yml) or a
[release](../../releases), then follow [`docs/READ ME FIRST.txt`](docs/READ%20ME%20FIRST.txt)
(also inside the DMG).

Launcher options (`"/Applications/BFME II.app/Contents/MacOS/BFME2" <option>`):

| Option       | Does                                                         |
|--------------|--------------------------------------------------------------|
| *(none)*     | First run: guided setup. Afterwards: launch the game.        |
| `--menu`     | Play / switch game / resolution / setup / winecfg / logs / reset |
| `--setup`    | Re-run guided setup                                          |
| `--winecfg`  | Wine configuration for the game prefix                      |
| `--reset`    | Delete the prefix and config                                 |
| `--selftest` | Headless prefix + registry check (used by CI)               |

What the setup does:

- creates a Windows 7 prefix in `~/Library/Application Support/BFME2-macOS/prefix`
  (VideoMemorySize 2048, CSMT on, Option key as Alt);
- imports the game from an installed folder, an installer, or a disc image;
- writes the registry keys the game reads (`InstallPath`, `Language`,
  `UserDataLeafName`, `Version`, `MapPackVersion`, and your CD key under
  `ergc` only if you enter it);
- seeds `Options.ini` with a resolution Wine can display (a missing or bad
  one crashes the game on start) and launches with `-xres/-yres` (plus `-win`
  for windowed).

## Building

On macOS (needs Xcode command line tools):

```sh
scripts/build-app.sh build          # downloads Wine, assembles + ad-hoc signs the .app
scripts/make-dmg.sh  build          # build/BFME-II-macOS-<version>.dmg
```

`WINE_FLAVOR=staging|devel|stable` or `WINE_URL=<tarball>` picks the Wine
build. CI (`.github/workflows/build-dmg.yml`) lints, builds on `macos-14`,
runs `--selftest` (real Wine prefix creation under Rosetta) and uploads the
DMG; pushing a `v*` tag publishes a release.

## Known limitations

- **Not notarized.** No Apple Developer ID, so Gatekeeper blocks first launch;
  clear the quarantine flag as described in the DMG's read-me.
- **Disc DRM (SecuROM) does not work under Wine.** You need a DRM-free install.
- **Online play**: the official servers are gone. Community LAN/online tools
  (e.g. GameRanger-style or T3A:Online) are not integrated.
- **Untested with real game data in CI.** CI proves the Wine runtime, prefix
  and registry setup work on macOS; whether a given game version renders
  correctly depends on Wine's D3D9-over-OpenGL path on your Mac. Report
  issues with `~/Library/Logs/BFME2-macOS/wine.log`.
