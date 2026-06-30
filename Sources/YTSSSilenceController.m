#import "YTSSSilenceController.h"
#import "YTSSDefines.h"
#import "YTSSHUD.h"
#import <QuartzCore/QuartzCore.h>
#import <AudioToolbox/AudioToolbox.h>
#import <objc/runtime.h>
#import <math.h>

static const void *YTSSSessionKey = &YTSSSessionKey;
static const void *YTSSRetryKey = &YTSSRetryKey;

@class YTSSPlayerSession;

@interface YTSSPlayerSession : NSObject
@property (nonatomic, weak) AVPlayer *player;
@property (nonatomic, weak) AVPlayerItem *item;
@property (nonatomic, strong) id timeObserver;
@property (nonatomic, strong) NSArray<NSValue *> *silentRanges;
@property (nonatomic, assign) BOOL analysisStarted;
@property (nonatomic, assign) BOOL analysisFinished;
@property (nonatomic, assign) BOOL currentlySpeeding;
@property (nonatomic, assign) BOOL suppressUntilVoice;
@property (nonatomic, assign) float lastVoiceRate;
@property (nonatomic, assign) CFTimeInterval lastSkipAt;
- (instancetype)initWithPlayer:(AVPlayer *)player item:(AVPlayerItem *)item;
- (void)start;
- (void)restoreRateIfNeeded;
@end

@interface YTSSSilenceController ()
@property (nonatomic, strong) NSHashTable<YTSSPlayerSession *> *sessions;
@property (nonatomic, readwrite, getter=isEnabled) BOOL enabled;
@property (nonatomic, readwrite) BOOL jumpMode;
@end

@implementation YTSSSilenceController

+ (instancetype)sharedController {
    static YTSSSilenceController *controller;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        controller = [[self alloc] init];
        [controller installDefaults];
    });
    return controller;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _sessions = [NSHashTable weakObjectsHashTable];
    }
    return self;
}

- (void)installDefaults {
    NSDictionary *defaults = @{
        YTSS_ENABLED_KEY: @NO,
        YTSS_JUMP_MODE_KEY: @YES,
        YTSS_AGGRESSIVE_KEY: @NO,
        YTSS_HUD_KEY: @YES,
    };
    [YTSSDefaults() registerDefaults:defaults];
    self.enabled = [YTSSDefaults() boolForKey:YTSS_ENABLED_KEY];
    self.jumpMode = [YTSSDefaults() boolForKey:YTSS_JUMP_MODE_KEY];
}

- (BOOL)toggleEnabled {
    self.enabled = !self.enabled;
    [YTSSDefaults() setBool:self.enabled forKey:YTSS_ENABLED_KEY];
    [YTSSDefaults() synchronize];

    if (!self.enabled) {
        [self refreshAllSessions];
    }

    NSString *mode = self.jumpMode ? @"jump" : @"rate-through";
    [YTSSHUD showMessage:self.enabled ? [NSString stringWithFormat:@"Skip Silence on (%@)", mode] : @"Skip Silence off"];
    return self.enabled;
}

- (BOOL)cycleMode {
    self.jumpMode = !self.jumpMode;
    [YTSSDefaults() setBool:self.jumpMode forKey:YTSS_JUMP_MODE_KEY];
    [YTSSDefaults() synchronize];
    [YTSSHUD showMessage:self.jumpMode ? @"Skip Silence: jump mode" : @"Skip Silence: rate-through mode"];
    return self.jumpMode;
}

- (void)refreshAllSessions {
    for (YTSSPlayerSession *session in self.sessions) {
        [session restoreRateIfNeeded];
    }
}

- (void)attachToPlayer:(AVPlayer *)player item:(AVPlayerItem *)item reason:(NSString *)reason {
    if (!player || !item) return;
    if (objc_getAssociatedObject(item, YTSSSessionKey)) return;

    AVAsset *asset = item.asset;
    NSArray<AVAssetTrack *> *tracks = [asset tracksWithMediaType:AVMediaTypeAudio];
    if (tracks.count == 0) {
        NSNumber *retryCount = objc_getAssociatedObject(item, YTSSRetryKey);
        NSInteger nextRetry = retryCount.integerValue + 1;
        if (nextRetry <= 12) {
            objc_setAssociatedObject(item, YTSSRetryKey, @(nextRetry), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [[YTSSSilenceController sharedController] attachToPlayer:player item:item reason:@"retry"];
            });
        }
        return;
    }

    YTSSPlayerSession *session = [[YTSSPlayerSession alloc] initWithPlayer:player item:item];
    objc_setAssociatedObject(item, YTSSSessionKey, session, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self.sessions addObject:session];
    [session start];
    NSLog(@"[YTSkipSilence] Attached reader/time-observer session (%@)", reason ?: @"unknown");
}

@end

static double YTSSWindowDuration(void) {
    return YTSSBoolDefault(YTSS_AGGRESSIVE_KEY, NO) ? 0.060 : 0.085;
}

static double YTSSThresholdDB(void) {
    return YTSSBoolDefault(YTSS_AGGRESSIVE_KEY, NO) ? -38.0 : -43.0;
}

static double YTSSMinimumSilenceDuration(void) {
    return YTSSBoolDefault(YTSS_AGGRESSIVE_KEY, NO) ? 0.14 : 0.24;
}

static float YTSSSilenceRate(void) {
    return YTSSBoolDefault(YTSS_AGGRESSIVE_KEY, NO) ? 3.25f : 2.50f;
}

static BOOL YTSSRangeContainsTime(CMTimeRange range, CMTime time) {
    if (!CMTIME_IS_NUMERIC(time) || !CMTIMERANGE_IS_VALID(range)) return NO;
    CMTime end = CMTimeRangeGetEnd(range);
    return CMTimeCompare(time, range.start) >= 0 && CMTimeCompare(time, end) < 0;
}

static NSArray<NSValue *> *YTSSAnalyzeSilentRanges(AVAsset *asset) {
    if (!asset) return @[];

    NSArray<AVAssetTrack *> *tracks = [asset tracksWithMediaType:AVMediaTypeAudio];
    AVAssetTrack *audioTrack = tracks.firstObject;
    if (!audioTrack) return @[];

    NSError *readerError = nil;
    AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset error:&readerError];
    if (!reader || readerError) {
        NSLog(@"[YTSkipSilence] AVAssetReader init failed: %@", readerError);
        return @[];
    }

    NSDictionary *settings = @{
        AVFormatIDKey: @(kAudioFormatLinearPCM),
        AVLinearPCMIsFloatKey: @YES,
        AVLinearPCMBitDepthKey: @32,
        AVLinearPCMIsNonInterleaved: @NO,
    };

    AVAssetReaderTrackOutput *output = [[AVAssetReaderTrackOutput alloc] initWithTrack:audioTrack outputSettings:settings];
    output.alwaysCopiesSampleData = NO;
    if (![reader canAddOutput:output]) {
        NSLog(@"[YTSkipSilence] Could not add audio reader output");
        return @[];
    }
    [reader addOutput:output];

    if (![reader startReading]) {
        NSLog(@"[YTSkipSilence] AVAssetReader start failed: %@", reader.error);
        return @[];
    }

    NSMutableArray<NSValue *> *ranges = [NSMutableArray array];
    CMTime activeStart = kCMTimeInvalid;
    CMTime activeEnd = kCMTimeInvalid;
    double thresholdDB = YTSSThresholdDB();
    double minimumSilence = YTSSMinimumSilenceDuration();
    double windowDuration = YTSSWindowDuration();

    CMSampleBufferRef sampleBuffer = NULL;
    while ((sampleBuffer = [output copyNextSampleBuffer])) {
        CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sampleBuffer);
        if (!block) {
            CFRelease(sampleBuffer);
            continue;
        }

        CMTime presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
        CMTime sampleDuration = CMSampleBufferGetDuration(sampleBuffer);
        if (!CMTIME_IS_NUMERIC(sampleDuration) || CMTimeGetSeconds(sampleDuration) <= 0.0) {
            CMItemCount count = CMSampleBufferGetNumSamples(sampleBuffer);
            sampleDuration = CMTimeMakeWithSeconds(MAX(windowDuration, 0.02) * (double)MAX(count, 1), NSEC_PER_SEC);
        }

        size_t byteLength = CMBlockBufferGetDataLength(block);
        NSMutableData *data = [NSMutableData dataWithLength:byteLength];
        if (CMBlockBufferCopyDataBytes(block, 0, byteLength, data.mutableBytes) != kCMBlockBufferNoErr || byteLength < sizeof(float)) {
            CFRelease(sampleBuffer);
            continue;
        }

        const float *samples = (const float *)data.bytes;
        NSUInteger sampleCount = byteLength / sizeof(float);
        double sumSquares = 0.0;
        for (NSUInteger i = 0; i < sampleCount; i++) {
            double sample = samples[i];
            sumSquares += sample * sample;
        }
        double rms = sampleCount ? sqrt(sumSquares / (double)sampleCount) : 0.0;
        double db = 20.0 * log10(MAX(rms, 0.000001));
        BOOL silent = db < thresholdDB;

        if (silent) {
            if (!CMTIME_IS_VALID(activeStart)) {
                activeStart = presentationTime;
            }
            activeEnd = CMTimeAdd(presentationTime, sampleDuration);
        } else if (CMTIME_IS_VALID(activeStart) && CMTIME_IS_VALID(activeEnd)) {
            CMTime duration = CMTimeSubtract(activeEnd, activeStart);
            if (CMTimeGetSeconds(duration) >= minimumSilence) {
                [ranges addObject:[NSValue valueWithCMTimeRange:CMTimeRangeFromTimeToTime(activeStart, activeEnd)]];
            }
            activeStart = kCMTimeInvalid;
            activeEnd = kCMTimeInvalid;
        }

        CFRelease(sampleBuffer);
    }

    if (CMTIME_IS_VALID(activeStart) && CMTIME_IS_VALID(activeEnd)) {
        CMTime duration = CMTimeSubtract(activeEnd, activeStart);
        if (CMTimeGetSeconds(duration) >= minimumSilence) {
            [ranges addObject:[NSValue valueWithCMTimeRange:CMTimeRangeFromTimeToTime(activeStart, activeEnd)]];
        }
    }

    if (reader.status == AVAssetReaderStatusFailed) {
        NSLog(@"[YTSkipSilence] AVAssetReader failed: %@", reader.error);
    }

    return ranges.copy;
}

@implementation YTSSPlayerSession

- (instancetype)initWithPlayer:(AVPlayer *)player item:(AVPlayerItem *)item {
    self = [super init];
    if (self) {
        _player = player;
        _item = item;
        _silentRanges = @[];
        _lastVoiceRate = 1.0f;
    }
    return self;
}

- (void)dealloc {
    AVPlayer *player = self.player;
    if (player && self.timeObserver) {
        [player removeTimeObserver:self.timeObserver];
    }
}

- (void)start {
    [self installTimeObserver];
    [self startAnalysisIfNeeded];
}

- (void)installTimeObserver {
    AVPlayer *player = self.player;
    if (!player || self.timeObserver) return;

    __weak typeof(self) weakSelf = self;
    CMTime interval = CMTimeMakeWithSeconds(0.075, NSEC_PER_SEC);
    self.timeObserver = [player addPeriodicTimeObserverForInterval:interval queue:dispatch_get_main_queue() usingBlock:^(CMTime time) {
        [weakSelf tickAtTime:time];
    }];
}

- (void)startAnalysisIfNeeded {
    if (self.analysisStarted) return;
    self.analysisStarted = YES;

    AVAsset *asset = self.item.asset;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSArray<NSValue *> *ranges = YTSSAnalyzeSilentRanges(asset);
        dispatch_async(dispatch_get_main_queue(), ^{
            YTSSPlayerSession *strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.silentRanges = ranges ?: @[];
            strongSelf.analysisFinished = YES;
            NSLog(@"[YTSkipSilence] Analysis finished: %lu silent ranges", (unsigned long)strongSelf.silentRanges.count);
        });
    });
}

- (void)tickAtTime:(CMTime)time {
    YTSSSilenceController *controller = [YTSSSilenceController sharedController];
    AVPlayer *player = self.player;
    if (!player || !controller.enabled || player.rate <= 0.01f) {
        [self restoreRateIfNeeded];
        return;
    }

    if (!self.analysisFinished || self.silentRanges.count == 0) {
        return;
    }

    BOOL inSilentRange = NO;
    CMTimeRange matchedRange = kCMTimeRangeInvalid;
    for (NSValue *value in self.silentRanges) {
        CMTimeRange range = value.CMTimeRangeValue;
        if (YTSSRangeContainsTime(range, time)) {
            inSilentRange = YES;
            matchedRange = range;
            break;
        }
    }

    if (!inSilentRange) {
        self.suppressUntilVoice = NO;
        [self restoreRateIfNeeded];
        if (player.rate > 0.05f && player.rate < 2.25f) {
            self.lastVoiceRate = player.rate;
        }
        return;
    }

    if (controller.jumpMode) {
        if (self.suppressUntilVoice) return;
        CFTimeInterval now = CACurrentMediaTime();
        if (now - self.lastSkipAt < 0.12) return;
        self.lastSkipAt = now;
        self.suppressUntilVoice = YES;

        CMTime target = CMTimeRangeGetEnd(matchedRange);
        CMTime duration = self.item.duration;
        if (CMTIME_IS_NUMERIC(duration) && CMTimeCompare(target, duration) > 0) {
            target = duration;
        }
        if (CMTIME_IS_NUMERIC(target) && CMTimeCompare(target, time) > 0) {
            [player seekToTime:target toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
        }
    } else {
        float targetRate = YTSSSilenceRate();
        if (player.rate > 0.05f && player.rate < 2.25f) {
            self.lastVoiceRate = player.rate;
        }
        if (fabsf(player.rate - targetRate) > 0.05f) {
            self.currentlySpeeding = YES;
            player.rate = targetRate;
        }
    }
}

- (void)restoreRateIfNeeded {
    AVPlayer *player = self.player;
    if (!player) return;
    if (self.currentlySpeeding && player.rate > 2.25f && self.lastVoiceRate > 0.05f) {
        player.rate = self.lastVoiceRate;
    }
    self.currentlySpeeding = NO;
}

@end
