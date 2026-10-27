# Scene verification tools

There are no unit tests in this repository, and a scene renderer is not the kind of thing a unit
test would catch anyway: every bug worth finding here — a keyframe flying a layer off screen, a
shader flooding a wallpaper with flat colour, a particle emitter burying the frame in snow —
shows up as a *picture* being wrong across a library of real Workshop content, not as an
assertion failing on a fixture.

So the check is empirical. Each tool compiles the app's own scene sources and runs them over
every wallpaper installed in `~/Documents/Open Wallpaper Engine`, which means what it measures is
what the wallpaper window draws. Every regression listed in the git log of this subsystem was
caught by one of these three.

```sh
Tools/scenecheck render <outDir> all        # a PNG per scene, plus motion and parallax
Tools/scenecheck effects [dumpDir]          # effect tally and per-shader compile
Tools/scenecheck cost <id> [id ...]         # milliseconds a frame
```

The scenes are built at the default Settings → Quality, which a run can override through the
`UserDefaults` argument domain, appended after the ids: `-SceneEffectsDisabled YES` (Post-Processing
off), `-SceneReflections NO` (Reflections off: drops the 3 `reflection` passes of 1990 Miata, BMW and
Lonely Cat, so `effects` reports 456 compiling shaders instead of 459), `-SceneTextureScale 0.5` (Texture Resolution: High Performance), `-SceneTextureDisplay
2560x1440` (Automatic, for a display of that many pixels). `-SceneScriptDate 2026-10-19T17:30:00`
moves the clock every scene script reads, which is the only way to see a calendar's other days or a
day/night switch's other half — see `SceneScriptRuntime.clockOffset`. `render` and `cost` also read the two
words as ids and report them as unbuildable — ignore those lines; `effects` reads its first
argument as the dump directory, so give it one before the pair. See `SceneQuality.fromDefaults`.

They are not targets in `Open Wallpaper Engine.xcodeproj` on purpose: each links a subset of the
app with its own `main.swift`, and adding them to the app target would break the app build. The
script builds them with `swiftc` into `$TMPDIR` and rebuilds when a source they depend on
changes.

## `render`

Rasterises every scene through `SKRenderer` at its authored resolution and writes a PNG, then
reports three numbers per scene.

`SKRenderer` only draws the node tree onto whatever the render pass already contains — it never
paints `SKScene.backgroundColor` itself. `SKView` does that every frame, so the two only agree if
this tool's render pass clears to the scene's own background colour instead of a fixed one. This
sits beside the other gap between the two renderers, `SKRenderer.update(atTime:)` forwarding only
the first tick to the scene — both are places where `SKRenderer` quietly does less than `SKView`,
and the harness has to make up the difference by hand or the report describes a wallpaper window
that does not exist. Note that the second gap is *not* made up for here for the scene's own
`update(_:)`, only for its emitters — see the notes under the three numbers. Caught on White GTR (R34): a near-white `clearcolor` of `0.996 0.996 0.992`
rendered as a black background and `dom=49%` before this was fixed, against a white preview and a
white real wallpaper; afterwards it renders white and `dom=86%`, which is the scene's actual look,
not a regression.

- **`dom`** — the share of the frame taken by its single most common colour. This is the flat-frame
  alarm: a wallpaper that comes out one colour is the failure mode a broken shader, an
  unmasked tint or a runaway emitter produces, and it is invisible in a summary that only counts
  layers. Above 90% the scene is listed as suspicious. Read the list, don't trust it — dark
  artwork crosses that line legitimately, and six wallpapers in this library always will.
- **`mov`** — how much the frame changes between t=2s and t=7s. Today that is particles alone; see
  below for why it is not the keyframe evaluator.
- **`parallax`** — how much it changes when the cursor moves from one side to the other, with every
  emitter hidden. Should be non-zero for exactly the scenes whose author switched
  `general.cameraparallax` on.

The base frame — the PNG, and the frame `dom` is read from — is taken at t=2s with each emitter's
own simulation run forward to that point, not at t=0. At t=0 an emitter holds nothing yet, and what
a first tick shows is newborn particles sitting at keyframe 0 of their `alphafade` sequence, which
is alpha 0: a frame measured there is the scene with its particle layers missing.

**Before this harness ran emitters by hand, it had never drawn a particle older than one tick.** It ticked
`SKRenderer.update(atTime:)` in 1/15 s steps up to the probe's time, and any `update(atTime:)` with
a time above zero leaves `SKRenderer` drawing no particles at all — measured on a bare scene with
one emitter, the loop to 2 s rendered 0 lit pixels (what a t=0 frame showed was the handful born
on the first tick, invisible under `alphafade`) where `advanceSimulationTime(2)` and a single
`update(atTime: 0)` rendered 856, in the right place. So `mov` was never "particles and
`SKAction`s" as this file used to say; there are no `SKAction`s in a built scene, and on the 29
scenes the particle-motion fix was checked against it read 0.00–0.86 with the old loop and
0.22–43 once emitters were run by hand. Every earlier particle change in the git log was invisible
to this tool, and a report of `alphafade` "pinning alpha at 0" is what that blindness looks like
from outside. `render()` now ticks the scene once at t=0 and calls
`SKEmitterNode.advanceSimulationTime(_:)` on every emitter in the tree.

The parallax probe hides emitters because it compares two separately built scenes, and two builds
never lay their particles down in the same place (see the next section): with them visible, every
emitter scene reports cursor parallax that is really two different random draws.

Compare runs by diffing the report and by diffing the PNGs; the author's own `preview.jpg` in each
wallpaper directory is the ground truth worth checking a changed scene against.

Two things to know before reading a diff of this report, both of which make it say less than it
looks like it says:

- **Two runs of the same binary do not agree on a scene with an emitter.** `SKEmitterNode` seeds
  itself, so every emitter lays its particles down somewhere new each run and every number read
  off the pixels moves with them. Three consecutive runs over an unchanged build gave The Batman
  `dom` 26/27/28% and `mov` 2.31/2.62/1.79; another pair put Dark Magic at 39.64 and then 26.98.
  Scenes without an emitter repeat to the digit. So on a scene that emits, a couple of points of
  `dom` or a third of the `mov` is not evidence of anything — run the *unchanged* build twice and
  see how far it drifts on its own before blaming the diff. `nodos` is stable regardless, which is
  why a dropped layer still shows up honestly. So is `emis`, the count of every `SKEmitterNode`
  in the tree. It exists because `nodos` counts top-level layers only, one per scene object, and
  a particle system's child systems are emitters *inside* the parent layer's holder: adding the
  46 drawable static children moved `emis` on exactly the 20 scenes that carry them and `nodos`
  on none.
- **`render` does not advance the keyframe evaluator, so `mov` has never measured one.** It calls
  `SKRenderer.update(atTime:)` once, at t=0, and that is the only tick the scene would get anyway — the
  trap CLAUDE.md documents, which `scene-cost` works around by calling
  `(scene as? WallpaperSKScene)?.update(_:)` by hand and this tool simply never did. `mov` is
  therefore measuring particles alone. Adding that one call beside the existing
  `renderer.update` fixes it: Mitsubishi Lancer X goes from `mov=0.00` to `mov=76.74`, and because
  `update(_:)` is idempotent for a given `t`, a result that changes at all is itself the proof the
  call was not happening. Left alone here only because turning it on moves all 94 scenes at once
  and would make this report incomparable with every earlier run in the git log — it wants its own
  change, with its own before and after.

## `effects`

Builds every scene, pulls the `SKShader`s the rasterizer wired up, and compiles each one on its
own with `stderr` captured, so a failure is attributed to its scene instead of vanishing into the
noise at launch. Reports the effect tally per scene — how many passes were translated, how many
were unresolved or untranslatable — and a histogram of what the compiler objected to.

This tool also clears its render pass to black, but it does not have `render`'s clearcolor defect:
each shader is compiled against a throwaway 8×8 scene built fresh for the test, not the wallpaper's
own `SKScene`, and the only thing read back is compiler `stderr`, never a pixel. There is no
scene background here to get wrong.

Pass a directory to have the translated source of every failing shader written there. That is what
turns "46 fail" into four named causes.

## `cost`

Milliseconds a frame, averaged over 40 frames after a warm-up. Note the resolution: this renders
at the scene's *authored* size, usually 4K, while the app's `SKView` renders at the display's — a
1440p screen pays roughly half of what this reports. Use it to compare, not to predict.
Every effect is an offscreen pass, so this is the number that decides whether effects can be on by
default in something that runs all day. Run it against
`-SceneEffectsDisabled YES` to split the cost between the composition and the effect chain.

This tool builds the real project scene, same as `render`, and also clears to black instead of the
scene's `backgroundColor` — but it never reads a pixel back, only the wall-clock time to render 40
frames, and a GPU clear costs the same regardless of colour. So the wrong clear colour does not
skew the number `cost` reports; left as-is.

# Playback rule check: `Tools/audiocheck`

```sh
Tools/audiocheck        # ~45 s, and it makes sound
```

Compiles `Services/OtherAppAudioMonitor.swift`, the detector behind Settings → Playback → *Other
Application Playing Audio*, with its own `main.swift`, and drives it through a fixed script: Ping
through `afplay`, an alert `beep`, a long `say`, an `afplay` attributed to the harness itself, a clip
through an in-process `AVPlayer`, and `stop()` mid-sound. Each transition the monitor reports is
logged with its time; the run passes on exactly three rises and three falls.

The "other application" is spawned with its responsibility disclaimed
(`responsibility_spawnattrs_setdisclaim`), which makes it its own responsible process the way an
app launched from the Dock is. A child spawned normally is attributed to the harness and must be
ignored — that is the shape of a web wallpaper, whose sound plays in WebKit's GPU process. Run
from a terminal, everything else that terminal started counts as the harness's own too, which
is why the script does not simply shell out to `afplay`.

What a run shows (macOS 27.0.1): a rise ~1.05 s after the other process starts output (the
monitor's 1 s settle, so a 0.11 s `beep` does not pause anything — and `systemsoundserverd`,
which plays it, is excluded anyway), and a fall within 0.01 s of a command-line player exiting.
Not in the script because it needs a second app: a paused `AVPlayer` keeps `IsRunningOutput` set
for ~7.4 s, a paused `WKWebView` `<audio>` for ~8.7 s, so in practice the rule releases that long
after the other app goes quiet. Baseline false positives — processes running output while
silent — are listed at the top of each run; on the measuring machine they were four iOS Simulator
audio servers and one simulator app, all excluded.

# Whole-library check: `Tools/appcheck`

```sh
Tools/appcheck                  # every wallpaper: a PASS/FAIL line each, then the tally
Tools/appcheck <id> [id ...]    # just these
```

The three scene tools answer "does this scene look right". This one answers the question that
comes first, "would this wallpaper load at all", and it answers it for all three types, because
video and web wallpapers had no instrument of any kind. You found a broken one by applying it
and looking at the desktop, and on a wallpaper that means a black screen with no error anywhere.
It exits non-zero when anything fails, so it can gate a change the way the scene reports gate a
change to `SceneParsers/`. It is built the same way as `scenecheck`: the app's own sources
compiled with `swiftc` into `$TMPDIR`, not an Xcode target. A run over the installed library takes
about 22 seconds.

Each step goes through the app's own code where the app has code for it. Where it doesn't, the
step asks the system framework that the app hands the job to:

- **Every type.** `project.json` decodes through `WEProject`. `WEProject.renderer`, the same
  property `WallpaperView` now dispatches on, recognises the type. The file it names exists. The
  preview exists and decodes through `NSImage`, which is what the library grid's `NSImageView`
  will do with it.
- **video.** `AVURLAsset` opens it, it has a video track, its duration is positive, and
  `AVAssetImageGenerator` decodes a frame at zero. The codec FourCC and display resolution are
  printed. A codec outside the set every supported Mac can decode is marked with a portability
  warning (`⚠ codec … needs a decoder not every supported Mac has`; `av01` decodes only on M3 and
  later), not a failure: whether it plays *here* is decided by the frame, pulled with the same
  supplemental decoders the app registers at launch. The frame is the decisive test: it is exactly what
  `setPlacehoderWallpaper` asks for, and the first thing an `AVPlayerLayer` would draw.
- **web.** The entry HTML exists, every relative `src`/`href`/`url()` it names resolves to a file
  in the wallpaper, and nothing is root-absolute (`loadFileURL` resolves `/x.js` against the
  filesystem root, not the wallpaper). Remote hosts are listed as notes, not failures, because a
  page that needs the network still works when the network is there.
- **scene.** The package resolves the way `loadScene` resolves it (`<file>.pkg`, else the loose
  JSON), and `SceneWallpaperViewModel` builds a scene with at least one node. A scene that comes
  back as a plain `SKScene` is the 3D fallback and is marked `(3D: preview only)`.

Workshop presets count as SKIP. A preset is a manifest with no `type`, a settings override for
some other item. An entry with no `project.json` is left out and listed under the tally. Both
rules copy `ContentViewModel.allWallpapers`, which hides these entries from the grid, so the tally
counts what the user can actually pick.

## What the first run found

```
=== 154 wallpapers checked: 153 PASS, 1 FAIL, 7 SKIP ===
  (2 entries without a project.json, not listed by the app: 2532575614, 884014929)
  video: 51/52 pass
  web: 9/9 pass
  scene: 93/93 pass
```

- **One real app bug, now fixed: the unsafe-wallpaper gate compared `type` verbatim.**
  `WallpaperView` lowercases `type` before dispatching, but `nextCurrentWallpaper`'s gate tested
  `["web", "application"].contains(type)`. Three of the library's nine web pages declare `"Web"`
  (Customizable Module Visualizer, the WebGL bitcoin ticker, js object - clock). They rendered,
  and they ran their Workshop JavaScript with no warning and no `TrustedWallpapers` entry. The
  same verbatim match in `setPlacehoderWallpaper` skipped the one video that declares `"Video"`
  (Wall of the Abyss), so the menu bar was never tinted for it. Capitalised types are not rare:
  21 of the 154 manifests use one, 17 of them `"Scene"`. All three call sites now ask
  `WEProject.renderer` or `runsUntrustedCode`, and the tool fails any web page those say is not
  gated. With the old comparison put back, the tool fails exactly those three pages; with the fix
  it passes them.
- **One wallpaper that can't be played: Tuner Scene HDR 60 FPS 4K - Cars (2006), `2997998111`.**
  Its `.mp4` carries VP9 (Profile 0, 8-bit, 2560×1080; `ffprobe` agrees with the FourCC).
  AVFoundation has no VP9 decoder for files, so `isPlayable` is false and opening it fails with
  "Cannot Open". The wallpaper window shows black. The app can't fix this without bundling a
  decoder, so it is a content problem. It is recorded here and left failing on purpose: the count
  stays at 1 until the item is re-encoded or removed. Every other video is `avc1`, except one
  `hvc1`.

  *Update, 2026-10:* the app now calls `VTRegisterSupplementalVideoDecoderIfAvailable` for VP9 in
  `applicationWillFinishLaunching`, and `appcheck` makes the same call, so this wallpaper plays and
  passes with the portability warning above. The tally is now
  `154 wallpapers checked: 154 PASS, 0 FAIL, 7 SKIP` (video 52/52). Whether VP9 decodes is still
  per-machine: a Mac without the supplemental decoder would show black.

  *Update, 2026-10-27:* `148 wallpapers checked: 148 PASS, 0 FAIL, 7 SKIP` (video 52/52, web 3/3,
  scene 93/93). The library now holds six fewer web pages; the tally follows the library, not the
  code.
- The two missing manifests are dead symlinks into steamcmd's `workshop/content`, for items that
  are no longer downloaded. Three scenes (Moon, Three-Body problem, Wuhu Island) are 3D and pass
  as preview-only.

The tool was also checked from the other direction, because a clean report means nothing unless
the tool can fail. Ten hand-made broken wallpapers each fail, and each for the reason it was
built to fail:

- an undecodable preview
- a missing preview
- a missing video
- 200 KB of random bytes named `.mp4`
- a page with a missing script and a root-absolute one
- a scene with no package
- a scene whose `.pkg` is random bytes
- an `application` type
- a manifest whose `file` is a number
- a folder with no manifest

Two runs over the library produce byte-identical reports.

Two things to know before trusting a PASS:

- **The first version of this tool checked 32 of 163 entries and reported nothing about the
  rest.** Most of a library is symlinks into steamcmd's download folder, and
  `URLResourceValues.isDirectory` says a symlink is not a directory, so filtering on it silently
  dropped 130 wallpapers. The app's own listing never filtered on it, which is why the app saw
  them. When the checked count changes, compare it against
  `ls ~/Documents/Open\ Wallpaper\ Engine | wc -l`.
- **The remote-host list comes from a text scan, so it only sees addresses written as text.** The
  bitcoin ticker is a live price feed and lists no host, because its endpoint is inside the Unity
  build's compressed `.unityweb` payload. A web PASS means the page's own files are all present,
  not that it works offline.
