# YTSkipSilence

A YTLite-compatible YouTube tweak that adds a clean **Skip Silence** button to the video overlay using PoomSmart's YTVideoOverlay helper.

This repository was built after inspecting the supplied Overcast IPA for observable feature shape. The IPA did not contain recoverable source code, but its symbols and strings showed these relevant concepts: `skipSilences`, `silenceSkippingSpeed`, `smartSpeed`, `OCAudioPeaks`, `OCAudioSignature`, and Smart Speed time-savings tracking. This project implements a clean-room approximation of that behavior for YouTube playback.

No Overcast source, binary code, assets, or proprietary implementation were copied into this repository.

## GitHub Actions / YTLitePlusEXTRA build note

If you build this from a YTLitePlusEXTRA workflow that clones `YTVideoOverlay` as a sibling repo, this project automatically imports `../YTVideoOverlay/Header.h` and `../YTVideoOverlay/Init.x`. For standalone builds, it falls back to the vendored compatibility headers in `Vendor/YTVideoOverlay`.

This revision intentionally avoids MediaToolbox and `MTAudioProcessingTap` entirely. The silence model is now built with public AVFoundation/CoreMedia APIs: an `AVAssetReader` analyzes audio windows into silent time ranges, then an `AVPlayer` periodic time observer skips or speeds through those ranges. This is less realtime than an audio tap, but it is much friendlier to public SDK / Theos GitHub Actions builds.

## What it does

- Adds a **Skip Silence** overlay button through YTVideoOverlay.
- Analyzes the active `AVPlayerItem` audio track with `AVAssetReader`.
- Detects low-energy audio using RMS/dB windows.
- Default mode jumps to the end of detected silent ranges.
- Optional rate-through mode speeds through detected silent ranges instead of hard seeking.
- Shows lightweight YouTube HUD messages for enable/disable and mode changes.
- Works as a standalone Theos tweak and can be bundled alongside YTLite/YTPlus builds.

## Gesture controls

- Tap the overlay button: enable or disable skip silence.
- Long press the overlay button: switch between **jump mode** and **rate-through mode**.

## Build

Install Theos, then run:

```sh
make package THEOS_PACKAGE_SCHEME=rootless
```

For rootful:

```sh
make package
```

## Dependencies

- YouTube for iOS
- Theos / Logos
- `com.ps.ytvideooverlay (>= 2.0.0)` for the overlay button registration
- UIKit, AVFoundation, CoreMedia, AudioToolbox, QuartzCore

## Notes and limitations

YouTube changes private classes often. The overlay button is intentionally based on YTVideoOverlay's public integration template. Silence analysis now happens through `AVAssetReader`, so some encrypted, live, or remote streaming assets may not expose readable audio samples. In those cases the button still toggles cleanly, but skipping may not activate for that item.

See `docs/OVERCAST_FINDINGS.md` for the non-code IPA inspection notes that informed the behavior model.
