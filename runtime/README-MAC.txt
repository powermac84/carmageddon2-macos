Carmageddon II local Mac runtime build 1.3, 2026-11-01

Upstream source:
https://github.com/Carter54git/carmageddon-2-ported-to-web
Commit: eaf6994309b2f23b1ef7a146605c5fa430bba713
License: GPL-3.0, see LICENSE.

Local changes:
- Implement the Unicode CompareStringW API needed by the user's GOG executable.
- Use decoded WebAudio buffer music in WebKit (or ?webaudiomusic=1) to avoid
  an AVFoundation track-switch deadlock. Cache at most two decoded tracks.
- Recognize that executable's checksum in the data packer.
- Save timestamps use the real local date (yyyy-MM-dd) and 24-hour time
  (HH:mm:ss), with Win32 buffer-size queries and insufficient-buffer errors.
- Export emu_js_release_inputs to clear all held keyboard and mouse state
  when the native host loses focus.
- Correct Glide chroma-key comparison: compare the selected source color at
  24-bit precision before lighting, rather than the darkened RGB565 result.
- Stabilize crossed foliage planes: use alpha-to-coverage with depth writes
  when MSAA is active, and a 0.5 alpha cutout with depth writes at MSAA 0.
  Only two-sided leaf materials from the 17 original TreeSurgery model names
  qualify. Material pixelmaps are matched to decoded GL textures by dimensions
  and two independent 32-bit content checks; recycled texture IDs are ignored.
  Ordinary blending remains active for HUD, glass, particles and tree bark.
  Classification runs at most three times during the first three seconds of
  each Root/Track/Race generation. No periodic scene scans run afterwards.
  Module.getFoliageRendering() reports enabled/mode/materials/draws/registryScans;
  Module.setFoliageRendering(bool) can disable this renderer repair for comparison.
- Live graphics API: Module.setGraphicsQuality({scale,msaa,anisotropy}) queues
  a safe framebuffer change; Module.getGraphicsQuality() reports actual
  settings and supported MSAA/anisotropy. Scale 1..4 is supported. MSAA is
  clamped to the common color/depth support of the current GPU. Settings are
  restored from localStorage unless explicit URL parameters override them.
- Browser JIT compilation runs asynchronously with at most four compilations
  in flight; cache prewarming is limited to about 1 ms per frame. Periodic
  JIT-cache serialization is scheduled outside the game frame callback.
- Module.flushGameStorage() serializes IndexedDB syncs. Converted PIX caches
  are mirrored immediately in memory, then committed with settings/saves or
  normal app termination instead of scheduling their own post-load batch.
- Traffic presentation repair: copy the complete AI-calculated 48-byte matrix
  of eligible controlled road-car drones before PHIL physics resets them to
  the last physics snapshot. Use that matrix only during the original render
  call, then restore the original matrix byte-for-byte. No opponent-racer,
  player-car, velocity, clock, path-state or collision updates are changed.
- Pedestrian repair retains the animation-owned passive root after PHIL resets
  it while independent body actors keep their animation pose. This intentionally
  corrects the canonical actor position and its next AI/collision starting point.
  It does not write clocks, velocities, omega or cached physics transforms.
  Eligible living walking/running/panicking characters require unchanged retail
  owner/type/queue, slots, HP/action/move, collision flag and body matrices.
  Physical, dead, morphing and detached states retain their original behavior.
  A 40 ms exponential visual translation filter then uses this consistent root;
  its temporary offsets are restored after rendering. This time constant is
  not a hard upper bound on visual delay. OFF restores original future handling,
  without undoing distance already travelled while the repair was enabled.
- The native Mac host starts both presentation features enabled when no user
  preference exists. Existing explicit false choices remain false. The raw
  runtime APIs start disabled until the host applies its preferences, or
  debug URLs explicitly request npcvisual=1 / trafficvisual=1.
  Module.getPedestrianSmoothing(), Module.setPedestrianSmoothing(bool),
  Module.getTrafficSmoothing() and Module.setTrafficSmoothing(bool) expose
  independent requested/enabled/available/active/pendingRestore state, explicit
  safetyDisabled/safetyReason and cumulative diagnostic counters. Pedestrian
  availability requires both byte-verified hooks, even with Traffic switched OFF.
  An explicit manual retry can clear a safety latch; errors remain cumulative.
- Record the bounded validation in docs/GAME_FILES.md.
- Optional ?nativevideo=1 hook pauses the interpreter on SmackOpen, asks the
  nativeVideo WebKit bridge to play the allowlisted mix_intr/toprank movie,
  and resumes after window.__finishNativeVideo(). The native host supplies
  video/mix_intr.mp4 and video/toprank.mp4 converted from the user's SMK files.
  Each movie is requested at most once per session, including Smacker retries.

Build the WebAssembly runtime using Emscripten 3.1.50:
  source /path/to/emsdk/emsdk_env.sh
  ./build.sh
  python3 tools/make_data.py "/path/to/Carmageddon 2" dist/site --music "/path/to/Carmageddon 2/music"

No game assets are included in this source archive. The user's local app uses
their own game assets and original Windows executable. The game code runs in
an x86-to-WebAssembly runtime; the Mac host is native arm64. This is not a
fully native reimplementation of Carmageddon II's game engine.

Validation:
Chrome headless on the user's Mac: GOG executable entered single-player menu,
loaded Nice Beaver City and responded to acceleration (collision with a wall).
Runtime reported about 60 fps in that sampled race, 1,881 JIT regions, zero
failed JIT regions. WebGL2 context present. Seven CD audio files detected.
This does not certify all missions, network play, audio output or save reload.
The date/time functions were separately checked with 2026-11-01 18:07:09,
size queries, short buffers, custom formatting and an invalid calendar date.

Follow-up graphics validation:
The actual old/new fragment shaders were tested on WebGL2: a non-key green
texel under dark lighting was incorrectly discarded before the fix and stays
opaque afterwards; a genuine black key texel remains transparent.
An isolated Chrome race switched live through 1x/0x MSAA, 2x/2x, 3x/4x,
4x/requested 8x (clamped to the GPU's 4x), then 2x/4x. Every framebuffer was
complete and gl.getError() stayed zero. A warm race sample measured 601 actual
Glide frames in 10.019 seconds (59.986 fps), p95 interval 16.7 ms, maximum
16.8 ms and zero intervals above 40 ms. This does not establish that every
NPC movement or every texture-flicker report is resolved.

1.2 motion verification:
Visible, active road traffic reproduced the reported difference from smooth
race opponents: on 197/197 interpolation transitions a road-car actor stayed
at a stale PHIL pose while its AI position advanced. With the repair enabled,
480 frames in 7.9831 seconds measured about 60.002 fps. All 2 028 captured
AI/render matrices matched; 1 186 translations and 360 rotations differed
from the stale PHIL snapshot. All 1 161 measured active interpolation
transitions moved, with no repeated rendered positions. Disabling while a
restore was pending preserved that restore; 3 022 restores finished with
zero errors and no interpreter faults.
Historical 1.2 pedestrian off/on video samples measured about 59.90 fps, preserved limb
proportions and recorded zero restore errors. A separate 493-frame sample
reduced repeated rendered translation from about 75.7% to 1.65% without
changing canonical game state. The user still reported jumping figures. Those
root counters did not prove a smooth visible body; 1.3 measures independent body
actors and replaces the incorrect root reference. These were bounded samples.

1.3 pedestrian verification:
In 346 baseline frames PHIL reset each observed root 102 times, while Bone1
never changed during those physics calls. Body holds lasted 150.9 to 233.8 ms;
the 1.2 filter added visible backward steps. The ownership comparison applied
2 181 root corrections at 60.12 fps with zero restore errors. Body34 had zero
backward/hold frames instead of 26 backward steps; speed deviation fell from
0.245 to 0.070. A 769-frame lifecycle drive measured 60.03 fps, 6 224 corrections,
zero restore errors/faults and excluded actual hit/fall/getting-up states.
32 panicking frames in a prior drive had the same guarded retail ownership,
including 10 raw resets; the last random drive had no panic frames. A separate
active panic application count is not claimed. Original limb poses remain.
Native integrated host verification is recorded separately in the delivered
test report; these research measurements are not a full campaign test.

1.3 foliage verification:
The user's City Slicker night scene was reproduced (race 2, 1 116 pedestrians).
With the eye fixed, small camera pans changed the painter order of four crossed
CITREE2 leaf triangles whose original lighting differed (76.2 versus 174.4).
Replaying identical original scene geometry and changing only that order caused
31 505 pixels to differ, 8 403 by more than 20 RGB levels (maximum 87). With
identified foliage depth/coverage enabled the two complete-scene renders were
pixel-identical, with no WebGL errors. The recorded original leaf triangles were
also order-invariant in the clean renderer at 2x/MSAA4, 2x/MSAA2 and 4x/MSAA0;
without the repair those same cases changed 35 420, 35 377 and 141 305 pixels.
The clean cold-start race identified both original CITREE2 and CITREE01 leaf
materials. Switching 2x/MSAA4 -> 4x/MSAA0 -> 2x/MSAA2 -> 2x/MSAA4 produced no
GL errors. After swaps alpha-to-coverage was disabled and the normal HUD depth
mask was restored. The registry stopped after three scans. These are bounded
local render checks; they do not certify all levels or eliminate minification
aliasing on fine leaf edges.
