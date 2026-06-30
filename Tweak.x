//
//  Tweak.x
//  YTSkipSilence
//
//  YTLite extension that ports Overcast's silence-skipping behavior to
//  YouTube. Adds a "Skip Silence" toggle button to the YouTube video
//  player overlay via PoomSmart's YTVideoOverlay framework.
//
//  When the button is on (red), an MTAudioProcessingTap is attached to
//  the underlying AVPlayer's AVPlayerItem audio tracks. A real-time RMS→dBFS
//  detector (SkipSilenceDetector) watches for sustained silence. When
//  silence persists beyond minSilenceDuration, the manager seeks the
//  AVPlayer forward by silence × multiplier — mirroring Overcast's
//  silenceSkippingSpeed (≈4×).
//
//  Structure mirrors YouLoop / YouTimeStamp (YTVideoOverlay consumers):
//    - %group Main    → YTPlayerViewController lifecycle
//    - %group Top     → YTMainAppControlsOverlayView (top button)
//    - %group Bottom  → YTInlinePlayerBarContainerView (bottom button)
//    - %ctor          → initYTVideoOverlay(...) registration
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// --- YTVideoOverlay (sibling checkout of github.com/PoomSmart/YTVideoOverlay) ---
#import "../YTVideoOverlay/Header.h"
#import "../YTVideoOverlay/Init.x"

// --- YouTube private headers (provided as a headers-only clone at
//     $THEOS/include/YouTubeHeader — do NOT link as a framework) ---
#import <YouTubeHeader/YTColor.h>
#import <YouTubeHeader/QTMIcon.h>
#import <YouTubeHeader/YTMainAppVideoPlayerOverlayViewController.h>
#import <YouTubeHeader/YTMainAppVideoPlayerOverlayView.h>
#import <YouTubeHeader/YTMainAppControlsOverlayView.h>
#import <YouTubeHeader/YTInlinePlayerBarContainerView.h>
#import <YouTubeHeader/YTPlayerViewController.h>

// --- Skip Silence source ---
#import "Source/SkipSilenceSettings.h"
#import "Source/SkipSilenceManager.h"
#import "Source/SkipSilenceDetector.h"
#import "Source/SkipSilenceAudioTap.h"

#define TweakKey @"SkipSilence"
// kSkipSilenceVerboseLoggingKey and kSkipSilenceSkipBackwardKey are
// declared as `extern NSString * const` in SkipSilenceSettings.h and
// defined in SkipSilenceSettings.m. We use them directly instead of
// redefining as macros here.

#pragma mark - Forward declarations for private classes

// YTMainAppControlsOverlayView natively exposes `playerViewController`,
// so we don't need to walk the view hierarchy for the top button.
// (See YouTubeHeader/YTMainAppControlsOverlayView.h.)
// For the bottom button (YTInlinePlayerBarContainerView) we still need
// to walk via the delegate chain, mirroring YouLoop / YouTimeStamp.

@interface YTMainAppVideoPlayerOverlayViewController (YTSkipSilence)
@property (nonatomic, assign) YTPlayerViewController *parentViewController;
@end

@interface YTMainAppVideoPlayerOverlayView (YTSkipSilence)
@property (nonatomic, weak, readwrite) YTMainAppVideoPlayerOverlayViewController *delegate;
@end

@interface YTPlayerViewController (YTSkipSilence)
- (CGFloat)currentVideoMediaTime;
@end

@interface YTMainAppControlsOverlayView (YTSkipSilence)
// `playerViewController` is declared on the base class in
// YouTubeHeader/YTMainAppControlsOverlayView.h. Re-declaring it here lets
// the compiler see it inside our %hook body without an extra import.
@property (nonatomic, strong, readwrite) YTPlayerViewController *playerViewController;
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
        NSString *tweakBundlePath = [[NSBundle mainBundle] pathForResource:@"YTSkipSilence" ofType:@"bundle"];
        if (tweakBundlePath) {
            bundle = [NSBundle bundleWithPath:tweakBundlePath];
        } else {
            // PS_ROOT_PATH_NS comes from PSHeader/Misc.h (imported transitively
            // via YTVideoOverlay/Header.h → YouTubeHeader chain). It resolves
            // to /var/jb/... on rootless.
            bundle = [NSBundle bundleWithPath:PS_ROOT_PATH_NS(@"/Library/Application Support/YTSkipSilence.bundle")];
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
    if (!img) return nil;

    // Tint: white when off, YouTube-red when on. YTColor exposes
    // `white1` and `youTubeRed` (NOT `youTubeBlueColor` — that doesn't exist).
    UIColor *tint = on ? [%c(YTColor) youTubeRed] : [%c(YTColor) white1];
    return [%c(QTMIcon) tintImage:img color:tint];
}

#pragma mark - Per-player manager storage (associated objects)

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
/// If every candidate fails, returns nil and the tweak degrades to a no-op
/// (never crashes).
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

/// Bind (or unbind) the silence manager to the given YTPlayerViewController.
/// Used both at first appearance and when the user toggles the button.
static void YTSkipSilenceAttachOrDetach(YTPlayerViewController *pvc, BOOL enable) {
    if (pvc == nil) return;
    SkipSilenceManager *mgr = YTSkipSilenceManagerForPlayer(pvc);
    if (enable) {
        if (mgr == nil) {
            mgr = [[SkipSilenceManager alloc] init];
            YTSkipSilenceSetManagerForPlayer(pvc, mgr);
        }
        AVPlayer *p = YTSkipSilenceExtractAVPlayer(pvc);
        if (p) {
            [mgr attachToPlayer:p];
        } else {
            NSLog(@"[YTSkipSilence] could not extract AVPlayer from YTPlayerViewController — skip silence will be inactive for this video");
        }
    } else {
        [mgr detach];
    }
}

#pragma mark - %group Main (YTPlayerViewController lifecycle)

%group Main
%hook YTPlayerViewController

// `currentVideoMediaTime` is a getter YouTube calls on a cadence to update
// the scrubber. We hook the GETTER (not a setter — there is no setter) to
// piggy-back the manager's playback-time cache. This is the documented
// public-ish API in YouTubeHeader/YTPlayerViewController.h.
- (CGFloat)currentVideoMediaTime {
    CGFloat t = %orig;
    SkipSilenceManager *mgr = YTSkipSilenceManagerForPlayer(self);
    if (mgr) [mgr updatePlaybackTime:(NSTimeInterval)t];
    return t;
}

// Single-point attach/detach on the player VC lifecycle. We do NOT hook
// viewDidLoad because at that point the AVPlayer ivar is typically nil —
// viewWillAppear is also too early. We hook the more reliable
// `viewDidAppear:` and `viewDidDisappear:` so the manager binds once the
// player is actually presenting media.
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    SkipSilenceSettings *s = [SkipSilenceSettings shared];
    if (s.isEnabled) {
        YTSkipSilenceAttachOrDetach(self, YES);
    }
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    SkipSilenceManager *mgr = YTSkipSilenceManagerForPlayer(self);
    [mgr detach];
}

%end

%end // %group Main

#pragma mark - %group Top (YTMainAppControlsOverlayView)

%group Top
%hook YTMainAppControlsOverlayView

// YTVideoOverlay calls buttonImage: to let each registered tweak supply
// its own icon. Return nil for non-matching IDs so other tweaks still
// get their images via %orig.
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

    // YTMainAppControlsOverlayView natively exposes `playerViewController`
    // (per YouTubeHeader/YTMainAppControlsOverlayView.h). No view-hierarchy
    // walking needed.
    YTPlayerViewController *pvc = self.playerViewController;
    if (pvc) {
        YTSkipSilenceAttachOrDetach(pvc, newState);
    }
}

%end

%end // %group Top

#pragma mark - %group Bottom (YTInlinePlayerBarContainerView)

%group Bottom
%hook YTInlinePlayerBarContainerView

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

    // YTInlinePlayerBarContainerView doesn't expose playerViewController
    // directly; walk via the delegate chain (same pattern as YouLoop).
    YTInlinePlayerBarController *barDelegate = self.delegate;
    YTMainAppVideoPlayerOverlayViewController *overlayVC =
        [barDelegate valueForKey:@"_delegate"];
    YTPlayerViewController *pvc = overlayVC.parentViewController;
    if (pvc) {
        YTSkipSilenceAttachOrDetach(pvc, newState);
    }
}

%end

%end // %group Bottom

#pragma mark - %ctor

%ctor {
    @autoreleasepool {
        [SkipSilenceSettings registerDefaults];

        initYTVideoOverlay(TweakKey, @{
            AccessibilityLabelKey: @"Skip Silence",
            SelectorKey: @"didPressSkipSilence:",
            // Re-pull the icon every time the button becomes visible so the
            // tint reflects the current on/off state.
            UpdateImageOnVisibleKey: @YES,
            // Expose two extra boolean settings in YTVideoOverlay's settings
            // pane. Strings live in our .bundle's Localizable.strings.
            ExtraBooleanKeys: @[kSkipSilenceVerboseLoggingKey, kSkipSilenceSkipBackwardKey],
        });

        %init(Main);
        %init(Top);
        %init(Bottom);

        NSLog(@"[YTSkipSilence] loaded (enabled=%@)",
              [SkipSilenceSettings shared].isEnabled ? @"YES" : @"NO");
    }
}
