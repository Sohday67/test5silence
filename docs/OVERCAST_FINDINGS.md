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

- It attaches an `MTAudioProcessingTap` to the active `AVPlayerItem` where possible.
- It computes RMS energy from decoded PCM samples.
- It applies smoothed dB thresholding to avoid reacting to single quiet frames.
- It either seeks forward in short steps during sustained silence or temporarily increases playback rate.

No Overcast implementation code, assets, or binary fragments are included.
