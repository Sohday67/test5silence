//
//  SkipSilenceManager.m
//  YTSkipSilence
//

#import "SkipSilenceManager.h"
#import "SkipSilenceSettings.h"
#import "SkipSilenceStreamAnalyzer.h"

#import <YouTubeHeader/YTPlayerViewController.h>

#define SSLog(fmt, ...) NSLog(@"[YTSkipSilence][mgr] " fmt, ##__VA_ARGS__)

// The player VC's accessors we rely on aren't all in the public header; declare
// the ones we use. (currentVideoID / currentVideoMediaTime / seekToTime: are.)
@interface YTPlayerViewController (YTSkipSilence)
- (id)playerResponse;   // YTPlayerResponse
- (NSString *)currentVideoID;
- (void)seekToTime:(CGFloat)time;
@end

@interface SkipSilenceManager ()
@property (nonatomic, weak) YTPlayerViewController *playerVC;
@property (nonatomic, copy) NSString *videoID;
@property (nonatomic, strong) SkipSilenceStreamAnalyzer *analyzer;
@property (nonatomic, strong) NSMutableArray<SkipSilenceRegion *> *regions; // main-thread only
@property (nonatomic, assign) BOOL mapReady;
@property (nonatomic, assign) NSTimeInterval lastSkipHostTime;
@end

@implementation SkipSilenceManager

- (instancetype)init {
    self = [super init];
    if (self) {
        _regions = [NSMutableArray array];
        _lastSkipHostTime = -1000.0;
    }
    return self;
}

- (void)dealloc {
    [self detach];
}

- (BOOL)isMonitoring {
    return self.mapReady && self.regions.count > 0;
}

#pragma mark - Attach / detach

- (void)attachToPlayerViewController:(YTPlayerViewController *)pvc {
    if (pvc == nil) return;

    SkipSilenceSettings *s = [SkipSilenceSettings shared];
    if (!s.isEnabled) {
        SSLog(@"attach requested but Skip Silence is off — ignoring");
        return;
    }

    NSString *vid = nil;
    @try { vid = [pvc currentVideoID]; } @catch (id e) {}
    // Without a video id we can't dedupe; wait for a tick that has one rather
    // than thrash (the time hook fires many times per second).
    if (vid.length == 0) return;

    // Same video already in progress / mapped → nothing to do.
    if (self.playerVC == pvc && [vid isEqualToString:self.videoID]) {
        return;
    }

    [self detach];
    self.playerVC = pvc;
    self.videoID = vid;
    SSLog(@"attaching for video %@", vid ?: @"(unknown id)");

    NSURL *audioURL = [self resolveAudioURLFromPlayerVC:pvc];
    if (audioURL == nil) {
        SSLog(@"could not resolve a progressive audio (audio/mp4) URL from the "
              @"player response — silence-skip inactive for this video");
        return;
    }

    SkipSilenceStreamAnalyzer *analyzer =
        [[SkipSilenceStreamAnalyzer alloc] initWithURL:audioURL
                                    silenceThresholdDB:s.silenceThresholdDB
                                    minSilenceDuration:s.minSilenceDuration];
    __weak typeof(self) weakSelf = self;
    analyzer.onRegionFound = ^(SkipSilenceRegion *region) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf.regions addObject:region];   // main queue (analyzer dispatches here)
    };
    analyzer.onCompleted = ^(BOOL ok, NSUInteger count) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.mapReady = YES;
        SSLog(@"silence map ready: %lu region(s), analysis %@",
              (unsigned long)count, ok ? @"ok" : @"failed");
    };
    self.analyzer = analyzer;
    [analyzer start];
}

- (void)detach {
    [self.analyzer cancel];
    self.analyzer = nil;
    [self.regions removeAllObjects];
    self.mapReady = NO;
    self.videoID = nil;
    self.playerVC = nil;
}

#pragma mark - Audio URL resolution

/// Walk playerVC.playerResponse.playerData.streamingData.adaptiveFormatsArray and
/// pick the smallest `audio/mp4` (AAC) stream — small to download, and the only
/// container AVAssetReader can decode reliably (opus/webm cannot). All access is
/// via KVC + @try so a header/ivar rename degrades to "no URL" rather than a crash.
- (NSURL *)resolveAudioURLFromPlayerVC:(YTPlayerViewController *)pvc {
    @try {
        id playerResponse = [pvc playerResponse];                    // YTPlayerResponse
        id playerData     = [playerResponse valueForKey:@"playerData"];     // YTIPlayerResponse
        id streamingData  = [playerData valueForKey:@"streamingData"];      // YTIStreamingData
        NSArray *formats  = [streamingData valueForKey:@"adaptiveFormatsArray"];
        if (![formats isKindOfClass:[NSArray class]] || formats.count == 0) {
            SSLog(@"no adaptiveFormats in player response (HLS-only response?)");
            return nil;
        }

        NSString *bestURL = nil;
        long bestBitrate = LONG_MAX;
        for (id fmt in formats) {
            NSString *mime = [self stringValueOf:fmt key:@"mimeType"];
            if (![mime hasPrefix:@"audio/mp4"]) continue;            // AAC only
            NSString *url = [self stringValueOf:fmt key:@"URL"];
            if (url.length == 0) continue;
            long bitrate = 0;
            @try { bitrate = [[fmt valueForKey:@"bitrate"] longValue]; } @catch (id e) {}
            if (bestURL == nil || bitrate < bestBitrate) {
                bestURL = url;
                bestBitrate = bitrate;
            }
        }
        if (bestURL) {
            SSLog(@"resolved audio/mp4 stream (%ld bps)", bestBitrate == LONG_MAX ? 0 : bestBitrate);
            return [NSURL URLWithString:bestURL];
        }
        SSLog(@"adaptiveFormats present but no audio/mp4 stream found");
    } @catch (id e) {
        SSLog(@"audio URL resolution threw: %@", e);
    }
    return nil;
}

- (NSString *)stringValueOf:(id)obj key:(NSString *)key {
    @try {
        id v = [obj valueForKey:key];
        return [v isKindOfClass:[NSString class]] ? v : nil;
    } @catch (id e) { return nil; }
}

#pragma mark - Skipping

- (void)updatePlaybackTime:(NSTimeInterval)seconds {
    if (!self.mapReady && self.regions.count == 0) return;
    YTPlayerViewController *pvc = self.playerVC;
    if (pvc == nil) return;
    if (![SkipSilenceSettings shared].isEnabled) return;

    NSTimeInterval now = [NSProcessInfo processInfo].systemUptime; // monotonic
    if (now - self.lastSkipHostTime < [SkipSilenceSettings shared].skipCooldown) return;

    for (SkipSilenceRegion *r in self.regions) {
        if (r.consumed) continue;
        // Drop regions we've already moved past.
        if (r.end <= seconds - 0.5) { r.consumed = YES; continue; }
        // Inside (or just entering) a silence region → jump to its end.
        if (seconds >= r.start - 0.15 && seconds < r.end - 0.20) {
            r.consumed = YES;
            self.lastSkipHostTime = now;
            // Keep a sliver of silence so speech onset isn't clipped.
            NSTimeInterval target = r.end - 0.05;
            if (target <= seconds) continue;
            SSLog(@"SKIP silence [%.2f→%.2f] from %.2fs → %.2fs", r.start, r.end, seconds, target);
            @try { [pvc seekToTime:(CGFloat)target]; } @catch (id e) {
                SSLog(@"seekToTime: failed: %@", e);
            }
            return;
        }
    }
}

@end
