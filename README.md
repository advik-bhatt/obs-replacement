# Upstage

A native macOS studio app for recording and streaming, built to replace OBS for
one specific job first: take an iPhone Continuity Camera feed (wired or
wireless), upscale it to 4K with MetalFX, shoot in portrait, and mix every
CoreAudio input on the Mac (BlackHole 16ch included).

Status: bootstrapping. The core (scene model, RTMP/FLV muxer, obs-websocket
protocol) is unit-tested; the macOS app is being built. See the GitHub
Actions "build" workflow for the latest `Upstage.dmg` artifact.
