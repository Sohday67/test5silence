//
//  SkipSilenceManager.h
//  YTSkipSilence
//
//  Orchestrates silence-skipping for a single YouTube video.
//
//  Pipeline (map-based — see SkipSilenceStreamAnalyzer for why we don't tap the
//  live AVPlayer audio):
//
//    YTPlayerViewController (Logos hook)
//          │  currentVideoID + playerResponse.…streamingData.adaptiveFormats
//          ▼
//    SkipSilenceManager ── resolve audio/mp4 URL ──► SkipSilenceStreamAnalyzer
//          │                                              │ (AVAssetReader, offline)
//          │  ◄──────────── silence regions ──────────────┘
//          │
//          │  on each playback-time tick (updatePlaybackTime:)
//          ▼
//    [YTPlayerViewController seekToTime:]  (skip past the silence)
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class YTPlayerViewController;

@interface SkipSilenceManager : NSObject

/// Bind to the player VC: resolves the audio stream URL, analyzes it for silence
/// in the background, and arms time-based skipping. Re-attaching to the same
/// video is a no-op; a different video restarts analysis. Respects the master
/// enable setting.
- (void)attachToPlayerViewController:(YTPlayerViewController *)playerViewController;

/// Stop analysis and skipping; release resources.
- (void)detach;

/// Fed from the YTPlayerViewController time hooks. Drives the skips.
- (void)updatePlaybackTime:(NSTimeInterval)seconds;

/// YES once a silence map exists for the current video.
@property (nonatomic, readonly, getter=isMonitoring) BOOL monitoring;

@end

NS_ASSUME_NONNULL_END
