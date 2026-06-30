# Overcast IPA inspection notes

The uploaded IPA was inspected only for observable symbol/string-level behavior. It contained a Mach-O arm64 `Overcast` executable and not recoverable source files.

Relevant discovered names included:

- `skipSilences`
- `silenceSkippingSpeed`
- `smartSpeed`
- `OCAudioPeaks`
- `OCAudioSignature`
- `OCAudioPlayer`
- `OCAudioPlaybackSpeed`
- `Smart Speed saved %g of %g seconds (%g%%)`
- `PlayerCommon_currentPeakAmplitude`
- `updatesPeakAmplitudes`
- `minimumSpeed`

Behavior inferred from those names:

1. Smart Speed is a playback pipeline feature, not merely a UI toggle.
2. It distinguishes normal baseline speed from a separate silence-skipping speed.
3. It tracks or estimates savings over time.
4. It uses peak/amplitude or precomputed audio-signature information as part of analysis.
5. It keeps separate handling for voice boost and music detection.

YTSkipSilence implements a clean-room approximation suited to YouTube:

- It analyzes the active `AVPlayerItem` audio track with `AVAssetReader` where possible.
- It computes RMS energy from decoded PCM sample windows.
- It groups sustained low-energy windows into silent time ranges.
- It either seeks to the end of a detected silent range or temporarily increases playback rate while inside one.

No Overcast implementation code, assets, or binary fragments are included.
