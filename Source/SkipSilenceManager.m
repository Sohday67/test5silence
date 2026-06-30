//
//  SkipSilenceManager.m
//  YTSkipSilence
//

#import "SkipSilenceManager.h"
#import "SkipSilenceSettings.h"
#import "SkipSilenceDetector.h"
#import "SkipSilenceAudioTap.h"

#if DEBUG
  #define SSLog(fmt, ...) NSLog(@"[YTSkipSilence][mgr] " fmt, ##__VA_ARGS__)
#else
  #define SSLog(fmt, ...) do { } while (0)
#endif

@interface SkipSilenceManager () <SkipSilenceDetectorDelegate, SkipSilenceAudioTapDelegate>
@property (nonatomic, strong) NSLock *stateLock;
@property (nonatomic, weak) AVPlayer *player;
@property (nonatomic, strong) AVPlayerItem *observedItem;
@property (nonatomic, strong) SkipSilenceAudioTap *audioTap;
@property (nonatomic, strong) SkipSilenceDetector *detector;
@property (nonatomic, strong) id timeObserverToken;
@property (nonatomic, assign) NSTimeInterval lastPlaybackTime;
@property (nonatomic, assign) BOOL skipInFlight;
@end

@implementation SkipSilenceManager

- (instancetype)init {
    self = [super init];
    if (self) {
        _stateLock = [[NSLock alloc] init];
        _lastPlaybackTime = 0;
        _skipInFlight = NO;
    }
    return self;
}

- (void)dealloc {
    [self detach];
}

#pragma mark - Public

- (BOOL)isMonitoring {
    [self.stateLock lock];
    BOOL r = (_audioTap != nil && _audioTap.isAttached);
    [self.stateLock unlock];
    return r;
}

- (void)attachToPlayer:(AVPlayer *)player {
    [self detach];
    if (player == nil) return;

    SkipSilenceSettings *s = [SkipSilenceSettings shared];
    if (!s.isEnabled) {
        SSLog(@"attach requested but tweak is disabled — ignoring");
        return;
    }

    [self.stateLock lock];
    _player = player;
    AVPlayerItem *item = [player currentItem];
    _observedItem = item;
    [self.stateLock unlock];

    if (item == nil) {
        SSLog(@"player has no currentItem; will observe KVO on player");
        [self observePlayerForItemChange:player];
        return;
    }

    [self observeItem:item];
    [self maybeInstallTapOnItem:item];
}

- (void)detach {
    [self.stateLock lock];
    AVPlayer *p = _player;
    AVPlayerItem *item = _observedItem;
    id token = _timeObserverToken;
    SkipSilenceAudioTap *tap = _audioTap;
    _player = nil;
    _observedItem = nil;
    _timeObserverToken = nil;
    _audioTap = nil;
    _detector = nil;
    [self.stateLock unlock];

    if (token && p) {
        @try { [p removeTimeObserver:token]; } @catch (id e) {}
    }
    if (item) {
        @try { [item removeObserver:self forKeyPath:@"status"]; } @catch (id e) {}
    }
    if (p) {
        @try { [p removeObserver:self forKeyPath:@"currentItem"]; } @catch (id e) {}
    }
    if (tap) [tap detach];
    SSLog(@"detached");
}

- (void)updatePlaybackTime:(NSTimeInterval)seconds {
    [self.stateLock lock];
    _lastPlaybackTime = seconds;
    [self.stateLock unlock];
}

#pragma mark - Private: observations

- (void)observePlayerForItemChange:(AVPlayer *)player {
    @try {
        [player addObserver:self
                 forKeyPath:@"currentItem"
                    options:NSKeyValueObservingOptionNew
                    context:NULL];
    } @catch (id e) {
        SSLog(@"failed to observe player.currentItem: %@", e);
    }
}

- (void)observeItem:(AVPlayerItem *)item {
    @try {
        [item addObserver:self
               forKeyPath:@"status"
                  options:NSKeyValueObservingOptionNew
                  context:NULL];
    } @catch (id e) {
        SSLog(@"failed to observe item.status: %@", e);
    }
}

- (void)maybeInstallTapOnItem:(AVPlayerItem *)item {
    [self.stateLock lock];
    BOOL already = (_audioTap != nil);
    [self.stateLock unlock];
    if (already) return;

    SkipSilenceSettings *s = [SkipSilenceSettings shared];
    if (!s.isEnabled) return;

    SkipSilenceAudioTap *tap = [[SkipSilenceAudioTap alloc] init];
    tap.delegate = self;
    BOOL ok = [tap attachToPlayerItem:item];
    if (!ok) {
        SSLog(@"tap attach failed");
        return;
    }

    SkipSilenceDetector *det = [[SkipSilenceDetector alloc] initWithFormat:(AudioStreamBasicDescription){0}];
    det.delegate = self;
    det.silenceThresholdDB = s.silenceThresholdDB;
    det.minSilenceDuration = s.minSilenceDuration;
    det.cooldown = s.skipCooldown;
    det.verboseLogging = s.verboseLogging;

    [self.stateLock lock];
    _audioTap = tap;
    _detector = det;
    [self.stateLock unlock];

    SSLog(@"tap + detector installed");
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary *)change
                       context:(void *)context {
    if ([keyPath isEqualToString:@"status"]) {
        AVPlayerItem *item = object;
        if (item.status == AVPlayerItemStatusReadyToPlay) {
            SSLog(@"playerItem ready — installing tap");
            dispatch_async(dispatch_get_main_queue(), ^{
                [self maybeInstallTapOnItem:item];
            });
        }
    } else if ([keyPath isEqualToString:@"currentItem"]) {
        AVPlayer *p = self.player;
        AVPlayerItem *newItem = [p currentItem];
        SSLog(@"player.currentItem changed → re-attach");
        dispatch_async(dispatch_get_main_queue(), ^{
            [self attachToPlayer:p];
        });
    }
}

#pragma mark - SkipSilenceAudioTapDelegate

- (void)audioTap:(SkipSilenceAudioTap *)tap
   didReceiveAudio:(const AudioBufferList *)bufferList
       framesCount:(UInt32)frames
            format:(AudioStreamBasicDescription)format {
    // Lazily sync the detector's format if it was created with a zeroed one.
    SkipSilenceDetector *det = self.detector;
    if (det == nil) return;

    static dispatch_once_t once;
    static AudioStreamBasicDescription lastSynced = {0};
    @synchronized(self) {
        if (format.mSampleRate > 0 &&
            (lastSynced.mSampleRate != format.mSampleRate ||
             lastSynced.mChannelsPerFrame != format.mChannelsPerFrame ||
             lastSynced.mFormatFlags != format.mFormatFlags)) {
            lastSynced = format;
            // Re-create the detector with the real format so its RMS computation
            // knows whether samples are float or int, interleaved or planar.
            SkipSilenceSettings *s = [SkipSilenceSettings shared];
            SkipSilenceDetector *nd = [[SkipSilenceDetector alloc] initWithFormat:format];
            nd.delegate = self;
            nd.silenceThresholdDB = s.silenceThresholdDB;
            nd.minSilenceDuration = s.minSilenceDuration;
            nd.cooldown = s.skipCooldown;
            nd.verboseLogging = s.verboseLogging;
            self.detector = nd;
            det = nd;
        }
    }

    [det processAudio:bufferList framesCount:frames];
}

#pragma mark - SkipSilenceDetectorDelegate

- (void)detector:(SkipSilenceDetector *)detector
    didDetectSilenceWithDuration:(NSTimeInterval)durationSeconds
                  atHostTime:(UInt64)hostTime {
    [self performSkipForSilenceDuration:durationSeconds];
}

#pragma mark - Skip

- (void)performSkipForSilenceDuration:(NSTimeInterval)silenceDuration {
    [self.stateLock lock];
    if (_skipInFlight) {
        [self.stateLock unlock];
        return;
    }
    _skipInFlight = YES;
    AVPlayer *p = _player;
    NSTimeInterval current = _lastPlaybackTime;
    [self.stateLock unlock];

    if (p == nil) {
        [self.stateLock lock]; _skipInFlight = NO; [self.stateLock unlock];
        return;
    }

    SkipSilenceSettings *s = [SkipSilenceSettings shared];
    // Skip distance: silence × multiplier, but never less than the silence
    // itself (otherwise we'd just re-enter it) and capped at 10 seconds so
    // we don't jump past content we can't see.
    NSTimeInterval skipBy = silenceDuration * s.silenceSkipSpeedMultiplier;
    skipBy = MAX(skipBy, silenceDuration + 0.1);
    skipBy = MIN(skipBy, 10.0);

    // If the user wants backward-skipping too AND the silence run started
    // before our current position, we could rewind to silenceStart first.
    // We don't track silence start in player time (only host time), so we
    // approximate: just skip forward from current.
    NSTimeInterval target = current + skipBy;
    if (target <= 0) target = 0;

    CMTime targetTime = CMTimeMakeWithSeconds(target, 600);
    SSLog(@"SKIP: from %.2fs by %.2fs (silence=%.2fs × %.1f) → %.2fs",
          current, skipBy, silenceDuration, s.silenceSkipSpeedMultiplier, target);

    // Use precise (zero-tolerance) seeking so we land past the silence,
    // not at a nearby keyframe that might still be inside it. The cost is
    // minor — skips are infrequent and the user has already accepted the
    // visual hitch of a seek.
    __weak typeof(self) weakSelf = self;
    [p seekToTime:targetTime
        toleranceBefore:kCMTimeZero
         toleranceAfter:kCMTimeZero
      completionHandler:^(BOOL finished) {
        __strong typeof(weakSelf) sself = weakSelf;
        if (!sself) return;
        [sself.stateLock lock];
        sself->_skipInFlight = NO;
        [sself.stateLock unlock];
        [sself.detector reset];

        if (finished && [sself.delegate respondsToSelector:@selector(manager:didSkipSilenceWithDuration:newPlaybackTime:)]) {
            [sself.delegate manager:sself
                didSkipSilenceWithDuration:skipBy
                            newPlaybackTime:targetTime];
        }
    }];
}

@end
