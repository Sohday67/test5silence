//
//  SkipSilenceDetector.h
//  YTSkipSilence
//
//  Real-time silence detector.
//
//  Overcast (Marco Arment) preprocesses podcast audio offline to locate
//  silence regions, then plays through them at silenceSkippingSpeed (≈4x).
//  Source: /Users/marco/overcast/overcast-ios/OCAudio/Sources/OCAudioCore/
//          OCVoiceBoost/OCVoiceBoostLookahead.c (revealed by symbol strings
//          in the Overcast binary: seekToNextSilenceWithMinimumSampleDuration:threshold:
//          and timestampOfNearestSilenceBetweenStartTime:endTime:silenceThreshold:).
//
//  YouTube videos are streamed (HLS/DASH) and cannot be pre-analyzed, so this
//  detector works in real time: it ingests audio sample buffers from an
//  MTAudioProcessingTap (see SkipSilenceAudioTap), computes per-window RMS in
//  dBFS, and runs a small state machine that:
//    1. Marks each analysis window as silent or loud relative to a threshold
//    2. Accumulates consecutive silent windows into a "silence run"
//    3. When the run exceeds minSilenceDuration, fires onSilenceDetected:withDuration:
//    4. Enforces a cooldown so a single silence region only triggers one skip
//
//  The skip itself is performed by SkipSilenceManager (which owns the AVPlayer).
//

#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>

NS_ASSUME_NONNULL_BEGIN

@class SkipSilenceDetector;

@protocol SkipSilenceDetectorDelegate <NSObject>
@required
/// Called when sustained silence has been detected.
/// @param durationSeconds Length of the silence run so far (>= minSilenceDuration).
- (void)detector:(SkipSilenceDetector *)detector
    didDetectSilenceWithDuration:(NSTimeInterval)durationSeconds
                  atHostTime:(UInt64)hostTime;
@end

@interface SkipSilenceDetector : NSObject

@property (nonatomic, weak) id<SkipSilenceDetectorDelegate> delegate;

/// dBFS below which a window is considered silent. Default -45.
@property (nonatomic, assign) float silenceThresholdDB;

/// Minimum sustained silence (seconds) before a callback fires. Default 0.6.
@property (nonatomic, assign) float minSilenceDuration;

/// Cooldown (seconds) after a callback before the next can fire. Default 0.5.
@property (nonatomic, assign) float cooldown;

/// Analysis window length (seconds). Default 0.05 (50 ms).
@property (nonatomic, assign) float analysisWindowSeconds;

/// YES if verbose logging to syslog is enabled.
@property (nonatomic, assign) BOOL verboseLogging;

- (instancetype)initWithFormat:(AudioStreamBasicDescription)format;

/// Push a chunk of audio samples. Called from the MTAudioProcessingTap callback.
/// @param inBufferList   Pointer to an AudioBufferList with the audio data.
/// @param inNumberFrames Number of frames in the chunk.
- (void)processAudio:(const AudioBufferList *)inBufferList
       framesCount:(UInt32)inNumberFrames;

/// Reset all internal state (e.g. when playback seeks to a new position).
- (void)reset;

@end

NS_ASSUME_NONNULL_END
