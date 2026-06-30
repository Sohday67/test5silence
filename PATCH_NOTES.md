# Patch notes

## Build-failure fix v2

The GitHub Actions job failed in the Theos dylib link step for `YTSkipSilence.dylib` on both the `arm64e` and `arm64` targets. The previous implementation intentionally avoided linking MediaToolbox symbols directly, but it still depended on `MTAudioProcessingTap` types and runtime behavior that can be fragile in public SDK / Theos CI builds.

This revision removes the MediaToolbox audio tap path completely and uses a conservative AVFoundation-only implementation:

- `ARCHS` is now `arm64`, matching the working YouTimeStamp example and avoiding unnecessary arm64e packaging friction in YTLitePlus workflows.
- The tweak no longer imports, links, or dynamically resolves MediaToolbox.
- Silence ranges are analyzed with `AVAssetReader` using linear PCM windows.
- Playback skipping is driven by an `AVPlayer` periodic time observer.
- Jump mode seeks to the end of detected silent ranges.
- Rate-through mode temporarily speeds playback while inside detected silent ranges.

This keeps the Overcast-inspired behavior model (`audio peaks/signature -> skip/rate through silence`) while using only public AVFoundation/CoreMedia APIs that are available to the GitHub Actions SDK.
