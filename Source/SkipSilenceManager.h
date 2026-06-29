//
//  SkipSilenceManager.h
//  YTSkipSilence
//
//  Orchestrates the silence-skipping pipeline for a single YouTube video.
//
//  Pipeline:
//
//    YTPlayerViewController (Logos hook)
//          │
//          │  (KVC access to underlying AVPlayer)
//          ▼
//    SkipSilenceManager ◄─────── SkipSilenceSettings (NSUserDefaults)
//          │
//          │  (observes AVPlayerItem readiness)
//          ▼
//    SkipSilenceAudioTap  ─────► AVPlayerItem.audioMix (MTAudioProcessingTap)
//          │
//          │  (forwards raw samples)
//          ▼
//    SkipSilenceDetector  ─────► RMS→dBFS state machine
//          │
//          │  (sustained silence callback)
//          ▼
//    SkipSilenceManager  ─────► AVPlayer.seekToTime (skip past silence)
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

@class SkipSilenceManager;

@protocol SkipSilenceManagerDelegate <NSObject>
@optional
/// Called whenever a skip occurs (for HUD / log feedback).
- (void)manager:(SkipSilenceManager *)manager
    didSkipSilenceWithDuration:(NSTimeInterval)skippedSeconds
                newPlaybackTime:(CMTime)newTime;
@end

@interface SkipSilenceManager : NSObject

@property (nonatomic, weak) id<SkipSilenceManagerDelegate> delegate;

/// Bind this manager to an AVPlayer (typically the underlying AVPlayer of
/// a YTPlayerViewController instance). Idempotent; calling with nil detaches.
- (void)attachToPlayer:(AVPlayer *)player;

/// Detach and release all resources (tap, detector, observations).
- (void)detach;

/// YES if the manager is actively monitoring audio.
@property (nonatomic, readonly, getter=isMonitoring) BOOL monitoring;

/// Push the latest playback time (seconds). The Tweak.x hook feeds this from
/// YTPlayerViewController.currentVideoMediaTime so the manager can compute
/// seek targets in player time rather than host time.
- (void)updatePlaybackTime:(NSTimeInterval)seconds;

@end

NS_ASSUME_NONNULL_END
