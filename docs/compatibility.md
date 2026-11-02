# Game data compatibility

The download contains the Apple Silicon application and open-source runtime.
It does not contain the original game, its Windows executable, music, movies,
textures, tracks, or other retail assets. Import your own installation or installer.

## Supported import routes

| Source | Status | What to select |
| --- | --- | --- |
| GOG Windows offline installer `setup_carmageddon2_2.1.0.28.exe` | Tested locally | The installer, with any accompanying installer parts in the same folder. The importer extracts it without executing Windows setup. |
| Installed GOG Windows game | Tested locally | The folder containing `CARMA2_HW.EXE`, `3DFX_WIN.BDD`, and `DATA`. |
| The same Windows game installed on a Mac through Wine, CrossOver, or Highball | Same PC data format | Select the actual game folder inside the bottle, rather than the bottle launcher. |
| The earlier self-contained macOS application from this project | Migration route | Select that `.app`. Its existing data package is imported into the separate writable data folder. |
| Manually copied original files | Supported import workflow | Use **Open Import Folder**, add the original installation files, then choose **Check Import Folder**. |
| An already prepared data package | Supported validation workflow | Put the complete generated package, including its manifest and every numbered part, in **GameData**. |
| Other PC retail, Steam, regional, or modified editions | Not fully verified | They must contain a compatible Windows hardware executable. A similar filename does not prove compatibility. |
| Original Classic Mac-only retail disc or installation | **Not supported by this release** | The Classic Mac executable is not a replacement for the required PC executable. Asset compatibility has not been validated. |

The Mac import routes above describe where the files are stored. They do not
turn a Classic Mac-only edition into the supported Windows edition.

## Required executable and files

This application is a native arm64 macOS host around an x86-to-WebAssembly
runtime. The runtime starts the original Windows hardware executable and
implements the Windows/Glide services it needs. It is not a complete native
reimplementation of the game's engine.

The fully tested local executable is:

```text
CARMA2_HW.EXE
2,680,320 bytes
SHA-256 9b896c2cbb170c01b3e9f904ce5e1808db29fe5b51184a5d55a6d19b1799b58d
GOG offline installer 2.1.0.28
```

The upstream data packer also recognizes SHA-256
`698c2b11865578b6ea2a77324fbc1840080841a8ae4041e9ca14ca5ff027bd6c`
(2,674,688 bytes). Recognition by the upstream packer is not a claim that the
complete macOS package and every local rendering/movement repair were tested
with that edition. The importer should report compatibility rather than silently
treating every `CARMA2_HW.EXE` as equivalent.

The PC layout must include `3DFX_WIN.BDD` and nonempty `DATA/COMMON`, `DATA/CARS`,
`DATA/RACES`, `DATA/INTRFACE`, and `DATA/SOUND` folders, together with the other
original installation files. Preserve the original directory structure. Filename
case is handled by the importer/runtime; missing content is not reconstructed.

## Music and movies

CD music is optional and separate from the engine. The supported digital layout
uses `music/Track02.ogg` through `Track08.ogg`; MP3 or WAV tracks with the same
numbering can also be imported. A folder copy cannot recreate CD-audio tracks that
were never copied from the original disc.

The bundled converter is a minimal arm64 FFmpeg build. It decodes the original
Smacker movies locally and encodes H.264 through Apple's VideoToolbox with AAC
audio for the native movie player. The original movies are supplied by the user's
installation, not by the project. The source and exact build settings for the
converter are provided with the dependency-source release asset.

## Multiplayer compatibility

Each player needs their own compatible game data. Players must use compatible
game versions, tracks, and modifications. Network transport and relay checks do
not certify every game type, map, mod, or connection condition. See the multiplayer
guide and release test report for the checks actually performed for this release.

## Why Classic Mac-only media is different

The current loader explicitly opens `/carma2/carma2_HW.exe` and parses a Windows
PE image, including its sections and imported APIs. Rendering and movement fixes
also use byte-checked addresses in that supported executable. Original Classic
Mac software cannot be substituted for that file. No original Classic Mac retail
installation was available for validation of its data layout, byte order, media
extraction, or assets, so this release makes no Classic Mac-only compatibility
claim.

Implementation references: [runtime loader](../runtime/src/emu_main.c),
[PE loader](../runtime/src/emu_core.c), and
[upstream-format data packer](../runtime/tools/make_data.py).

## Open-source dependency references

- [innoextract 1.9](https://github.com/dscharrer/innoextract/tree/1.9): extracts
  Inno Setup/GOG installers without running their installation scripts; zlib license.
- [FFmpeg](https://ffmpeg.org/): the distributed minimal converter is configured
  under LGPL-2.1-or-later and does not use libx264 or other GPL-only codecs.
- Exact source URLs, checksums, license texts, and build commands are recorded in
  [`tools/dependencies`](../tools/dependencies/).
