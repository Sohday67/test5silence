//
//  Tweak.x
//  YTSkipSilence
//
//  YTLite extension that ports Overcast's silence-skipping behavior to
//  YouTube. Adds a "Skip Silence" toggle button to the YouTube video
//  player overlay via PoomSmart's YTVideoOverlay framework.
//
//  When the button is on (blue), an MTAudioProcessingTap is attached to
//  the underlying AVPlayer's AVPlayerItem audio tracks. A real-time RMS→dBFS
//  detector (SkipSilenceDetector) watches for sustained silence. When
//  silence persists beyond minSilenceDuration, the manager seeks the
//  AVPlayer forward by silence × multiplier — mirroring Overcast's
//  silenceSkippingSpeed (≈4×).
//
//  Structure mirrors the YouTimeStamp extension (Sohday67/YouTimeStamp):
//    - group Main         -> YTPlayerViewController lifecycle
//    - group Top          -> YTMainAppControlsOverlayView (top button)
//    - group Bottom       -> YTInlinePlayerBarContainerView (bottom button)
//    - ctor               -> initYTVideoOverlay(...) registration
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// --- YTVideoOverlay (sibling checkout of github.com/PoomSmart/YTVideoOverlay) ---
#import "../YTVideoOverlay/Header.h"
#import "../YTVideoOverlay/Init.x"

// --- YouTube private headers (provided by Theos's YouTubeHeader framework) ---
#import <YouTubeHeader/YTColor.h>
#import <YouTubeHeader/QTMIcon.h>
#import <YouTubeHeader/YTMainAppVideoPlayerOverlayViewController.h>
#import <YouTubeHeader/YTMainAppVideoPlayerOverlayView.h>
#import <YouTubeHeader/YTMainAppControlsOverlayView.h>
#import <YouTubeHeader/YTPlayerViewController.h>

// --- Skip Silence source ---
#import "Source/SkipSilenceSettings.h"
#import "Source/SkipSilenceManager.h"
#import "Source/SkipSilenceDetector.h"
#import "Source/SkipSilenceAudioTap.h"

#define TweakKey @"SkipSilence"
#define kSkipSilenceVerboseKey @"YTSkipSilence-VerboseLogging"

#pragma mark - Forward declarations for private classes

@interface YTMainAppVideoPlayerOverlayViewController (YTSkipSilence)
@property (nonatomic, assign) YTPlayerViewController *parentViewController;
@end

@interface YTMainAppVideoPlayerOverlayView (YTSkipSilence)
@property (nonatomic, weak, readwrite) YTMainAppVideoPlayerOverlayViewController *delegate;
@end

@interface YTPlayerViewController (YTSkipSilence)
@property (nonatomic, assign) CGFloat currentVideoMediaTime;
@property (nonatomic, strong) NSString *currentVideoID;
@end

@interface YTMainAppControlsOverlayView (YTSkipSilence)
@property (nonatomic, assign) YTPlayerViewController *playerViewController;
- (void)didPressSkipSilence:(id)arg;
@end

@interface YTInlinePlayerBarContainerView (YTSkipSilence)
@property (nonatomic, strong) id delegate;
- (void)didPressSkipSilence:(id)arg;
@end

@interface YTInlinePlayerBarController : NSObject
@end

#pragma mark - Bundle / icon helpers

NSBundle *YTSkipSilenceBundle(void) {
    static NSBundle *bundle = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *path = [[NSBundle mainBundle] pathForResource:@"YTSkipSilence" ofType:@"bundle"];
        if (path) {
            bundle = [NSBundle bundleWithPath:path];
        } else {
            // ROOT_PATH_NS already yields an NSString; wrapping it in
            // stringWithFormat: tripped -Wformat-security (the path isn't a
            // literal). Use it directly.
            bundle = [NSBundle bundleWithPath:
                ROOT_PATH_NS(@"/Library/Application Support/YTSkipSilence.bundle")];
        }
    });
    return bundle;
}

static UIImage *SkipSilenceIcon(BOOL on) {
    NSBundle *b = YTSkipSilenceBundle();
    NSString *name = on ? @"SkipSilenceOn" : @"SkipSilenceOff";
    UIImage *img = [UIImage imageNamed:name inBundle:b compatibleWithTraitCollection:nil];
    if (!img) {
        // Fallback: a system glyph so the button is never blank.
        UIImageSymbolConfiguration *cfg =
            [UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightRegular];
        img = [UIImage systemImageNamed:@"speaker.wave.2.fill" withConfiguration:cfg];
    }
    // Tint white in the YouTube overlay style (matches other overlay buttons).
    if (img) {
        // YTColor exposes no blue accessor — use YouTube's accent blue
        // (#3EA6FF) for the active state, and YTColor's white1 when off.
        UIColor *tint = on ? [UIColor colorWithRed:62.0/255.0 green:166.0/255.0 blue:255.0/255.0 alpha:1.0]
                           : [%c(YTColor) white1];
        if ([%c(QTMIcon) respondsToSelector:@selector(tintImage:color:)]) {
            img = [%c(QTMIcon) tintImage:img color:tint];
        } else {
            img = [img imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        }
    }
    return img;
}

#pragma mark - Per-player manager storage

static char kSkipSilenceManagerKey; // associated-object key

static SkipSilenceManager *YTSkipSilenceManagerForPlayer(YTPlayerViewController *pvc) {
    return objc_getAssociatedObject(pvc, &kSkipSilenceManagerKey);
}

static void YTSkipSilenceSetManagerForPlayer(YTPlayerViewController *pvc, SkipSilenceManager *mgr) {
    objc_setAssociatedObject(pvc, &kSkipSilenceManagerKey, mgr, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

/// Try several known ways to dig the underlying AVPlayer out of a
/// YTPlayerViewController. YouTube wraps an AVQueuePlayer / AVPlayer in a
/// custom container; the ivar name has shifted between YouTube versions.
static AVPlayer *YTSkipSilenceExtractAVPlayer(YTPlayerViewController *pvc) {
    NSArray<NSString *> *candidates = @[
        @"player", @"_player", @"mediaPlayer", @"_mediaPlayer",
        @"videoPlayer", @"_videoPlayer", @"avPlayer", @"_avPlayer",
        @"queuePlayer", @"_queuePlayer"
    ];
    for (NSString *key in candidates) {
        @try {
            id v = [pvc valueForKey:key];
            if ([v isKindOfClass:[AVPlayer class]]) {
                return (AVPlayer *)v;
            }
            // Some YouTube versions nest one level deeper.
            if ([v respondsToSelector:@selector(player)]) {
                id inner = [(id)v performSelector:@selector(player)];
                if ([inner isKindOfClass:[AVPlayer class]]) return inner;
            }
        } @catch (NSException *e) {
            // Try next candidate.
        }
    }
    return nil;
}

#pragma mark - Main group: YTPlayerViewController lifecycle

%group Main
%hook YTPlayerViewController

- (void)viewDidLoad {
    %orig;
    [SkipSilenceSettings registerDefaults];
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    SkipSilenceSettings *s = [SkipSilenceSettings shared];
    if (!s.isEnabled) return;

    SkipSilenceManager *mgr = YTSkipSilenceManagerForPlayer(self);
    if (mgr == nil) {
        mgr = [[SkipSilenceManager alloc] init];
        YTSkipSilenceSetManagerForPlayer(self, mgr);
    }
    AVPlayer *p = YTSkipSilenceExtractAVPlayer(self);
    if (p) {
        [mgr attachToPlayer:p];
    } else {
        NSLog(@"[YTSkipSilence] could not extract AVPlayer from YTPlayerViewController — skip silence will be inactive for this video");
    }
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    SkipSilenceManager *mgr = YTSkipSilenceManagerForPlayer(self);
    [mgr detach];
}

// YouTube calls this on a cadence to update the scrubber. We piggy-back on
// it to keep the manager's last-known playback time fresh for seek targeting.
- (void)updateCurrentVideoTime:(CGFloat)time {
    %orig;
    SkipSilenceManager *mgr = YTSkipSilenceManagerForPlayer(self);
    if (mgr) [mgr updatePlaybackTime:(NSTimeInterval)time];
}

// Some YouTube versions expose the time via a different selector.
- (void)setCurrentVideoMediaTime:(CGFloat)time {
    %orig;
    SkipSilenceManager *mgr = YTSkipSilenceManagerForPlayer(self);
    if (mgr) [mgr updatePlaybackTime:(NSTimeInterval)time];
}

%end

%end // end Main group

#pragma mark - Top group: YTMainAppControlsOverlayView (top button)

%group Top
%hook YTMainAppControlsOverlayView

- (id)initWithDelegate:(id)delegate {
    self = %orig;
    return self;
}

- (id)initWithDelegate:(id)delegate autoplaySwitchEnabled:(BOOL)autoplaySwitchEnabled {
    self = %orig;
    return self;
}

- (UIImage *)buttonImage:(NSString *)tweakId {
    if ([tweakId isEqualToString:TweakKey]) {
        BOOL on = [SkipSilenceSettings shared].isEnabled;
        return SkipSilenceIcon(on);
    }
    return %orig;
}

%new(v@:@)
- (void)didPressSkipSilence:(id)arg {
    SkipSilenceSettings *s = [SkipSilenceSettings shared];
    BOOL newState = !s.isEnabled;
    s.enabled = newState;

    // Refresh the icon immediately so the user sees the state change.
    [self.overlayButtons[TweakKey] setImage:[self buttonImage:TweakKey]
                                  forState:UIControlStateNormal];

    // Walk the view hierarchy to reach the YTPlayerViewController, then
    // either attach or detach the silence manager.
    YTMainAppVideoPlayerOverlayView *overlayView = (YTMainAppVideoPlayerOverlayView *)self.superview;
    YTMainAppVideoPlayerOverlayViewController *overlayVC = (YTMainAppVideoPlayerOverlayViewController *)overlayView.delegate;
    YTPlayerViewController *pvc = overlayVC.parentViewController;
    if (pvc) {
        SkipSilenceManager *mgr = YTSkipSilenceManagerForPlayer(pvc);
        if (newState) {
            if (mgr == nil) {
                mgr = [[SkipSilenceManager alloc] init];
                YTSkipSilenceSetManagerForPlayer(pvc, mgr);
            }
            AVPlayer *p = YTSkipSilenceExtractAVPlayer(pvc);
            if (p) [mgr attachToPlayer:p];
        } else {
            [mgr detach];
        }
    }
}

%end

%end // end Top group

#pragma mark - Bottom group: YTInlinePlayerBarContainerView (bottom button)

%group Bottom
%hook YTInlinePlayerBarContainerView

- (id)init {
    self = %orig;
    return self;
}

- (UIImage *)buttonImage:(NSString *)tweakId {
    if ([tweakId isEqualToString:TweakKey]) {
        BOOL on = [SkipSilenceSettings shared].isEnabled;
        return SkipSilenceIcon(on);
    }
    return %orig;
}

%new(v@:@)
- (void)didPressSkipSilence:(id)arg {
    SkipSilenceSettings *s = [SkipSilenceSettings shared];
    BOOL newState = !s.isEnabled;
    s.enabled = newState;

    [self.overlayButtons[TweakKey] setImage:[self buttonImage:TweakKey]
                                  forState:UIControlStateNormal];

    // Walk to the YTPlayerViewController via the inline bar's delegate chain.
    YTInlinePlayerBarController *barDelegate = self.delegate;
    YTMainAppVideoPlayerOverlayViewController *overlayVC =
        [barDelegate valueForKey:@"_delegate"];
    YTPlayerViewController *pvc = overlayVC.parentViewController;
    if (pvc) {
        SkipSilenceManager *mgr = YTSkipSilenceManagerForPlayer(pvc);
        if (newState) {
            if (mgr == nil) {
                mgr = [[SkipSilenceManager alloc] init];
                YTSkipSilenceSetManagerForPlayer(pvc, mgr);
            }
            AVPlayer *p = YTSkipSilenceExtractAVPlayer(pvc);
            if (p) [mgr attachToPlayer:p];
        } else {
            [mgr detach];
        }
    }
}

%end

%end // end Bottom group

#pragma mark - ctor

%ctor {
    @autoreleasepool {
        [SkipSilenceSettings registerDefaults];

        initYTVideoOverlay(TweakKey, @{
            AccessibilityLabelKey: @"Skip Silence",
            SelectorKey: @"didPressSkipSilence:",
            // Re-pull the icon every time the button becomes visible so the
            // tint reflects the current on/off state.
            UpdateImageOnVisibleKey: @YES,
            // Expose a verbose-logging switch in YTVideoOverlay's settings
            // pane for debugging. The strings live in our .bundle.
            ExtraBooleanKeys: @[kSkipSilenceVerboseKey,
                                @"YTSkipSilence-SkipBackward"],
        });

        %init(Main);
        %init(Top);
        %init(Bottom);

        NSLog(@"[YTSkipSilence] loaded (enabled=%@)",
              [SkipSilenceSettings shared].isEnabled ? @"YES" : @"NO");
    }
}
