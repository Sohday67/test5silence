# YTSkipSilence

A YTLite-compatible YouTube tweak that adds a clean **Skip Silence** button to the video overlay using PoomSmart's YTVideoOverlay helper.

This repository was built after inspecting the supplied Overcast IPA for observable feature shape. The IPA did not contain recoverable source code, but its symbols and strings showed these relevant concepts: `skipSilences`, `silenceSkippingSpeed`, `smartSpeed`, `OCAudioPeaks`, `OCAudioSignature`, and Smart Speed time-savings tracking. This project implements a clean-room approximation of that behavior for YouTube playback.

No Overcast source, binary code, assets, or proprietary implementation were copied into this repository.

## What it does

- Adds a **Skip Silence** overlay button through YTVideoOverlay.
- Taps the YouTube `AVPlayerItem` audio path with `MTAudioProcessingTap` when possible.
- Detects low-energy audio using smoothed RMS/dB analysis.
- Default mode jumps ahead in small steps during sustained silence.
- Optional rate-through mode speeds through silence instead of hard seeking.
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
- UIKit, AVFoundation, CoreMedia, AudioToolbox, MediaToolbox, QuartzCore

## Notes and limitations

YouTube changes private classes often. The overlay button is intentionally based on YTVideoOverlay's public integration template. The audio tap is attached at the AVPlayer layer, so it is less dependent on YouTube private names, but some streams may not expose an audio track early or may reject audio-mix taps. In those cases the button still toggles cleanly, but silence skipping may not activate until a compatible player item is used.

See `docs/OVERCAST_FINDINGS.md` for the non-code IPA inspection notes that informed the behavior model.
