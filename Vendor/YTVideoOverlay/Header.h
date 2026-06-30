#import <UIKit/UIKit.h>

@class YTFrostedGlassView;
@class YTQTMButton;
@class YTSettingsSectionItemManager;

@interface YTQTMButton : UIButton
@end

@interface YTFrostedGlassView : UIView
@end

@interface YTSettingsSectionItemManager (YTVideoOverlay)
- (void)updateYTVideoOverlaySectionWithEntry:(id)entry;
@end

@interface YTMainAppControlsOverlayView : UIView
@property (retain, nonatomic) NSMutableDictionary<NSString *, YTQTMButton *> *overlayButtons;
- (UIImage *)buttonImage:(NSString *)tweakId;
@end

@interface YTInlinePlayerBarContainerView : UIView
@property (retain, nonatomic) NSMutableDictionary<NSString *, YTQTMButton *> *overlayButtons;
@property (retain, nonatomic) NSMutableDictionary<NSString *, YTFrostedGlassView *> *overlayGlasses;
- (UIImage *)buttonImage:(NSString *)tweakId;
@end

#define OVERLAY_BUTTON_SIZE 24
