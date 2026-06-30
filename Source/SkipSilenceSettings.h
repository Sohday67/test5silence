//
//  SkipSilenceSettings.h
//  YTSkipSilence
//
//  Centralized NSUserDefaults wrapper for the YTSkipSilence tweak.
//  All keys are namespaced under "YTSkipSilence-" to avoid collisions
//  with other tweaks sharing the YouTube preferences domain.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Default constants

// dBFS below which a window is considered "silent".
// Overcast uses an LUFS-derived threshold; we approximate with dBFS since
// we cannot run a two-pass loudness pre-analysis on streaming YouTube audio.
extern const float kDefaultSilenceThresholdDB;

// Minimum sustained-silence duration (in seconds) before a skip is triggered.
// Mirrors Overcast's seekToNextSilenceWithMinimumSampleDuration:threshold:
// "minimumSampleDuration" parameter — short silences (breaths, pauses) are
// left intact, long silences (intros/outros, ad-break gaps) are skipped.
extern const float kDefaultMinSilenceDuration;

// Multiplier applied to the sustained-silence duration when computing the
// skip distance. e.g. 1.0s of silence at 4.0x = 4.0s of skipped audio.
// Overcast's silenceSkippingSpeed is typically 4.0x.
extern const float kDefaultSilenceSkipSpeedMultiplier;

// Cooldown (seconds) after a skip before another skip is allowed. Prevents
// the detector from re-triggering during the seek animation.
extern const float kDefaultSkipCooldown;

// Size of the rolling analysis window (seconds) used by SkipSilenceDetector.
extern const float kDefaultAnalysisWindowSeconds;

#pragma mark - Keys

extern NSString * const kSkipSilenceEnabledKey;            // BOOL — master toggle (driven by the overlay button)
extern NSString * const kSkipSilenceShowButtonKey;         // BOOL — show the button in the overlay (YTVideoOverlay-managed)
extern NSString * const kSkipSilenceSkipBackwardKey;       // BOOL — also seek backward to the start of a silence if we entered it
extern NSString * const kSkipSilenceVerboseLoggingKey;     // BOOL — emit debug logs to syslog
extern NSString * const kSkipSilenceThresholdDBKey;        // float — silence threshold in dBFS
extern NSString * const kSkipSilenceMinDurationKey;        // float — minimum sustained silence (sec) before skip
extern NSString * const kSkipSilenceSpeedMultiplierKey;    // float — skip speed multiplier
extern NSString * const kSkipSilenceCooldownKey;           // float — cooldown (sec) between skips
extern NSString * const kSkipSilenceLastPositionKey;       // float — last known playback position (for resume across app launches)

#pragma mark - Interface

@interface SkipSilenceSettings : NSObject

+ (instancetype)shared;

// Toggles
@property (nonatomic, assign, getter=isEnabled) BOOL enabled;
@property (nonatomic, assign) BOOL showButton;
@property (nonatomic, assign) BOOL skipBackward;
@property (nonatomic, assign) BOOL verboseLogging;

// Tunable algorithm parameters (each with a sensible default)
@property (nonatomic, assign) float silenceThresholdDB;
@property (nonatomic, assign) float minSilenceDuration;
@property (nonatomic, assign) float silenceSkipSpeedMultiplier;
@property (nonatomic, assign) float skipCooldown;

// Persisted playback resume (best-effort)
@property (nonatomic, assign) float lastKnownPosition;

// Register defaults on first launch (call from %ctor)
+ (void)registerDefaults;

@end

NS_ASSUME_NONNULL_END
