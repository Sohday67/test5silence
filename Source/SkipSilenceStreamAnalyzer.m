//
//  SkipSilenceStreamAnalyzer.m
//  YTSkipSilence
//

#import "SkipSilenceStreamAnalyzer.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <AudioToolbox/AudioToolbox.h>

#define SSLog(fmt, ...) NSLog(@"[YTSkipSilence][analyzer] " fmt, ##__VA_ARGS__)

// We decode to a fixed, cheap format: 16 kHz mono float32. Silence detection
// needs no fidelity, and this minimises both the decode cost and the math.
static const double kAnalysisSampleRate = 16000.0;
static const double kWindowSeconds      = 0.05;   // 50 ms RMS windows

@implementation SkipSilenceRegion
- (NSTimeInterval)duration { return self.end - self.start; }
@end

@interface SkipSilenceStreamAnalyzer ()
@property (nonatomic, strong) NSURL *url;
@property (nonatomic, assign) float thresholdDB;
@property (nonatomic, assign) float minDuration;
@property (nonatomic, assign) BOOL cancelled;
@property (nonatomic, strong) NSURLSessionDownloadTask *downloadTask;
@end

@implementation SkipSilenceStreamAnalyzer

- (instancetype)initWithURL:(NSURL *)url
         silenceThresholdDB:(float)thresholdDB
         minSilenceDuration:(float)minDuration {
    self = [super init];
    if (self) {
        _url = url;
        _thresholdDB = thresholdDB;
        _minDuration = minDuration;
    }
    return self;
}

- (void)cancel {
    self.cancelled = YES;
    [self.downloadTask cancel];
    self.downloadTask = nil;
}

- (void)reportSuccess:(BOOL)ok regions:(NSUInteger)count {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.onCompleted) self.onCompleted(ok, count);
    });
}

- (void)start {
    if (self.url == nil) {
        SSLog(@"no URL — nothing to analyze");
        [self reportSuccess:NO regions:0];
        return;
    }
    SSLog(@"downloading audio for analysis: %@", self.url.absoluteString.length > 80
          ? [[self.url.absoluteString substringToIndex:80] stringByAppendingString:@"…"]
          : self.url.absoluteString);

    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    cfg.timeoutIntervalForResource = 60;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];

    __weak typeof(self) weakSelf = self;
    self.downloadTask = [session downloadTaskWithURL:self.url
                                   completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.cancelled) return;
        if (error || location == nil) {
            SSLog(@"download failed: %@", error.localizedDescription ?: @"no file");
            [strongSelf reportSuccess:NO regions:0];
            return;
        }
        long long status = [response isKindOfClass:[NSHTTPURLResponse class]]
            ? (long long)[(NSHTTPURLResponse *)response statusCode] : 0;
        if (status >= 400) {
            SSLog(@"download HTTP %lld — URL likely throttled/expired", status);
            [strongSelf reportSuccess:NO regions:0];
            return;
        }

        // Move out of the session's temp slot (valid only inside this block).
        NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:
                         [NSString stringWithFormat:@"ytss_%@.m4a", [[NSUUID UUID] UUIDString]]];
        NSURL *localURL = [NSURL fileURLWithPath:tmp];
        NSError *moveErr = nil;
        [[NSFileManager defaultManager] moveItemAtURL:location toURL:localURL error:&moveErr];
        if (moveErr) {
            SSLog(@"could not stage temp file: %@", moveErr.localizedDescription);
            [strongSelf reportSuccess:NO regions:0];
            return;
        }

        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            [strongSelf analyzeLocalFile:localURL];
            [[NSFileManager defaultManager] removeItemAtURL:localURL error:NULL];
        });
    }];
    [self.downloadTask resume];
    // Let the in-flight task finish, then tear the session down (no leak).
    [session finishTasksAndInvalidate];
}

- (void)analyzeLocalFile:(NSURL *)localURL {
    NSError *err = nil;
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:localURL options:nil];
    AVAssetTrack *audioTrack = [[asset tracksWithMediaType:AVMediaTypeAudio] firstObject];
    if (audioTrack == nil) {
        SSLog(@"staged file has no audio track (codec not decodable? e.g. opus)");
        [self reportSuccess:NO regions:0];
        return;
    }

    AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:asset error:&err];
    if (reader == nil) {
        SSLog(@"AVAssetReader init failed: %@", err.localizedDescription);
        [self reportSuccess:NO regions:0];
        return;
    }

    NSDictionary *settings = @{
        AVFormatIDKey:               @(kAudioFormatLinearPCM),
        AVSampleRateKey:             @(kAnalysisSampleRate),
        AVNumberOfChannelsKey:       @1,
        AVLinearPCMBitDepthKey:      @32,
        AVLinearPCMIsFloatKey:       @YES,
        AVLinearPCMIsBigEndianKey:   @NO,
        AVLinearPCMIsNonInterleaved: @NO,
    };
    AVAssetReaderTrackOutput *output =
        [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:audioTrack outputSettings:settings];
    output.alwaysCopiesSampleData = NO;
    if (![reader canAddOutput:output]) {
        SSLog(@"cannot add reader output");
        [self reportSuccess:NO regions:0];
        return;
    }
    [reader addOutput:output];
    if (![reader startReading]) {
        SSLog(@"startReading failed: %@", reader.error.localizedDescription);
        [self reportSuccess:NO regions:0];
        return;
    }

    const UInt32 windowFrames = (UInt32)(kWindowSeconds * kAnalysisSampleRate); // 800
    const double threshold = (double)self.thresholdDB;
    const double minDur = (double)self.minDuration;

    UInt64 totalFrames = 0;     // frames consumed → time = totalFrames / sampleRate
    double winSumSq = 0.0;      // running window accumulator
    UInt32 winCount = 0;
    BOOL inSilence = NO;
    double silenceStart = 0.0;
    NSUInteger regionsFound = 0;

    while (reader.status == AVAssetReaderStatusReading) {
        if (self.cancelled) { [reader cancelReading]; break; }

        CMSampleBufferRef sbuf = [output copyNextSampleBuffer];
        if (sbuf == NULL) break;

        CMBlockBufferRef block = NULL;
        AudioBufferList abl;
        OSStatus s = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sbuf, NULL, &abl, sizeof(abl), kCFAllocatorDefault, kCFAllocatorDefault,
            kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, &block);
        if (s != noErr || abl.mNumberBuffers == 0 || abl.mBuffers[0].mData == NULL) {
            if (block) CFRelease(block);
            CFRelease(sbuf);
            continue;
        }

        const float *samples = (const float *)abl.mBuffers[0].mData;
        UInt32 frames = (UInt32)CMSampleBufferGetNumSamples(sbuf);

        for (UInt32 i = 0; i < frames; i++) {
            float v = samples[i];
            if (!isfinite(v)) v = 0.0f;
            winSumSq += (double)v * (double)v;
            winCount++;
            totalFrames++;

            if (winCount >= windowFrames) {
                double rms = sqrt(winSumSq / (double)winCount);
                double db = (rms > 0.0) ? 20.0 * log10(rms) : -160.0;
                BOOL silent = (db <= threshold);
                double now = (double)totalFrames / kAnalysisSampleRate;

                if (silent && !inSilence) {
                    inSilence = YES;
                    silenceStart = now - kWindowSeconds; // region began at window start
                } else if (!silent && inSilence) {
                    inSilence = NO;
                    double end = now - kWindowSeconds;
                    if (end - silenceStart >= minDur) {
                        [self emitRegionFrom:silenceStart to:end];
                        regionsFound++;
                    }
                }
                winSumSq = 0.0;
                winCount = 0;
            }
        }

        if (block) CFRelease(block);
        CFRelease(sbuf);
    }

    // Close a silence run that extends to the end of the track.
    if (inSilence) {
        double end = (double)totalFrames / kAnalysisSampleRate;
        if (end - silenceStart >= minDur) {
            [self emitRegionFrom:silenceStart to:end];
            regionsFound++;
        }
    }

    BOOL ok = (reader.status == AVAssetReaderStatusCompleted) ||
              (self.cancelled == NO && totalFrames > 0);
    if (reader.status == AVAssetReaderStatusFailed) {
        SSLog(@"reader failed mid-stream: %@", reader.error.localizedDescription);
    }
    SSLog(@"analysis %@ — %.1fs of audio, %lu silence region(s)",
          ok ? @"done" : @"incomplete",
          (double)totalFrames / kAnalysisSampleRate, (unsigned long)regionsFound);
    [self reportSuccess:ok regions:regionsFound];
}

- (void)emitRegionFrom:(double)start to:(double)end {
    if (self.cancelled) return;
    SkipSilenceRegion *r = [[SkipSilenceRegion alloc] init];
    r.start = start;
    r.end = end;
    SSLog(@"silence region [%.2f → %.2f] (%.2fs)", start, end, end - start);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.onRegionFound) self.onRegionFound(r);
    });
}

@end
