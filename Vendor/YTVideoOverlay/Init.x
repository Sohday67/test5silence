#import <dlfcn.h>
#import <Foundation/Foundation.h>
#import "Init.h"

#ifndef PS_ROOT_PATH
#define PS_ROOT_PATH(path) path
#endif

static void initYTVideoOverlay(NSString *tweakKey, NSDictionary *metadata) {
    NSString *inAppPath = [NSString stringWithFormat:@"%@/Frameworks/YTVideoOverlay.dylib", [[NSBundle mainBundle] bundlePath]];
    dlopen([inAppPath UTF8String], RTLD_LAZY);
    dlopen(PS_ROOT_PATH("/Library/MobileSubstrate/DynamicLibraries/YTVideoOverlay.dylib"), RTLD_LAZY);
    [NSClassFromString(@"YTSettingsSectionItemManager") registerTweak:tweakKey metadata:metadata];
}
