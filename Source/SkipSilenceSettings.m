//
//  SkipSilenceSettings.m
//  YTSkipSilence
//

#import "SkipSilenceSettings.h"

#pragma mark - Defaults

const float kDefaultSilenceThresholdDB        = -45.0f;   // dBFS — quiet speech is ~-35 to -25 dBFS
const float kDefaultMinSilenceDuration        = 0.6f;     // sec — skip silences >= 0.6s
const float kDefaultSilenceSkipSpeedMultiplier = 4.0f;    // 4x — Overcast's silenceSkippingSpeed
const float kDefaultSkipCooldown              = 0.5f;     // sec — pause between consecutive skips
const float kDefaultAnalysisWindowSeconds     = 0.05f;    // 50 ms RMS windows

#pragma mark - Keys

NSString * const kSkipSilenceEnabledKey         = @"YTSkipSilence-Enabled";
NSString * const kSkipSilenceShowButtonKey      = @"YTVideoOverlay-YTSkipSilence-Enabled"; // YTVideoOverlay-<TweakKey>-Enabled; registering @YES makes the button visible by default
NSString * const kSkipSilenceSkipBackwardKey    = @"YTSkipSilence-SkipBackward";
NSString * const kSkipSilenceVerboseLoggingKey  = @"YTSkipSilence-VerboseLogging";
NSString * const kSkipSilenceThresholdDBKey     = @"YTSkipSilence-ThresholdDB";
NSString * const kSkipSilenceMinDurationKey     = @"YTSkipSilence-MinSilenceDuration";
NSString * const kSkipSilenceSpeedMultiplierKey = @"YTSkipSilence-SkipSpeedMultiplier";
NSString * const kSkipSilenceCooldownKey        = @"YTSkipSilence-Cooldown";
NSString * const kSkipSilenceLastPositionKey    = @"YTSkipSilence-LastKnownPosition";

@implementation SkipSilenceSettings

+ (instancetype)shared {
    static SkipSilenceSettings *sInstance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sInstance = [[SkipSilenceSettings alloc] init];
    });
    return sInstance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        [self reload];
    }
    return self;
}

+ (void)registerDefaults {
    NSDictionary *defaults = @{
        kSkipSilenceEnabledKey:          @NO,
        kSkipSilenceShowButtonKey:       @YES,
        kSkipSilenceSkipBackwardKey:     @NO,
        kSkipSilenceVerboseLoggingKey:   @NO,
        kSkipSilenceThresholdDBKey:      @(kDefaultSilenceThresholdDB),
        kSkipSilenceMinDurationKey:      @(kDefaultMinSilenceDuration),
        kSkipSilenceSpeedMultiplierKey:  @(kDefaultSilenceSkipSpeedMultiplier),
        kSkipSilenceCooldownKey:         @(kDefaultSkipCooldown),
        kSkipSilenceLastPositionKey:     @0.0f,
    };
    [[NSUserDefaults standardUserDefaults] registerDefaults:defaults];
}

- (void)reload {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    _enabled                   = [d boolForKey:kSkipSilenceEnabledKey];
    _showButton                = [d boolForKey:kSkipSilenceShowButtonKey];
    _skipBackward              = [d boolForKey:kSkipSilenceSkipBackwardKey];
    _verboseLogging            = [d boolForKey:kSkipSilenceVerboseLoggingKey];
    _silenceThresholdDB        = (float)[d floatForKey:kSkipSilenceThresholdDBKey];
    _minSilenceDuration        = (float)[d floatForKey:kSkipSilenceMinDurationKey];
    _silenceSkipSpeedMultiplier = (float)[d floatForKey:kSkipSilenceSpeedMultiplierKey];
    _skipCooldown              = (float)[d floatForKey:kSkipSilenceCooldownKey];
    _lastKnownPosition         = (float)[d floatForKey:kSkipSilenceLastPositionKey];
}

- (void)setEnabled:(BOOL)enabled {
    _enabled = enabled;
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kSkipSilenceEnabledKey];
}

- (void)setShowButton:(BOOL)showButton {
    _showButton = showButton;
    [[NSUserDefaults standardUserDefaults] setBool:showButton forKey:kSkipSilenceShowButtonKey];
}

- (void)setSkipBackward:(BOOL)skipBackward {
    _skipBackward = skipBackward;
    [[NSUserDefaults standardUserDefaults] setBool:skipBackward forKey:kSkipSilenceSkipBackwardKey];
}

- (void)setVerboseLogging:(BOOL)verboseLogging {
    _verboseLogging = verboseLogging;
    [[NSUserDefaults standardUserDefaults] setBool:verboseLogging forKey:kSkipSilenceVerboseLoggingKey];
}

- (void)setSilenceThresholdDB:(float)silenceThresholdDB {
    _silenceThresholdDB = silenceThresholdDB;
    [[NSUserDefaults standardUserDefaults] setFloat:silenceThresholdDB forKey:kSkipSilenceThresholdDBKey];
}

- (void)setMinSilenceDuration:(float)minSilenceDuration {
    _minSilenceDuration = minSilenceDuration;
    [[NSUserDefaults standardUserDefaults] setFloat:minSilenceDuration forKey:kSkipSilenceMinDurationKey];
}

- (void)setSilenceSkipSpeedMultiplier:(float)silenceSkipSpeedMultiplier {
    _silenceSkipSpeedMultiplier = silenceSkipSpeedMultiplier;
    [[NSUserDefaults standardUserDefaults] setFloat:silenceSkipSpeedMultiplier forKey:kSkipSilenceSpeedMultiplierKey];
}

- (void)setSkipCooldown:(float)skipCooldown {
    _skipCooldown = skipCooldown;
    [[NSUserDefaults standardUserDefaults] setFloat:skipCooldown forKey:kSkipSilenceCooldownKey];
}

- (void)setLastKnownPosition:(float)lastKnownPosition {
    _lastKnownPosition = lastKnownPosition;
    [[NSUserDefaults standardUserDefaults] setFloat:lastKnownPosition forKey:kSkipSilenceLastPositionKey];
}

@end
