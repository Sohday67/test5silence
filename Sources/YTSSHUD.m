#import "YTSSHUD.h"
#import "YTSSDefines.h"
#import <UIKit/UIKit.h>

@implementation YTSSHUD

+ (void)showMessage:(NSString *)message {
    if (!YTSSBoolDefault(YTSS_HUD_KEY, YES) || message.length == 0) return;

    Class hudMessageClass = NSClassFromString(@"YTHUDMessage");
    Class hudManagerClass = NSClassFromString(@"GOOHUDManagerInternal");
    if ([hudMessageClass respondsToSelector:@selector(messageWithText:)] &&
        [hudManagerClass respondsToSelector:@selector(sharedInstance)]) {
        id hudMessage = [hudMessageClass performSelector:@selector(messageWithText:) withObject:message];
        id manager = [hudManagerClass performSelector:@selector(sharedInstance)];
        if ([manager respondsToSelector:@selector(showMessageMainThread:)]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [manager performSelector:@selector(showMessageMainThread:) withObject:hudMessage];
            });
            return;
        }
    }

    NSLog(@"[YTSkipSilence] %@", message);
}

@end
