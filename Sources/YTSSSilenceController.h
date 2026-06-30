#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

@interface YTSSSilenceController : NSObject
@property (nonatomic, readonly, getter=isEnabled) BOOL enabled;
@property (nonatomic, readonly) BOOL jumpMode;

+ (instancetype)sharedController;
- (void)installDefaults;
- (BOOL)toggleEnabled;
- (BOOL)cycleMode;
- (void)attachToPlayer:(AVPlayer *)player item:(AVPlayerItem *)item reason:(NSString *)reason;
- (void)refreshAllSessions;
@end
