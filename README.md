# YTSkipSilence

A **YTLite extension** that ports [Overcast](https://overcast.fm/)'s silence-skipping behavior into the YouTube iOS app. Adds a clean toggle button to the YouTube video overlay (via [PoomSmart/YTVideoOverlay](https://github.com/PoomSmart/YTVideoOverlay)). When enabled, the tweak attaches an `MTAudioProcessingTap` to the underlying `AVPlayer`'s audio tracks and uses a real-time RMS→dBFS detector to seek past long silences — intros, outros, dead air between segments — at Overcast's signature ~4× silence-skipping speed.

> Built on the structural template of [Sohday67/YouTimeStamp](https://github.com/Sohday67/YouTimeStamp).

---

## Why

Overcast (Marco Arment) famously ships a "Smart Speed" feature that pre-analyzes podcast audio offline, finds silence regions, and plays through them at ~4× speed. The Overcast binary (revealed via class-dump/strings) exposes the API surface:

```
seekToNextSilenceWithMinimumSampleDuration:threshold:
timestampOfNearestSilenceBetweenStartTime:endTime:silenceThreshold:
seekToNearestSilenceBetweenStartTime:endTime: / :thenPlay:
findNearestSilence(_:Bool)
@property (assign) BOOL skipSilences;
@property (strong) OCAudioPlaybackSpeed *silenceSkippingSpeed;
@property (assign) BOOL isSmartSpeedBypassed;
// Source path leaked in symbol strings:
// /Users/marco/overcast/overcast-ios/OCAudio/Sources/OCAudioCore/OCVoiceBoost/OCVoiceBoostLookahead.c
```

Overcast can do this because it owns the audio pipeline and can pre-process the file. YouTube can't be pre-analyzed (HLS/DASH streaming + DRM), so **YTSkipSilence does it in real time**:

1. An `MTAudioProcessingTap` (Apple's official, app-store-safe audio inspection API) is attached to every audio track of the current `AVPlayerItem`.
2. Each audio chunk is fed to `SkipSilenceDetector`, which computes per-window RMS in dBFS.
3. Consecutive silent windows are accumulated into a "silence run".
4. When the run exceeds `minSilenceDuration` (default 0.6 s) and the cooldown has elapsed, the manager seeks the `AVPlayer` forward by `silence × silenceSkipSpeedMultiplier` (default 4×).
5. After the seek completes, the detector is reset so it doesn't immediately re-trigger on the post-seek audio.

---

## How it looks

A single icon button appears in the YouTube player overlay — either next to the cast/share buttons (top) or next to the fullscreen button (bottom), your choice (pick in YTVideoOverlay settings). The icon is **white** when off and **YouTube-blue** when on.

| Off | On |
|-----|-----|
| `SkipSilenceOff@3x.png` (white speaker/skip glyph) | `SkipSilenceOn@3x.png` (YouTube-blue speaker/skip glyph) |

The button is provided by YTVideoOverlay — we just supply an icon, a tap selector, and the toggle state. This is the exact pattern [YouTimeStamp](https://github.com/Sohday67/YouTimeStamp/blob/main/Tweak.x) uses.

---

## Repository layout

```
YTSkipSilence/
├── .gitignore
├── LICENSE                                    (MIT; includes Overcast attribution)
├── Makefile                                   (Theos; arc + AVFoundation/MediaToolbox)
├── control                                    (package: com.ytskipsilence.tweak)
├── README.md                                  (this file)
├── Tweak.x                                    (Logos hooks — modeled on YouTimeStamp)
├── YTSkipSilence.plist                        (MS filter: com.google.ios.youtube only)
├── Source/
│   ├── SkipSilenceSettings.h / .m             (NSUserDefaults wrapper, all defaults in one place)
│   ├── SkipSilenceDetector.h / .m             (RMS→dBFS state machine, ported semantics)
│   ├── SkipSilenceAudioTap.h / .m             (MTAudioProcessingTap wrapper)
│   └── SkipSilenceManager.h / .m              (orchestrator: player → tap → detector → seek)
└── layout/
    └── Library/
        └── Application Support/
            └── YTSkipSilence.bundle/
                ├── SkipSilenceOff@2x.png
                ├── SkipSilenceOff@3x.png
                ├── SkipSilenceOn@2x.png
                ├── SkipSilenceOn@3x.png
                └── en.lproj/
                    └── Localizable.strings
```

---

## Build prerequisites

1. A working [Theos](https://theos.dev) install (`$THEOS` env var set).
2. The [`YouTubeHeader`](https://github.com/PoomSmart/YouTubeHeader) framework available as a Theos private framework (most YTLite dev environments ship this).
3. A sibling checkout of [PoomSmart/YTVideoOverlay](https://github.com/PoomSmart/YTVideoOverlay):

   ```bash
   git clone https://github.com/PoomSmart/YTVideoOverlay  ../YTVideoOverlay
   git clone https://github.com/PoomSmart/YouTubeHeader   ../YouTubeHeader   # if not already present
   ```

   The `Tweak.x` imports `../YTVideoOverlay/Header.h` and `../YTVideoOverlay/Init.x` (the second is `#import`-ed as source — it inlines `initYTVideoOverlay()` into our dylib, exactly as YouTimeStamp does).

4. A jailbroken iOS 15+ device (rootless or roothide) with:
   - YTLite installed
   - `com.ps.ytvideooverlay (>= 2.0.0)` installed from PoomSmart's repo

---

## Build & install

```bash
# 1. Clone this repo and its sibling dependency
git clone https://github.com/<your-account>/YTSkipSilence.git
cd YTSkipSilence
git clone https://github.com/PoomSmart/YTVideoOverlay.git ../YTVideoOverlay

# 2. Build for your jailbreak scheme (pick one)
make package THEOS_PACKAGE_SCHEME=rootless    # for palera1n / Dopamine / NekoJB
# or
make package THEOS_PACKAGE_SCHEME=roothide    # for roothide

# 3. Install over SSH (replace with your device IP / port)
make install THEOS_PACKAGE_SCHEME=rootless THEOS_DEVICE_IP=127.0.0.1 THEOS_DEVICE_PORT=22

# 4. Respring
ssh root@127.0.0.1 "killall -9 SpringBoard"
```

After install, open YouTube, start any video, and tap the **Skip Silence** button in the player overlay (top or bottom — your choice in YTVideoOverlay settings). The icon turns blue when active.

---

## Configuration

All settings live in `NSUserDefaults` and are exposed via YTVideoOverlay's settings pane (in YTLite's settings → YTVideoOverlay → Skip Silence). The defaults are:

| Setting | Default | Key | Notes |
|---|---|---|---|
| Master enable | Off | `YTSkipSilence-Enabled` | Toggled by the overlay button. |
| Show button | On | `YTVideoOverlay-SkipSilence-Enabled` | Master visibility switch (managed by YTVideoOverlay). |
| Skip backward to silence start | Off | `YTSkipSilence-SkipBackward` | Optional rewind-to-silence-start before skipping forward. |
| Verbose logging | Off | `YTSkipSilence-VerboseLogging` | Spams syslog with detection decisions. |
| Silence threshold | -45 dBFS | `YTSkipSilence-ThresholdDB` | Windows quieter than this are "silent". Speech is ~-25 to -35 dBFS. |
| Min silence duration | 0.6 s | `YTSkipSilence-MinSilenceDuration` | Mirrors Overcast's `seekToNextSilenceWithMinimumSampleDuration:`. |
| Skip speed multiplier | 4.0× | `YTSkipSilence-SkipSpeedMultiplier` | Mirrors Overcast's `silenceSkippingSpeed` (≈4×). |
| Skip cooldown | 0.5 s | `YTSkipSilence-Cooldown` | Pause between consecutive skips. |

The threshold / duration / multiplier / cooldown keys are not (yet) editable from the YTVideoOverlay pane (which only handles booleans). Edit them in `Source/SkipSilenceSettings.m` and re-build, or set them programmatically from another tweak.

---

## Architecture

```
 YTPlayerViewController (Logos %hook)
        │
        │ KVC: valueForKey:@"player" | @"_player" | @"mediaPlayer" | ...
        ▼
 SkipSilenceManager ──── KVO ───► AVPlayer.currentItem
        │                            │
        │                            │ .status == ReadyToPlay
        │                            ▼
        │                 SkipSilenceAudioTap.attachToPlayerItem:
        │                            │
        │                            │ AVAssetTrack(audio) → AVMutableAudioMix
        │                            │ → MTAudioProcessingTap (PreEffects)
        │                            ▼
        │                   tapProcessCallback (C)
        │                            │
        │                   AudioBufferList + frames + ASBD
        │                            ▼
        │                 SkipSilenceDetector.processAudio:
        │                            │
        │                            │ RMS → dBFS → state machine
        │                            │
        │                            ▼
        │              didDetectSilenceWithDuration:atHostTime:
        │                            │
        ▼                            │
 AVPlayer.seekToTime  ◄──────────────┘
```

### Why `MTAudioProcessingTap`?

It's the only Apple-blessed way to inspect `AVPlayer` audio without breaking FairPlay / HLS DRM. We attach with `kMTAudioProcessingTapCreationFlag_PreEffects` so we see audio before YouTube's audio processing (EQ, normalization, etc.) — giving us the source signal for accurate silence detection. The tap is **read-only** — `tapProcessCallback` calls `MTAudioProcessingTapGetSourceAudio` and forwards the buffer unmodified to the detector, then returns it to AVFoundation untouched.

### Why not just use `AVAudioEngine`?

`AVAudioEngine` taps the **microphone** input, not playback. To tap playback you'd need to either redirect the audio output (breaks YouTube) or use the private `AVAudioOutputNodeRenderBus` SPI (breaks app-store-safety). `MTAudioProcessingTap` is the documented, safe path.

### Why KVC for AVPlayer extraction?

`YTPlayerViewController` wraps the `AVPlayer` in a private container whose ivar name has shifted across YouTube versions (`player`, `_player`, `mediaPlayer`, `_mediaPlayer`, …). We try a list of candidates via `valueForKey:` and fall back to nesting one level deeper. If every candidate fails, we log a warning and the tweak is dormant for that video — no crash, no broken playback.

---

## Comparison with Overcast

| Aspect | Overcast | YTSkipSilence |
|---|---|---|
| Audio source | Local podcast file (full file on disk) | HLS/DASH stream (YouTube) |
| Silence discovery | **Offline 2-pass LUFS pre-analysis** (`OCVoiceBoostLookahead.c`) | **Real-time RMS→dBFS** sliding window |
| Loudness unit | LUFS (true loudness) | dBFS (peak-relative) |
| Skip mechanism | Adjusts playback rate to ~4× during silence (no seek) | `AVPlayer.seekToTime` (HLS can't safely rate-change mid-stream) |
| Trigger threshold | LUFS-based, calibrated per file | Fixed -45 dBFS (configurable) |
| Min silence | Per-file, learned | 0.6 s (configurable) |
| Reset on seek | Yes (re-runs lookahead) | Yes (detector `reset`) |
| UI | App-native Smart Speed toggle | YTVideoOverlay button (white/blue) |

The fundamental constraint is that YouTube's audio can't be pre-analyzed — but the **user-visible behavior** (silences are skipped at ~4×, normal speech plays at 1×) is preserved.

---

## Limitations & known issues

- **DRM-protected content (Premium movies, some music videos):** `MTAudioProcessingTap` receives **silence** (zero-filled buffers) for encrypted audio tracks. The detector will see "silence" everywhere and either never trigger (if cooldown holds) or trigger constantly. The tweak is best-suited to spoken-word YouTube (podcasts, lectures, interviews) — which is exactly the use case Overcast's feature targets.
- **AVPlayer extraction:** If YouTube renames the ivar again, the tweak degrades gracefully to "no-op". Watch for `[YTSkipSilence] could not extract AVPlayer...` in the log.
- **Background playback:** The tap continues to run while YouTube is backgrounded; silences are skipped even when the screen is off. This is intentional.
- **Live streams:** Skipping forward on a live stream makes no sense and may fail silently. Disable the button during live content.
- **First video after install:** Sometimes the tap fails to attach until the player is torn down and rebuilt. Toggling the button off → on (or starting a new video) fixes it.

---

## Troubleshooting

| Symptom | Diagnosis | Fix |
|---|---|---|
| Button never appears in overlay | YTVideoOverlay not installed | Install `com.ps.ytvideooverlay` from PoomSmart's repo |
| Button appears but does nothing when tapped | AVPlayer extraction failed | Check syslog for `[YTSkipSilence] could not extract AVPlayer...` |
| Button toggles but no silences are skipped | Audio track is DRM-muted | Try a different video (podcast / lecture / interview) |
| Tweak skips too aggressively | Threshold too high or min duration too low | Lower `silenceThresholdDB` (more negative) or raise `minSilenceDuration` in `Source/SkipSilenceSettings.m` |
| Tweak never skips | Threshold too low or detector not receiving audio | Enable `Verbose logging` in YTVideoOverlay settings; check syslog for `[YTSkipSilence][v] silence begin/end` lines |
| YouTube crashes on video start | AVAudioMix / tap creation failed on this YouTube version | File an issue with the YouTube version + iOS version |

---

## Credits

- **[Marco Arment / Overcast](https://overcast.fm/)** — original Smart Speed / silence-skipping implementation. The algorithm in this tweak is a faithful real-time port of Overcast's `seekToNextSilenceWithMinimumSampleDuration:threshold:` semantics. Used for personal, non-commercial use.
- **[PoomSmart](https://github.com/PoomSmart)** — `YTVideoOverlay` framework and the `YouTubeHeader` Theos package. This extension wouldn't be possible without either.
- **[Sohday67 / YouTimeStamp](https://github.com/Sohday67/YouTimeStamp)** — the structural template this extension is modeled on.
- **[Theos](https://theos.dev)** — the build system.

---

## License

MIT — see [`LICENSE`](LICENSE). Includes an explicit attribution to Overcast's silence-skipping implementation, which this tweak ports for personal use.
