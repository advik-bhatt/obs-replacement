# Upstage

A native macOS studio app for recording and streaming, written to replace OBS
for one job first: take an iPhone Continuity Camera feed (USB or Wi-Fi),
upscale it to 4K with MetalFX, shoot in portrait, and mix every CoreAudio input
on the Mac, including all 16 channels of BlackHole 16ch.

Swift, SwiftUI, AVFoundation, ScreenCaptureKit, Metal + MetalFX, CoreAudio,
VideoToolbox, Network.framework, CoreMIDI. No Electron, no third-party
dependencies, Apple Silicon and Intel (universal binary). Requires macOS 14
Sonoma or newer.

> Status: alpha. v0.1.0 builds as a universal binary on GitHub's macOS
> runner, the core is unit-tested (47 tests, Linux and macOS), and the app
> code has been through an adversarial review pass, but it has not yet been
> run on real hardware (it was written from a Linux session). Expect
> first-run bugs; file them as issues with the status line shown in the
> Sources panel.

## Download

1. Open the latest run of the **build** workflow under *Actions* and download
   the `Upstage-macOS` artifact (a `.dmg` and a `.zip`), or grab the DMG from
   the *Releases* page once a `v*` tag exists.
2. Drag `Upstage.app` to *Applications*.
3. The app is ad-hoc signed (no Apple Developer ID yet), so the first launch
   is blocked by Gatekeeper. Open *System Settings > Privacy & Security*,
   scroll down, and click **Open Anyway** next to the Upstage message, or run:
   ```sh
   xattr -d com.apple.quarantine /Applications/Upstage.app
   ```
4. Grant Camera and Microphone access when asked. Display/window capture and
   desktop audio also need *Screen Recording* permission (macOS prompts on
   first use; the app must then be relaunched).

## What it does

**Sources** (one scene can hold any number, drawn bottom to top):

| Source | Backing API | Notes |
| --- | --- | --- |
| Video Capture Device | AVFoundation | Built-in camera, USB/UVC webcams and capture cards, iPhone as **Continuity Camera** (wired or wireless, same device), wired iPhone/iPad **screen** (CoreMediaIO screen-capture opt-in, same path as QuickTime). Per-source rotation 0/90/180/270, mirror, format/fps pick. |
| Display Capture | ScreenCaptureKit | Native pixel size, cursor toggle, 15–60 fps. |
| Window Capture | ScreenCaptureKit | Captures a window even when covered. |
| Audio Input Capture | CoreAudio AUHAL | Every device Audio MIDI Setup lists, with its real channel count. A **channel routing matrix** maps any device channels to L/R (BlackHole 16ch, interfaces, aggregates). |
| Desktop Audio | ScreenCaptureKit | System audio, excluding Upstage itself. |
| Media Source | AVAssetReader | Video/audio files, loop, restart on scene activation. |
| Image / Text / Color | CoreGraphics | Premultiplied BGRA textures; text with font, outline, alignment. |

**Upscaling to 4K.** Every video source is drawn by a Metal compositor. When
an item is drawn larger than its native pixels, the source texture is first
run through an **MTLFXSpatialScaler** (the hardware path games use), then
composited, so a 1920x1080 Continuity Camera lands on a 3840x2160 canvas at
2x with MetalFX quality while text and images render at native 4K. Lanczos-3
is the fallback on GPUs without MetalFX, and `Settings > Video` lets you pick
MetalFX / Lanczos / bilinear for the canvas → output pass as well.

**Portrait.** Canvas presets include Portrait 4K (2160x3840) and Portrait
1080p (1080x1920). Rotate the camera source 90° when the iPhone is mounted
vertically (a 1920x1080 feed becomes 1080x1920 and fits the portrait canvas
at exactly 2x), or crop a landscape feed to 9:16 in Transform. There is a
*Profile > New Portrait 4K Profile…* shortcut.

**Scenes, studio mode, transitions.** Scene collections with any number of
scenes; cut, fade, fade-to-black and four slides with a duration; studio mode
with preview/program and a Transition button; items can be dragged, corner
scaled, nudged with arrow keys, fitted/filled/stretched/centred, rotated,
cropped, flipped, locked and hidden.

**Filters per source.** Colour correction (brightness, contrast, saturation,
gamma, hue, opacity), chroma key (with spill reduction), luma key, sharpen,
Gaussian blur, crop/pad. Reorderable, toggleable.

**Audio mixer.** 48 kHz stereo mix in 10 ms blocks; per-source fader (OBS's
cubic curve), mute, peak/hold meters, monitoring (off / monitor only / monitor
and output) to any output device, sync offset, six mix tracks. Sources are
heard only while they are in the program scene, like OBS.

**Recording.** MP4 or MOV via AVAssetWriter: hardware H.264 or HEVC (bitrate
or constant quality, keyframe interval), Apple ProRes 422 / 4444 (MOV), AAC
96–320 kbps, fragmented writing so a crash leaves a playable file, pause and
resume, filename templates.

**Streaming.** RTMP and RTMPS to Twitch, YouTube, Facebook, Kick or any custom
ingest. VideoToolbox H.264 (no B-frames, fixed GOP) + AAC, optional separate
stream resolution, automatic reconnect with backoff, drops non-key frames when
the socket backs up, live bitrate/drop stats in the status bar. The RTMP
muxer (handshake, chunking, AMF0, FLV tags) lives in `UpstageCore` and is
unit-tested against a simulated server.

**Replay buffer.** Keeps the last 5–600 s encoded in memory; *Save Replay*
writes a file from the oldest keyframe.

**Control surfaces.**
- Global hotkeys (Carbon, work in any app) for stream/record/replay/studio
  mode/transition, per-scene switch, per-source mute, push-to-talk and
  push-to-mute. Defaults: ⌘⇧⌥R record, ⌘⇧⌥S stream, ⌘⇧⌥T transition, ⌘⇧⌥F1
  save replay.
- MIDI (CoreMIDI): bind notes/CCs with a *learn* button; trigger, momentary
  and continuous (fader) modes.
- **obs-websocket v5 compatible server** (`Settings > Remote`, port 4455,
  optional password with the standard SHA-256 challenge). Stream Deck, Touch
  Portal, Bitfocus Companion and other obs-websocket clients can switch
  scenes, toggle mute/volume, start/stop stream, record, replay buffer and
  scene item visibility, and receive the matching events.

**Not in this version (vs OBS).** Virtual camera (needs a Developer-ID-signed
CMIO system extension), browser source, SRT/WHIP/RIST outputs, multiview,
plugins/scripting, LUT filter, noise suppression/gate/compressor audio
filters, projector windows, auto-configuration wizard. HEVC streaming (enhanced
RTMP) is not implemented; streaming is H.264 only.

## Build it yourself

```sh
git clone https://github.com/advik-bhatt/obs-replacement.git
cd obs-replacement
swift test                       # UpstageCore unit tests (also run on Linux)
swift run Upstage                # debug run from the command line
sh scripts/bundle.sh             # universal release build -> dist/Upstage.app + .dmg
ARCHS=native sh scripts/bundle.sh   # current architecture only, faster
```

Xcode: *File > Open* the folder (it is a Swift package); run the `Upstage`
scheme. `swift build` compiles the Metal shaders at runtime from source
(`Sources/Upstage/Render/ShaderSource.swift`) because SwiftPM does not build
`.metal` files from the command line.

To ship a signed build, set `SIGN_IDENTITY="Developer ID Application: …"`
before `scripts/bundle.sh`; notarization is not scripted yet.

## Layout

```
Package.swift                  SwiftPM manifest (UpstageCore everywhere, Upstage on macOS)
Sources/UpstageCore/           Pure Swift, tested on Linux + macOS
  Model/                       scenes, sources, filters, transforms, profiles, hotkeys, MIDI
  Audio/                       dB math, cubic fader, channel matrix, ring buffer, meters
  Streaming/                   AMF0, RTMP chunking + handshake, FLV/AVC/AAC, publisher state machine
  Remote/                      obs-websocket v5 protocol + SHA-256 auth
Sources/Upstage/               macOS app
  Capture/                     AVFoundation cameras, ScreenCaptureKit, CoreAudio AUHAL, media, static
  Render/                      Metal shaders, compositor, MetalFX upscaler cache, texture cache
  Audio/                       mixer, monitoring, source output conversion
  Output/                      VideoToolbox encoder, AAC encoder, recorder, RTMP stream output, replay
  Engine/                      render loop + source registry + outputs
  Control/                     hotkeys, MIDI, obs-websocket server
  App/, UI/                    AppState, persistence, SwiftUI
Tests/UpstageCoreTests/        47 tests
scripts/bundle.sh              .app + .dmg + icon, ad-hoc or Developer ID signing
.github/workflows/build.yml    Linux core tests + macOS build, artifact, release on v* tags
```

Settings and scene collections are JSON under
`~/Library/Application Support/Upstage/` (profiles are user-only readable
because they hold the stream key). Recordings default to `~/Movies/Upstage`.
