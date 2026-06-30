//
//  SkipSilenceAudioTap.m
//  YTSkipSilence
//

#import "SkipSilenceAudioTap.h"

#if DEBUG
  #define SSLog(fmt, ...) NSLog(@"[YTSkipSilence][tap] " fmt, ##__VA_ARGS__)
#else
  #define SSLog(fmt, ...) do { } while (0)
#endif

// Bridging context handed to the MTAudioProcessingTap callbacks.
typedef struct {
    __unsafe_unretained SkipSilenceAudioTap *tap;
    AudioStreamBasicDescription format;
} SkipSilenceTapContext;

// Forward declarations for the MTAudioProcessingTap C callbacks (defined at the
// bottom of the file). These must match Apple's callback typedefs exactly:
// only the init callback receives clientInfo / produces tap storage; the rest
// recover state via MTAudioProcessingTapGetStorage(tap).
static void tapInitCallback(MTAudioProcessingTapRef tap, void *clientInfo, void **tapStorageOut);
static void tapFinalizeCallback(MTAudioProcessingTapRef tap);
static void tapPrepareCallback(MTAudioProcessingTapRef tap, CMItemCount maxFrames,
                               const AudioStreamBasicDescription *processingFormat);
static void tapUnprepareCallback(MTAudioProcessingTapRef tap);
static void tapProcessCallback(MTAudioProcessingTapRef tap, CMItemCount numberFrames,
                               MTAudioProcessingTapFlags flags, AudioBufferList *bufferListOut,
                               CMItemCount *numberFramesOut, MTAudioProcessingTapFlags *processFlagsOut);

@interface SkipSilenceAudioTap ()
@property (nonatomic, strong) NSLock *stateLock;
@property (nonatomic, assign) MTAudioProcessingTapRef tapRef;
@property (nonatomic, weak) AVPlayerItem *playerItem;
@property (nonatomic, strong) NSMutableArray<AVAudioMixInputParameters *> *originalMixParams;
@property (nonatomic, assign) AudioStreamBasicDescription lastFormat;
@property (nonatomic, assign) BOOL hasLastFormat;
@end

@implementation SkipSilenceAudioTap

- (instancetype)init {
    self = [super init];
    if (self) {
        _stateLock = [[NSLock alloc] init];
        _originalMixParams = [[NSMutableArray alloc] init];
    }
    return self;
}

- (void)dealloc {
    [self detach];
}

- (BOOL)isAttached {
    [self.stateLock lock];
    BOOL r = (_tapRef != NULL);
    [self.stateLock unlock];
    return r;
}

#pragma mark - Attach / detach

- (BOOL)attachToPlayerItem:(AVPlayerItem *)playerItem {
    if (playerItem == nil) return NO;
    [self detach];

    [self.stateLock lock];
    _playerItem = playerItem;
    [self.stateLock unlock];

    // Step 1: create the MTAudioProcessingTap.
    MTAudioProcessingTapCallbacks callbacks = {
        .version = kMTAudioProcessingTapCallbacksVersion_0,
        .clientInfo = (__bridge void *)self,
        .init = &tapInitCallback,
        .finalize = &tapFinalizeCallback,
        .prepare = &tapPrepareCallback,
        .unprepare = &tapUnprepareCallback,
        .process = &tapProcessCallback,
    };

    OSStatus status;
    MTAudioProcessingTapRef newTap = NULL;
    status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                                        kMTAudioProcessingTapCreationFlag_PreEffects,
                                        &newTap);
    if (status != noErr || newTap == NULL) {
        SSLog(@"MTAudioProcessingTapCreate failed: %d", (int)status);
        return NO;
    }

    [self.stateLock lock];
    _tapRef = newTap;
    [self.stateLock unlock];

    // Step 2: build an AVAudioMix that installs the tap on every audio track.
    AVAsset *asset = [playerItem asset];
    NSArray<AVAssetTrack *> *audioTracks =
        [asset tracksWithMediaType:AVMediaTypeAudio];
    if (audioTracks.count == 0) {
        SSLog(@"asset has no audio tracks");
        [self detach];
        return NO;
    }

    AVMutableAudioMix *mix = [AVMutableAudioMix audioMix];
    NSMutableArray<AVMutableAudioMixInputParameters *> *params =
        [[NSMutableArray alloc] initWithCapacity:audioTracks.count];

    for (AVAssetTrack *track in audioTracks) {
        AVMutableAudioMixInputParameters *p =
            [AVMutableAudioMixInputParameters audioMixInputParametersWithTrack:track];
        // The AVFoundation property is `audioTapProcessor` (a retained
        // NSObject-attributed MTAudioProcessingTapRef), not `audioProcessingTap`.
        [p setAudioTapProcessor:newTap];
        [params addObject:p];
    }
    mix.inputParameters = params;
    playerItem.audioMix = mix;

    SSLog(@"attached to %lu audio track(s)", (unsigned long)audioTracks.count);
    return YES;
}

- (void)detach {
    [self.stateLock lock];
    MTAudioProcessingTapRef tap = _tapRef;
    AVPlayerItem *pi = _playerItem;
    _tapRef = NULL;
    _playerItem = nil;
    [self.stateLock unlock];

    if (pi != nil) {
        // Clear the audioMix so AVFoundation releases the tap.
        @try { pi.audioMix = nil; } @catch (id e) {}
    }
    if (tap != NULL) {
        // MTAudioProcessingTapRef is a CF type; there is no
        // MTAudioProcessingTapRelease — balance MTAudioProcessingTapCreate's
        // +1 with CFRelease.
        CFRelease(tap);
        SSLog(@"detached");
    }
}

#pragma mark - MTAudioProcessingTap callbacks (C)

static void tapInitCallback(MTAudioProcessingTapRef tap, void *clientInfo, void **tapStorageOut) {
    // No per-tap storage beyond the bridge.
    *tapStorageOut = clientInfo;
}

static void tapFinalizeCallback(MTAudioProcessingTapRef tap) {
    // Nothing to free — the bridged tap storage is not retained.
}

static void tapPrepareCallback(MTAudioProcessingTapRef tap,
                               CMItemCount maxFrames,
                               const AudioStreamBasicDescription *processingFormat) {
    // Only the init callback receives clientInfo; everyone else reads it back
    // out of the tap's storage (set in tapInitCallback).
    SkipSilenceAudioTap *self = (__bridge SkipSilenceAudioTap *)MTAudioProcessingTapGetStorage(tap);
    if (processingFormat != NULL) {
        [self.stateLock lock];
        self.lastFormat = *processingFormat;
        self.hasLastFormat = YES;
        [self.stateLock unlock];
        SSLog(@"prepare: sr=%.0f ch=%u bps=%u flags=0x%x",
              processingFormat->mSampleRate,
              (unsigned)processingFormat->mChannelsPerFrame,
              (unsigned)processingFormat->mBitsPerChannel,
              (unsigned)processingFormat->mFormatFlags);
    }
}

static void tapUnprepareCallback(MTAudioProcessingTapRef tap) {
    SkipSilenceAudioTap *self = (__bridge SkipSilenceAudioTap *)MTAudioProcessingTapGetStorage(tap);
    [self.stateLock lock];
    self.hasLastFormat = NO;
    [self.stateLock unlock];
}

static void tapProcessCallback(MTAudioProcessingTapRef tap,
                               CMItemCount numberFrames,
                               MTAudioProcessingTapFlags flags,
                               AudioBufferList *bufferListOut,
                               CMItemCount *numberFramesOut,
                               MTAudioProcessingTapFlags *processFlagsOut) {
    void *clientInfo = MTAudioProcessingTapGetStorage(tap);
    SkipSilenceAudioTap *self = (__bridge SkipSilenceAudioTap *)clientInfo;

    // Pull source frames from the upstream audio.
    OSStatus status = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListOut,
                                                         NULL, NULL, numberFramesOut);
    if (status != noErr) {
        *numberFramesOut = 0;
        return;
    }

    // Pass through unmodified — we only inspect the audio, never modify it.
    *processFlagsOut = 0;

    // Snapshot format under lock; deliver to delegate.
    AudioStreamBasicDescription fmt = {0};
    BOOL hasFmt = NO;
    [self.stateLock lock];
    if (self.hasLastFormat) {
        fmt = self.lastFormat;
        hasFmt = YES;
    }
    [self.stateLock unlock];

    if (hasFmt && self.delegate != nil) {
        [self.delegate audioTap:self
                  didReceiveAudio:bufferListOut
                      framesCount:(UInt32)*numberFramesOut
                           format:fmt];
    }
}

@end
