# Carmageddon II for Apple Silicon

Play your own copy of **Carmageddon II: Carpocalypse Now!** on an Apple Silicon Mac.
Native Mac controls, an installer and data importer, correct 4:3 window/full-screen
presentation, graphics presets, an FPS display, and LAN multiplayer with a built-in relay.

**Bring your own game. No original executable, game data, music, movies, or game
artwork is included or downloaded.** This is an independent community project.

## Download and install

Download the `.pkg` installer or the portable app `.zip` from
[GitHub Releases](https://github.com/powermac84/carmageddon2-macos/releases).
Requires **Apple Silicon and macOS 14 or newer**. Wine, Rosetta, Python, Node.js,
Homebrew and Xcode are not required to play.

1. Install and open **Carmageddon II for Apple Silicon**.
2. Choose **Choose Installation Folder…** or **Choose GOG Installer…**, and select your own copy.
3. Wait for local extraction, verification and optional movie conversion. Play.

You can also choose **Open Import Folder**, copy your original files there, then
choose **Check Import Folder**. Keep the game's `DATA` hierarchy intact.
Game data is stored separately in `~/Library/Application Support/Carmageddon II/`;
updating the app does not replace it.

Supported import paths:

| Source | Status |
| --- | --- |
| GOG Windows installer `setup_carmageddon2_2.1.0.28.exe` | Full local extraction, music and movies tested. |
| Installed PC/GOG folder with a supported `CARMA2_HW.EXE`, `3DFX_WIN.BDD` and `DATA` | Supported; also works when the folder lives inside Wine, CrossOver or Highball on a Mac. |
| Earlier bundled 1.3 Carmageddon II Mac app | Tested import of its existing packed data, seven music tracks and both movies. |
| Already prepared data from this importer | Validated by manifest, part checksums and known engine hash. |
| Original Classic Mac-only PowerPC media | **Not supported by this engine.** No Classic Mac disc is included or claimed tested. |

See [compatibility](docs/compatibility.md) for exact engine requirements and disk-image limits.
The importer extracts a GOG installer; it never runs the Windows installer.
Missing optional music or movies are reported and do not prevent gameplay.

The installer uses a distinct app name, so it does not overwrite an earlier
`Carmageddon II.app` before you can import it. Run only one version at a time;
the existing bundle identity and local save origin are retained.

This first public release is a **community preview**. The app is ad-hoc signed;
the installer is unsigned. Neither is Apple-notarized. macOS may ask you to approve opening downloaded software;
no global security setting needs to be disabled. The source and build instructions
are available below.

## Graphics and controls

The **Display** menu offers 4:3 Window / Full Screen, FPS, four live graphics
presets, and independent traffic/pedestrian smoothing. The original HUD is preserved.
The foliage fix prevents crossed alpha-blended leaves from flashing between
different brightness levels when the camera turns.

| Control | Action |
| --- | --- |
| Arrow keys | Drive, brake and steer |
| Space | Handbrake |
| Backspace | Repair |
| C | Change camera |
| Tab | Map |
| Command–R | Recover car |
| Control–Command–F or double-click | Toggle full screen |
| Command–Q | Flush local saves and quit |

Career progress is saved by the original game after completed races. The importer's
data backups and the game's persistent saves are separate. Re-importing data does
not erase the browser-origin save store.

## Multiplayer

Use **Multiplayer → Host LAN Relay** on one Mac, or configure the same relay URL
and room on each player. No separate server runtime is required on the hosting Mac.
Then use the original game's **Network Game → Host / Join**, mark players ready,
and start the race. Set your racing nickname in the original **Driver** field;
the launcher's Computer name identifies the network computer.

An actual two-game test covered discovery, joining, readiness, starting a race and
synchronized car movement through the native relay. A native WebKit connectivity
smoke is recorded separately. This does not certify every network mode, remote
Internet latency, or two physical Macs on different networks.

For Internet play, use a reachable self-hosted WebSocket relay. This repository
includes compatible Node/Python server sources and deployment examples; it does
not provide a public relay service. Room names group players but are not passwords.
See [multiplayer setup and protocol](server/README.md).

## How it works

The launcher, importer and relay are native arm64 programs. The **original Windows
game code runs through an x86-to-WebAssembly JIT**, and Glide calls are rendered with
WebGL 2 in the system WebKit. This is not a complete native reimplementation of
the game engine. DLSS, MetalFX and RTX Remix are not integrated in this renderer.

The validated 1.3 fixes are retained, including decoded WebAudio music, native
movie playback, input release on focus loss, foliage depth coverage and passive
pedestrian animation ownership. The latter intentionally repairs the canonical
animation position; only its additional temporary rendering offsets are restored.
See [runtime changes and bounded validation](runtime/README-MAC.txt).

## Build from source

Maintainer requirements: Xcode command-line tools, **Emscripten 3.1.50**, Python 3,
CMake, Ninja and make. Player installations do not need these tools.

```sh
# Build the pinned, native extraction and video helpers.
bash tools/dependencies/build-ffmpeg.sh
bash tools/dependencies/build-innoextract.sh

# With Emscripten 3.1.50 activated:
bash tools/build-app.sh
bash tools/package-release.sh
```

The build contains no original game data. The package is non-relocatable and installs
to `/Applications/Carmageddon II for Apple Silicon.app`. Release signing can be
configured through `C2_CODESIGN_IDENTITY`; notarization is a separate maintainer step.
[Helper sources, exact checksums and licenses](tools/dependencies/README.md) are pinned.
The exact FFmpeg corresponding-source archive is provided alongside the binary release.

## Credits and license

Based on [Carter54git/carmageddon-2-ported-to-web](https://github.com/Carter54git/carmageddon-2-ported-to-web),
commit `eaf6994309b2f23b1ef7a146605c5fa430bba713`, with reverse-engineering reference
from [Link4Electronics/Carpocalypse2](https://github.com/Link4Electronics/Carpocalypse2).
Runtime and launcher: [GPL-3.0-or-later](LICENSE). Bundled helpers retain their
[separate open-source licenses](tools/dependencies/licenses).

Original game © Stainless Software / SCi and the respective rights holders.
Carmageddon names belong to their respective owners. This project is not affiliated
with, endorsed by, or a replacement for purchasing the original game.
