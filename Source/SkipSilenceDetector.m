//
//  SkipSilenceDetector.m
//  YTSkipSilence
//

#import "SkipSilenceDetector.h"

#import <math.h>
#import <mach/mach_time.h>
#import <AudioToolbox/AudioToolbox.h>

#if DEBUG
  #define SSLog(fmt, ...) NSLog(@"[YTSkipSilence] " fmt, ##__VA_ARGS__)
#else
  #define SSLog(fmt, ...) do { } while (0)
#endif
#define SSVerbose(fmt, ...) \
    do { if (self.verboseLogging) NSLog(@"[YTSkipSilence][v] " fmt, ##__VA_ARGS__); } while (0)

@interface SkipSilenceDetector ()
{
    AudioStreamBasicDescription _format;
    double _sampleRate;
    UInt32 _channels;
    BOOL _isFloat;
    BOOL _isInterleaved;
}
@property (nonatomic, assign) BOOL inSilence;
@property (nonatomic, assign) NSTimeInterval silenceStartHostSeconds;
@property (nonatomic, assign) NSTimeInterval accumulatedSilenceSeconds;
@property (nonatomic, assign) NSTimeInterval lastSkipHostSeconds;
@property (nonatomic, assign) UInt64 frameCounter;
@property (nonatomic, assign) UInt64 hostTimeToSecondsDenominator;
@end

@implementation SkipSilenceDetector

- (instancetype)initWithFormat:(AudioStreamBasicDescription)format {
    self = [super init];
    if (self) {
        _format = format;
        _sampleRate = format.mSampleRate > 0 ? format.mSampleRate : 44100.0;
        _channels = format.mChannelsPerFrame > 0 ? format.mChannelsPerFrame : 2;
        _isFloat = (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0;
        _isInterleaved = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0;

        _silenceThresholdDB = -45.0f;
        _minSilenceDuration = 0.6f;
        _cooldown = 0.5f;
        _analysisWindowSeconds = 0.05f;

        _inSilence = NO;
        _silenceStartHostSeconds = 0;
        _accumulatedSilenceSeconds = 0;
        _lastSkipHostSeconds = -1000.0;
        _frameCounter = 0;

        SSLog(@"detector init: sr=%.0f ch=%u float=%d interleaved=%d",
              _sampleRate, (unsigned)_channels, (int)_isFloat, (int)_isInterleaved);
    }
    return self;
}

- (void)reset {
    @synchronized(self) {
        _inSilence = NO;
        _silenceStartHostSeconds = 0;
        _accumulatedSilenceSeconds = 0;
        _frameCounter = 0;
        SSVerbose(@"detector reset");
    }
}

#pragma mark - Sample processing

- (void)processAudio:(const AudioBufferList *)inBufferList
       framesCount:(UInt32)inNumberFrames {
    if (inNumberFrames == 0 || inBufferList == NULL) return;

    // Per-window RMS analysis. We process in fixed analysisWindowSeconds-sized
    // logical windows — if the incoming chunk is larger, we split it into
    // multiple windows; if smaller, we just analyze what we got.
    UInt32 framesPerWindow = (UInt32)(_analysisWindowSeconds * _sampleRate);
    if (framesPerWindow == 0) framesPerWindow = inNumberFrames;

    UInt32 framesProcessed = 0;
    while (framesProcessed < inNumberFrames) {
        UInt32 chunkFrames = MIN(framesPerWindow, inNumberFrames - framesProcessed);
        double rms = [self rmsOfBufferList:inBufferList
                            startingFrame:framesProcessed
                            frameCount:chunkFrames];
        double db = (rms > 0.0) ? 20.0 * log10(rms) : -INFINITY;

        BOOL silent = (db <= (double)self.silenceThresholdDB) && isfinite(db);
        [self advanceStateBySeconds:(double)chunkFrames / _sampleRate silent:silent];
        framesProcessed += chunkFrames;
    }
}

- (double)rmsOfBufferList:(const AudioBufferList *)abl
           startingFrame:(UInt32)startFrame
              frameCount:(UInt32)frameCount {
    if (frameCount == 0 || abl == NULL) return 0.0;

    double sumSq = 0.0;
    UInt32 validSamples = 0;

    // For simplicity, we analyze channel 0 (silence is broadly correlated
    // across channels for spoken-word / podcast-style content). Overcast
    // itself does its LUFS analysis across the mono mixdown.
    const AudioBuffer *buf = &abl->mBuffers[0];
    if (buf == NULL || buf->mData == NULL) return 0.0;

    if (_isFloat) {
        const float *p = (const float *)buf->mData;
        UInt32 stride = _isInterleaved ? _channels : 1u;
        for (UInt32 i = 0; i < frameCount; i++) {
            float s = p[(startFrame + i) * stride];
            // Clamp non-finite values to zero to avoid NaN propagation.
            if (!isfinite(s)) s = 0.0f;
            sumSq += (double)s * (double)s;
            validSamples++;
        }
    } else {
        // 16-bit signed PCM
        UInt32 bytesPerFrame = (_format.mBitsPerChannel / 8) * _channels;
        const SInt16 *p = (const SInt16 *)((UInt8 *)buf->mData + startFrame * bytesPerFrame);
        UInt32 stride = _isInterleaved ? _channels : 1u;
        for (UInt32 i = 0; i < frameCount; i++) {
            double s = (double)p[i * stride] / 32768.0;
            sumSq += s * s;
            validSamples++;
        }
    }

    if (validSamples == 0) return 0.0;
    return sqrt(sumSq / (double)validSamples);
}

#pragma mark - State machine

- (void)advanceStateBySeconds:(NSTimeInterval)dt silent:(BOOL)silent {
    @synchronized(self) {
        if (silent) {
            if (!_inSilence) {
                _inSilence = YES;
                _accumulatedSilenceSeconds = dt;
                SSVerbose(@"silence begin (+%.3fs)", dt);
            } else {
                _accumulatedSilenceSeconds += dt;
            }

            if (_accumulatedSilenceSeconds >= self.minSilenceDuration) {
                NSTimeInterval nowHost = [self hostTimeSeconds]; // monotonic
                NSTimeInterval sinceLast = nowHost - _lastSkipHostSeconds;
                if (sinceLast >= self.cooldown) {
                    _lastSkipHostSeconds = nowHost;
                    SSLog(@"silence SUSTAINED (%.2fs >= %.2fs) → fire skip",
                          _accumulatedSilenceSeconds, self.minSilenceDuration);
                    if ([self.delegate respondsToSelector:@selector(detector:didDetectSilenceWithDuration:atHostTime:)]) {
                        [self.delegate detector:self
                            didDetectSilenceWithDuration:_accumulatedSilenceSeconds
                                          atHostTime:0];
                    }
                    // After firing, keep accumulating but the manager will
                    // either skip (and reset via reset) or ignore. Don't
                    // double-fire until cooldown elapses.
                } else {
                    SSVerbose(@"silence sustained but cooldown (%.2fs < %.2fs)",
                              sinceLast, self.cooldown);
                }
            }
        } else {
            if (_inSilence) {
                SSVerbose(@"silence end (total %.3fs)", _accumulatedSilenceSeconds);
            }
            _inSilence = NO;
            _accumulatedSilenceSeconds = 0;
        }
    }
}

- (NSTimeInterval)hostTimeSeconds {
    // Use mach_absolute_time for a monotonic clock independent of playback
    // time. (Used only for cooldown comparisons.)
    static mach_timebase_info_data_t sTBI;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ mach_timebase_info(&sTBI); });
    UInt64 ticks = mach_absolute_time();
    double nanos = (double)ticks * (double)sTBI.numer / (double)sTBI.denom;
    return nanos / 1.0e9;
}

@end
