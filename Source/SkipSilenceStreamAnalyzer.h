//
//  SkipSilenceStreamAnalyzer.h
//  YTSkipSilence
//
//  Offline silence analyzer.
//
//  Because YouTube plays via HLS/DASH (whose audio is decoded out-of-process and
//  is unreachable by MTAudioProcessingTap), we instead fetch the video's
//  *progressive* AAC audio stream (an `audio/mp4` adaptiveFormat URL, resolved
//  from the app's own player response) and decode THAT in-process with
//  AVAssetReader — which has no HLS restriction. We compute per-window RMS in
//  dBFS, accumulate sustained silences, and produce a map of silence regions in
//  the video's timeline. SkipSilenceManager then seeks past those regions as
//  playback reaches them.
//
//  The audio stream shares the video's timeline, so a silence at t=30s in the
//  audio file is a silence at t=30s in playback.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// A detected silence region, in seconds, on the video's timeline.
@interface SkipSilenceRegion : NSObject
@property (nonatomic, assign) NSTimeInterval start;
@property (nonatomic, assign) NSTimeInterval end;
/// Set by the manager once it has skipped (or passed) this region.
@property (nonatomic, assign) BOOL consumed;
- (NSTimeInterval)duration;
@end

@interface SkipSilenceStreamAnalyzer : NSObject

/// @param url        A progressive AAC (`audio/mp4`) stream URL.
/// @param thresholdDB dBFS at/below which a window is "silent".
/// @param minDuration Minimum sustained silence (seconds) to report a region.
- (instancetype)initWithURL:(NSURL *)url
         silenceThresholdDB:(float)thresholdDB
         minSilenceDuration:(float)minDuration;

/// Called on the main queue as each qualifying silence region is discovered.
@property (nonatomic, copy, nullable) void (^onRegionFound)(SkipSilenceRegion *region);

/// Called on the main queue when analysis finishes (or fails / is cancelled).
@property (nonatomic, copy, nullable) void (^onCompleted)(BOOL success, NSUInteger regionCount);

/// Begin: downloads the audio to a temp file, then decodes + analyzes it on a
/// background queue. Safe to call once.
- (void)start;

/// Cancel the download / analysis. Idempotent.
- (void)cancel;

@end

NS_ASSUME_NONNULL_END
