#import "YTSSSilenceController.h"
#import "YTSSDefines.h"
#import "YTSSHUD.h"
#import <AudioToolbox/AudioToolbox.h>
#if __has_include(<MediaToolbox/MTAudioProcessingTap.h>)
#import <MediaToolbox/MTAudioProcessingTap.h>
#else
typedef struct opaqueMTAudioProcessingTap *MTAudioProcessingTapRef;
typedef uint32_t MTAudioProcessingTapFlags;
typedef uint32_t MTAudioProcessingTapCreationFlags;
static const MTAudioProcessingTapCreationFlags kMTAudioProcessingTapCreationFlag_PreEffects = (1u << 0);
static const MTAudioProcessingTapCreationFlags kMTAudioProcessingTapCreationFlag_PostEffects = (1u << 1);
static const uint32_t kMTAudioProcessingTapCallbacksVersion_0 = 0;
typedef void (*MTAudioProcessingTapInitCallback)(MTAudioProcessingTapRef tap, void *clientInfo, void **tapStorageOut);
typedef void (*MTAudioProcessingTapFinalizeCallback)(MTAudioProcessingTapRef tap);
typedef void (*MTAudioProcessingTapPrepareCallback)(MTAudioProcessingTapRef tap, CMItemCount maxFrames, const AudioStreamBasicDescription *processingFormat);
typedef void (*MTAudioProcessingTapUnprepareCallback)(MTAudioProcessingTapRef tap);
typedef void (*MTAudioProcessingTapProcessCallback)(MTAudioProcessingTapRef tap, CMItemCount numberFrames, MTAudioProcessingTapFlags flags, AudioBufferList *bufferListInOut, CMItemCount *numberFramesOut, MTAudioProcessingTapFlags *flagsOut);
typedef struct MTAudioProcessingTapCallbacks {
    uint32_t version;
    void *clientInfo;
    MTAudioProcessingTapInitCallback init;
    MTAudioProcessingTapFinalizeCallback finalize;
    MTAudioProcessingTapPrepareCallback prepare;
    MTAudioProcessingTapUnprepareCallback unprepare;
    MTAudioProcessingTapProcessCallback process;
} MTAudioProcessingTapCallbacks;
#endif
#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <math.h>

static const void *YTSSSessionKey = &YTSSSessionKey;
static const void *YTSSRetryKey = &YTSSRetryKey;


typedef OSStatus (*YTSSMTAudioProcessingTapCreateFunction)(CFAllocatorRef allocator,
                                                           const MTAudioProcessingTapCallbacks *callbacks,
                                                           MTAudioProcessingTapCreationFlags flags,
                                                           MTAudioProcessingTapRef *tapOut);
typedef OSStatus (*YTSSMTAudioProcessingTapGetSourceAudioFunction)(MTAudioProcessingTapRef tap,
                                                                  CMItemCount numberFrames,
                                                                  AudioBufferList *bufferListInOut,
                                                                  MTAudioProcessingTapFlags *flagsOut,
                                                                  CMTimeRange *timeRangeOut,
                                                                  CMItemCount *numberFramesOut);
typedef void *(*YTSSMTAudioProcessingTapGetStorageFunction)(MTAudioProcessingTapRef tap);

static void *YTSSMediaToolboxHandle(void) {
    static void *handle = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        handle = dlopen("/System/Library/Frameworks/MediaToolbox.framework/MediaToolbox", RTLD_LAZY | RTLD_LOCAL);
        if (!handle) {
            handle = dlopen("MediaToolbox.framework/MediaToolbox", RTLD_LAZY | RTLD_LOCAL);
        }
        if (!handle) {
            NSLog(@"[YTSkipSilence] MediaToolbox unavailable: %s", dlerror());
        }
    });
    return handle;
}

static void *YTSSMediaToolboxSymbol(const char *symbol) {
    void *handle = YTSSMediaToolboxHandle();
    return handle ? dlsym(handle, symbol) : NULL;
}

static YTSSMTAudioProcessingTapCreateFunction YTSSMTAudioProcessingTapCreate(void) {
    static YTSSMTAudioProcessingTapCreateFunction function = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        function = (YTSSMTAudioProcessingTapCreateFunction)YTSSMediaToolboxSymbol("MTAudioProcessingTapCreate");
    });
    return function;
}

static YTSSMTAudioProcessingTapGetSourceAudioFunction YTSSMTAudioProcessingTapGetSourceAudio(void) {
    static YTSSMTAudioProcessingTapGetSourceAudioFunction function = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        function = (YTSSMTAudioProcessingTapGetSourceAudioFunction)YTSSMediaToolboxSymbol("MTAudioProcessingTapGetSourceAudio");
    });
    return function;
}

static YTSSMTAudioProcessingTapGetStorageFunction YTSSMTAudioProcessingTapGetStorage(void) {
    static YTSSMTAudioProcessingTapGetStorageFunction function = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        function = (YTSSMTAudioProcessingTapGetStorageFunction)YTSSMediaToolboxSymbol("MTAudioProcessingTapGetStorage");
    });
    return function;
}

static BOOL YTSSMTAudioTapIsAvailable(void) {
    return YTSSMTAudioProcessingTapCreate() && YTSSMTAudioProcessingTapGetSourceAudio() && YTSSMTAudioProcessingTapGetStorage();
}


static void YTSSTapInit(MTAudioProcessingTapRef tap, void *clientInfo, void **tapStorageOut);
static void YTSSTapFinalize(MTAudioProcessingTapRef tap);
static void YTSSTapPrepare(MTAudioProcessingTapRef tap, CMItemCount maxFrames, const AudioStreamBasicDescription *processingFormat);
static void YTSSTapUnprepare(MTAudioProcessingTapRef tap);
static void YTSSTapProcess(MTAudioProcessingTapRef tap,
                           CMItemCount numberFrames,
                           MTAudioProcessingTapFlags flags,
                           AudioBufferList *bufferListInOut,
                           CMItemCount *numberFramesOut,
                           MTAudioProcessingTapFlags *flagsOut);

@class YTSSPlayerSession;

@interface YTSSPlayerSession : NSObject
@property (nonatomic, weak) AVPlayer *player;
@property (nonatomic, weak) AVPlayerItem *item;
@property (nonatomic, assign) AudioStreamBasicDescription format;
@property (nonatomic, assign) BOOL hasFormat;
@property (nonatomic, assign) BOOL currentlySilent;
@property (nonatomic, assign) CFTimeInterval silenceBeganAt;
@property (nonatomic, assign) CFTimeInterval lastSkipAt;
@property (nonatomic, assign) CFTimeInterval lastVoiceAt;
@property (nonatomic, assign) float lastVoiceRate;
@property (nonatomic, assign) double smoothedDB;
- (instancetype)initWithPlayer:(AVPlayer *)player item:(AVPlayerItem *)item;
- (void)handleDecibels:(double)decibels;
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
    AVAssetTrack *audioTrack = tracks.firstObject;
    if (!audioTrack) {
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

    if (!YTSSMTAudioTapIsAvailable()) {
        NSLog(@"[YTSkipSilence] MTAudioProcessingTap symbols are unavailable");
        return;
    }

    MTAudioProcessingTapCallbacks callbacks;
    callbacks.version = kMTAudioProcessingTapCallbacksVersion_0;
    void *retainedSession = (__bridge_retained void *)session;
    callbacks.clientInfo = retainedSession;
    callbacks.init = YTSSTapInit;
    callbacks.finalize = YTSSTapFinalize;
    callbacks.prepare = YTSSTapPrepare;
    callbacks.unprepare = YTSSTapUnprepare;
    callbacks.process = YTSSTapProcess;

    MTAudioProcessingTapRef tap = NULL;
    OSStatus status = YTSSMTAudioProcessingTapCreate()(kCFAllocatorDefault,
                                                       &callbacks,
                                                       kMTAudioProcessingTapCreationFlag_PostEffects,
                                                       &tap);
    if (status != noErr || tap == NULL) {
        if (retainedSession) {
            id releasedSession = CFBridgingRelease(retainedSession);
            (void)releasedSession;
        }
        NSLog(@"[YTSkipSilence] Failed to create audio tap: %d", (int)status);
        return;
    }

    AVMutableAudioMixInputParameters *tapParameters = [AVMutableAudioMixInputParameters audioMixInputParametersWithTrack:audioTrack];
    [tapParameters setAudioTapProcessor:tap];

    NSMutableArray *inputParameters = [NSMutableArray array];
    if (item.audioMix.inputParameters.count > 0) {
        [inputParameters addObjectsFromArray:item.audioMix.inputParameters];
    }
    [inputParameters addObject:tapParameters];

    AVMutableAudioMix *mix = [AVMutableAudioMix audioMix];
    mix.inputParameters = inputParameters;
    item.audioMix = mix;

    objc_setAssociatedObject(item, YTSSSessionKey, session, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self.sessions addObject:session];
    CFRelease(tap);

    NSLog(@"[YTSkipSilence] Attached audio tap (%@)", reason ?: @"unknown");
}

@end

@implementation YTSSPlayerSession

- (instancetype)initWithPlayer:(AVPlayer *)player item:(AVPlayerItem *)item {
    self = [super init];
    if (self) {
        _player = player;
        _item = item;
        _lastVoiceRate = 1.0f;
        _smoothedDB = -90.0;
    }
    return self;
}

- (double)thresholdDB {
    return YTSSBoolDefault(YTSS_AGGRESSIVE_KEY, NO) ? -38.0 : -43.0;
}

- (double)minimumSilenceDuration {
    return YTSSBoolDefault(YTSS_AGGRESSIVE_KEY, NO) ? 0.12 : 0.20;
}

- (double)skipStepSeconds {
    return YTSSBoolDefault(YTSS_AGGRESSIVE_KEY, NO) ? 0.34 : 0.22;
}

- (float)silenceRate {
    return YTSSBoolDefault(YTSS_AGGRESSIVE_KEY, NO) ? 3.25f : 2.50f;
}

- (void)handleDecibels:(double)decibels {
    YTSSSilenceController *controller = [YTSSSilenceController sharedController];
    if (!controller.enabled) {
        [self restoreRateIfNeeded];
        return;
    }

    AVPlayer *player = self.player;
    if (!player || player.rate <= 0.01f) {
        [self restoreRateIfNeeded];
        return;
    }

    if (!self.currentlySilent && player.rate > 0.05f && player.rate < 2.25f) {
        self.lastVoiceRate = player.rate;
    }

    double alpha = self.smoothedDB < -89.0 ? 1.0 : 0.28;
    self.smoothedDB = (alpha * decibels) + ((1.0 - alpha) * self.smoothedDB);

    CFTimeInterval now = CACurrentMediaTime();
    BOOL silent = self.smoothedDB < [self thresholdDB];

    if (!silent) {
        self.currentlySilent = NO;
        self.silenceBeganAt = 0;
        self.lastVoiceAt = now;
        [self restoreRateIfNeeded];
        return;
    }

    if (!self.currentlySilent) {
        self.currentlySilent = YES;
        self.silenceBeganAt = now;
        return;
    }

    if (now - self.silenceBeganAt < [self minimumSilenceDuration]) return;

    if (controller.jumpMode) {
        if (now - self.lastSkipAt < 0.08) return;
        self.lastSkipAt = now;

        CMTime current = player.currentTime;
        CMTime duration = self.item.duration;
        if (CMTIME_IS_NUMERIC(current) && CMTIME_IS_NUMERIC(duration) && CMTimeCompare(current, duration) < 0) {
            CMTime delta = CMTimeMakeWithSeconds([self skipStepSeconds], NSEC_PER_SEC);
            CMTime target = CMTimeAdd(current, delta);
            if (CMTimeCompare(target, duration) > 0) target = duration;
            [player seekToTime:target toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
        }
    } else {
        float targetRate = [self silenceRate];
        if (fabsf(player.rate - targetRate) > 0.05f) {
            player.rate = targetRate;
        }
    }
}

- (void)restoreRateIfNeeded {
    AVPlayer *player = self.player;
    if (!player) return;
    if (player.rate > 2.25f && self.lastVoiceRate > 0.05f) {
        player.rate = self.lastVoiceRate;
    }
}

@end

static void YTSSTapInit(MTAudioProcessingTapRef tap, void *clientInfo, void **tapStorageOut) {
    *tapStorageOut = clientInfo;
}

static void YTSSTapFinalize(MTAudioProcessingTapRef tap) {
    YTSSMTAudioProcessingTapGetStorageFunction getStorage = YTSSMTAudioProcessingTapGetStorage();
    void *storage = getStorage ? getStorage(tap) : NULL;
    if (storage) {
        id releasedSession = CFBridgingRelease(storage);
        (void)releasedSession;
    }
}

static void YTSSTapPrepare(MTAudioProcessingTapRef tap, CMItemCount maxFrames, const AudioStreamBasicDescription *processingFormat) {
    YTSSMTAudioProcessingTapGetStorageFunction getStorage = YTSSMTAudioProcessingTapGetStorage();
    YTSSPlayerSession *session = getStorage ? (__bridge YTSSPlayerSession *)getStorage(tap) : nil;
    if (session && processingFormat) {
        session.format = *processingFormat;
        session.hasFormat = YES;
    }
}

static void YTSSTapUnprepare(MTAudioProcessingTapRef tap) {
}

static double YTSSDecibelsFromAudioBufferList(AudioBufferList *bufferList, AudioStreamBasicDescription format) {
    if (!bufferList) return -120.0;

    double sumSquares = 0.0;
    UInt64 sampleCount = 0;
    BOOL isFloat = (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0;
    UInt32 bits = format.mBitsPerChannel;

    for (UInt32 i = 0; i < bufferList->mNumberBuffers; i++) {
        AudioBuffer buffer = bufferList->mBuffers[i];
        if (!buffer.mData || buffer.mDataByteSize == 0) continue;

        if (isFloat && bits == 32) {
            Float32 *samples = (Float32 *)buffer.mData;
            UInt32 count = buffer.mDataByteSize / sizeof(Float32);
            for (UInt32 j = 0; j < count; j++) {
                double s = samples[j];
                sumSquares += s * s;
            }
            sampleCount += count;
        } else if (!isFloat && bits == 16) {
            SInt16 *samples = (SInt16 *)buffer.mData;
            UInt32 count = buffer.mDataByteSize / sizeof(SInt16);
            for (UInt32 j = 0; j < count; j++) {
                double s = (double)samples[j] / 32768.0;
                sumSquares += s * s;
            }
            sampleCount += count;
        }
    }

    if (sampleCount == 0) return -120.0;
    double rms = sqrt(sumSquares / (double)sampleCount);
    return 20.0 * log10(MAX(rms, 0.000001));
}

static void YTSSTapProcess(MTAudioProcessingTapRef tap,
                           CMItemCount numberFrames,
                           MTAudioProcessingTapFlags flags,
                           AudioBufferList *bufferListInOut,
                           CMItemCount *numberFramesOut,
                           MTAudioProcessingTapFlags *flagsOut) {
    YTSSMTAudioProcessingTapGetSourceAudioFunction getSourceAudio = YTSSMTAudioProcessingTapGetSourceAudio();
    if (!getSourceAudio) return;

    OSStatus status = getSourceAudio(tap,
                                     numberFrames,
                                     bufferListInOut,
                                     flagsOut,
                                     NULL,
                                     numberFramesOut);
    if (status != noErr) return;

    YTSSMTAudioProcessingTapGetStorageFunction getStorage = YTSSMTAudioProcessingTapGetStorage();
    YTSSPlayerSession *session = getStorage ? (__bridge YTSSPlayerSession *)getStorage(tap) : nil;
    if (!session.hasFormat) return;

    double decibels = YTSSDecibelsFromAudioBufferList(bufferListInOut, session.format);
    dispatch_async(dispatch_get_main_queue(), ^{
        [session handleDecibels:decibels];
    });
}
