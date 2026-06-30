#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import "Vendor/YTVideoOverlay/Header.h"
#import "Vendor/YTVideoOverlay/Init.x"
#import "Sources/YTSSDefines.h"
#import "Sources/YTSSSilenceController.h"
#import "Sources/YTSSIconFactory.h"

static const void *YTSSLongPressKey = &YTSSLongPressKey;

static UIImage *YTSSButtonImage(void) {
    YTSSSilenceController *controller = [YTSSSilenceController sharedController];
    return [YTSSIconFactory overlayIconEnabled:controller.enabled jumpMode:controller.jumpMode];
}

static void YTSSRefreshButton(YTQTMButton *button) {
    if (!button) return;
    UIImage *image = YTSSButtonImage();
    [button setImage:image forState:UIControlStateNormal];
    button.tintColor = UIColor.whiteColor;
    button.accessibilityLabel = @"Skip Silence";
}

static void YTSSInstallLongPress(YTQTMButton *button, id target) {
    if (!button || !target) return;
    if (objc_getAssociatedObject(button, YTSSLongPressKey)) return;
    UILongPressGestureRecognizer *gesture = [[UILongPressGestureRecognizer alloc] initWithTarget:target action:@selector(didLongPressYTSSkipSilence:)];
    gesture.minimumPressDuration = 0.45;
    [button addGestureRecognizer:gesture];
    objc_setAssociatedObject(button, YTSSLongPressKey, gesture, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

%group PlayerHooks

%hook AVPlayer

- (void)replaceCurrentItemWithPlayerItem:(AVPlayerItem *)item {
    %orig;
    [[YTSSSilenceController sharedController] attachToPlayer:self item:item reason:@"replaceCurrentItem"];
}

- (void)play {
    [[YTSSSilenceController sharedController] attachToPlayer:self item:self.currentItem reason:@"play"];
    %orig;
}

- (void)playImmediatelyAtRate:(float)rate {
    [[YTSSSilenceController sharedController] attachToPlayer:self item:self.currentItem reason:@"playImmediatelyAtRate"];
    %orig;
}

@end

%end

%group TopOverlay

%hook YTMainAppControlsOverlayView

- (id)initWithDelegate:(id)delegate {
    self = %orig;
    if (self) {
        YTQTMButton *button = self.overlayButtons[YTSS_TWEAK_KEY];
        YTSSInstallLongPress(button, self);
        YTSSRefreshButton(button);
    }
    return self;
}

- (id)initWithDelegate:(id)delegate autoplaySwitchEnabled:(BOOL)autoplaySwitchEnabled {
    self = %orig;
    if (self) {
        YTQTMButton *button = self.overlayButtons[YTSS_TWEAK_KEY];
        YTSSInstallLongPress(button, self);
        YTSSRefreshButton(button);
    }
    return self;
}

- (void)didMoveToWindow {
    %orig;
    YTQTMButton *button = self.overlayButtons[YTSS_TWEAK_KEY];
    YTSSInstallLongPress(button, self);
    YTSSRefreshButton(button);
}

- (UIImage *)buttonImage:(NSString *)tweakId {
    return [tweakId isEqualToString:YTSS_TWEAK_KEY] ? YTSSButtonImage() : %orig;
}

%new(v@:@)
- (void)didPressYTSSkipSilence:(id)arg {
    [[YTSSSilenceController sharedController] toggleEnabled];
    YTSSRefreshButton(self.overlayButtons[YTSS_TWEAK_KEY]);
}

%new(v@:@)
- (void)didLongPressYTSSkipSilence:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    [[YTSSSilenceController sharedController] cycleMode];
    YTSSRefreshButton(self.overlayButtons[YTSS_TWEAK_KEY]);
}

%end

%end

%group BottomOverlay

%hook YTInlinePlayerBarContainerView

- (id)init {
    self = %orig;
    if (self) {
        YTQTMButton *button = self.overlayButtons[YTSS_TWEAK_KEY];
        YTSSInstallLongPress(button, self);
        YTSSRefreshButton(button);
    }
    return self;
}

- (void)didMoveToWindow {
    %orig;
    YTQTMButton *button = self.overlayButtons[YTSS_TWEAK_KEY];
    YTSSInstallLongPress(button, self);
    YTSSRefreshButton(button);
}

- (UIImage *)buttonImage:(NSString *)tweakId {
    return [tweakId isEqualToString:YTSS_TWEAK_KEY] ? YTSSButtonImage() : %orig;
}

%new(v@:@)
- (void)didPressYTSSkipSilence:(id)arg {
    [[YTSSSilenceController sharedController] toggleEnabled];
    YTSSRefreshButton(self.overlayButtons[YTSS_TWEAK_KEY]);
}

%new(v@:@)
- (void)didLongPressYTSSkipSilence:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    [[YTSSSilenceController sharedController] cycleMode];
    YTSSRefreshButton(self.overlayButtons[YTSS_TWEAK_KEY]);
}

%end

%end

%ctor {
    [[YTSSSilenceController sharedController] installDefaults];

    initYTVideoOverlay(YTSS_TWEAK_KEY, @{
        AccessibilityLabelKey: @"Skip Silence",
        SelectorKey: @"didPressYTSSkipSilence:",
        UpdateImageOnVisibleKey: @YES,
        ExtraBooleanKeys: @[YTSS_JUMP_MODE_KEY, YTSS_AGGRESSIVE_KEY, YTSS_HUD_KEY],
    });

    %init(PlayerHooks);
    %init(TopOverlay);
    %init(BottomOverlay);
}
