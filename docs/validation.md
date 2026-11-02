# Release validation: 2.0.0-beta.1

Validated on an Apple M1 Ultra Mac, macOS 27.2. This records bounded local tests,
not a complete campaign, every retail edition, or a long-duration Internet test.

## Data import

The actual owned GOG 2.1.0.28 installer was extracted by the bundled native
innoextract, packed by the native importer, and independently validated:
2,020 files, seven music tracks, two converted movies, no import warnings.
The original Windows installer was never executed.

The existing 1.3 Mac app was imported separately: 2,037 packed files, seven
music tracks, both movies, no warnings. Its selected JavaScript loader was
parsed as metadata and regenerated from the trusted bundled template, not executed.

Both prepared packages pass the final helper's complete part checksums, engine
hash, trusted-loader comparison and media confinement checks. Six synthetic
negative-path checks cover missing data, unsupported engines, preservation of an
existing destination, direct/aliased path overlap, and legacy path traversal.

Both complete original Smacker movies converted using the minimal native FFmpeg.
AVFoundation confirmed playable H.264/AAC tracks, correct duration and an actual
decoded frame. Helper architecture, system-only linkage and neutral build paths
were checked. No Homebrew dynamic libraries are shipped.

## Native host

An actual data-free arm64 app plus external prepared data reached the original
Nice Beaver race in WebKit. The English setup was inspected visually. A fresh
first-run import used the same DataSetup entry point as the picker/drop action,
then independently validated the result and started the local server and engine.

The race sample reported GL error0, both motion-repair APIs available/active,
pedestrian ownership and traffic restoration counters advancing without restore
errors, and the expected semantic foliage materials. Native save flush and
normal quit passed. The runtime's actual `js_net_open` connected to the native
Swift relay through the app's CSP/ATS policy.

The native test window was occluded during this sample. Functional callbacks
were advanced by an external test harness; **no new native display-FPS
benchmark is claimed**. No frame-pump or clock modification is part of the
published runtime. Earlier 1.3 fixes and their measurements remain documented
in `runtime/README-MAC.txt`.

## Multiplayer

Eight real WebSocket protocol checks covered broadcast, sender exclusion,
unicast, room isolation, ping/pong, fragmentation, message bounds and duplicate
node handling. Settings validation covered sixteen valid/invalid relay and CSP cases.

Two actual isolated game clients used the native Swift relay. The guest found
and joined the host, both became ready, and both entered a New Sumo network race
with two players. Driving the host's car propagated its position to the guest
within0.0072 game units in the sampled comparison, without interpreter/JIT faults.
See `tests/multiplayer-verification.json` for the bounded results.

This is not a test of two physical Macs, every game mode, router forwarding,
or Internet latency. No hosted public relay is provided.

## Compatibility boundary

No Classic Mac disc/image was available. The engine parses and runs a supported
Windows PE executable; a Classic Mac-only PowerPC edition cannot boot it.
The public compatibility matrix makes this explicit. Mac-resident PC folders
and earlier compatible Mac wrappers are separate, supported import routes.

## Distribution

The public app and source are audited to exclude retail executables, BDD/TWT
archives, original music/movies, data parts and personal build paths. The icon
is original abstract artwork generated from source. Runtime source remains GPL;
the helper licenses and exact corresponding FFmpeg source are distributed separately.
The app is ad-hoc signed. The installer is unsigned, and neither is notarized.
