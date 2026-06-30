#import <Foundation/Foundation.h>

#define YTSS_TWEAK_KEY @"YTSkipSilence"
#define YTSS_ENABLED_KEY @"YTSkipSilenceEnabled"
#define YTSS_JUMP_MODE_KEY @"YTSkipSilenceJumpMode"
#define YTSS_AGGRESSIVE_KEY @"YTSkipSilenceAggressive"
#define YTSS_HUD_KEY @"YTSkipSilenceHUD"

static inline NSUserDefaults *YTSSDefaults(void) {
    return [NSUserDefaults standardUserDefaults];
}

static inline BOOL YTSSBoolDefault(NSString *key, BOOL fallback) {
    id value = [YTSSDefaults() objectForKey:key];
    return value ? [YTSSDefaults() boolForKey:key] : fallback;
}
