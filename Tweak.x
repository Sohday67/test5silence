//
//  Tweak.x
//  YTSkipSilence
//
//  YTLite extension that ports Overcast's silence-skipping behavior to
//  YouTube. Adds a "Skip Silence" toggle button to the YouTube video
//  player overlay via PoomSmart's YTVideoOverlay framework.
//
//  When the button is on (blue), SkipSilenceManager resolves the video's
//  progressive AAC audio URL from the app's player response, decodes it
//  in-process with AVAssetReader (SkipSilenceStreamAnalyzer) to build a map of
//  silence regions, and seeks the player past each silence (via the player's own
//  seekToTime:) as playback reaches it. We analyze a *separately fetched* audio
//  file because YouTube's live HLS audio is decoded out-of-process and cannot be
//  tapped in-process — see SkipSilenceStreamAnalyzer.h.
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

// IMPORTANT: this must match the .bundle name (YTSkipSilence.bundle), because
// YTVideoOverlay loads each tweak's Localizable.strings from a bundle named
// after this key (TweakBundle(name)). Using "SkipSilence" made it look for a
// non-existent SkipSilence.bundle, so every settings label fell back to its
// raw key. It is also the YTVideoOverlay button id and the settings sub-section
// header title.
#define TweakKey @"YTSkipSilence"
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

/// Lazily ensure a manager exists, (re)attach it to the player VC, and feed it
/// the current playback time. Called from the single-video time callbacks, which
/// only fire once the video — and therefore its player response / audio stream
/// URL — is live. attachToPlayerViewController: is idempotent per-video.
static void YTSkipSilenceTick(YTPlayerViewController *pvc) {
    if (![SkipSilenceSettings shared].isEnabled) return;
    SkipSilenceManager *mgr = YTSkipSilenceManagerForPlayer(pvc);
    if (mgr == nil) {
        mgr = [[SkipSilenceManager alloc] init];
        YTSkipSilenceSetManagerForPlayer(pvc, mgr);
    }
    [mgr attachToPlayerViewController:pvc];
    @try {
        [mgr updatePlaybackTime:(NSTimeInterval)[pvc currentVideoMediaTime]];
    } @catch (id e) {}
}

#pragma mark - Main group: YTPlayerViewController lifecycle

%group Main
%hook YTPlayerViewController

- (void)viewDidLoad {
    %orig;
    [SkipSilenceSettings registerDefaults];
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    [YTSkipSilenceManagerForPlayer(self) detach];
}

// Reliable, frequently-fired playback clock: YTPlayerViewController is the
// single-video controller's delegate, so these are called continuously during
// playback. We lazily attach + drive the skips from here.
- (void)singleVideo:(id)video currentVideoTimeDidChange:(id)time {
    %orig;
    YTSkipSilenceTick(self);
}

- (void)potentiallyMutatedSingleVideo:(id)video currentVideoTimeDidChange:(id)time {
    %orig;
    YTSkipSilenceTick(self);
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
            [mgr attachToPlayerViewController:pvc];
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
            [mgr attachToPlayerViewController:pvc];
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
