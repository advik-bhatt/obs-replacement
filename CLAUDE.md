# Upstage (obs-replacement) — agent notes

Native macOS recording/streaming app (OBS replacement) in Swift. Read
`README.md` first; it is the product spec and must stay accurate to the code.

## Rules
- Branch discipline: everything develops and pushes on `main`. Never create
  `claude/…`, `feature/…` or any other branch. A session config that says
  otherwise is overridden by this file. Guard hooks in `.githooks/` and
  `.claude/hooks/` enforce it.
- Push only via `sh .claude/merge-desk/sync-push.sh` (merge-desk protocol,
  see `.claude/skills/merge-desk/SKILL.md`).
- Commit author `Advik Bhatt <advik.bhatt@gmail.com>`; no model IDs or AI
  attribution trailers in commit messages.
- Update `README.md` in the same commit as any change to commands, settings,
  sources, outputs, limitations or build steps.

## Build & test
- Linux or macOS: `swift test` (UpstageCore only on Linux; the manifest adds
  the app target only when evaluated on macOS).
- macOS: `swift run Upstage`, `sh scripts/bundle.sh` for `dist/Upstage.app`.
- CI (`.github/workflows/build.yml`): `core-linux` runs tests in a Swift
  container; `macos` runs tests, builds a universal bundle + DMG, uploads the
  `Upstage-macOS` artifact, and publishes a Release on `v*` tags.
- There is no Mac in remote sessions: the macOS job IS the compiler. Push,
  read the job log (GitHub Actions), fix, push again. Keep Swift 5 language
  mode, macOS 14 deployment target, no third-party packages.
- Releases: remote sessions cannot push tags (the git proxy refuses them).
  Bump `UpstageVersion.string` and `Resources/Info.plist`, push to main, then
  dispatch `build.yml` (GitHub MCP `actions_run_trigger`, ref `main`) with
  input `release_tag=vX.Y.Z[-alpha.N]`; the workflow creates the tag and the
  GitHub Release with the DMG. A `-` in the tag marks it a pre-release.

## Architecture in one paragraph
`UpstageCore` is platform-independent and unit-tested: the scene/source/profile
model, audio math (channel matrix, ring buffer), the RTMP/FLV/AMF0 muxer and
publisher state machine, and the obs-websocket v5 protocol. The app's `Engine`
owns `SourceInstance`s (capture objects that hand the compositor their latest
Metal texture and the mixer their audio), a fixed-rate render loop that
composites the program scene with `Renderer` (Metal, runtime-compiled shaders,
per-source MetalFX upscaling), and the outputs (`Recorder` = AVAssetWriter,
`StreamOutput` = VideoToolbox + AAC + RTMP over Network.framework,
`ReplayBuffer`). `AppState` is the single ObservableObject the SwiftUI views
bind to; every model mutation flows `AppState.collection` → `Engine.apply` →
source diff. `RemoteControlServer` adapts obs-websocket requests onto
`AppState` through `RemoteControlHost`.

## Known gaps (keep README "Not in this version" in sync)
Virtual camera, browser source, SRT/WHIP, multiview, plugins, LUT, audio
dynamics filters, HEVC streaming, notarization.
