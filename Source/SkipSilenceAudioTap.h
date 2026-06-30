//
//  SkipSilenceAudioTap.h
//  YTSkipSilence
//
//  Wraps MTAudioProcessingTap to attach to an AVPlayerItem's audio tracks
//  and stream raw samples to a delegate (SkipSilenceDetector).
//
//  MTAudioProcessingTap is Apple's official, app-store-safe way to inspect
//  audio being played by AVPlayer without breaking DRM / FairPlay. The tap
//  receives AudioBufferLists in the audio track's native format and can
//  pass them through unmodified (we don't alter audio — we just measure it).
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <MediaToolbox/MediaToolbox.h>
#import <AudioToolbox/AudioToolbox.h>

NS_ASSUME_NONNULL_BEGIN

@class SkipSilenceAudioTap;

@protocol SkipSilenceAudioTapDelegate <NSObject>
@required
/// Called from the audio-processing-tap callback. The delegate MUST NOT do
/// heavy work here — just memcpy / state-machine bookkeeping and return.
- (void)audioTap:(SkipSilenceAudioTap *)tap
   didReceiveAudio:(const AudioBufferList *)bufferList
       framesCount:(UInt32)frames
            format:(AudioStreamBasicDescription)format;
@end

@interface SkipSilenceAudioTap : NSObject

@property (nonatomic, weak) id<SkipSilenceAudioTapDelegate> delegate;

/// Attach this tap to all audio tracks of the given AVPlayerItem.
/// Returns YES on success. Idempotent — calling twice is a no-op.
- (BOOL)attachToPlayerItem:(AVPlayerItem *)playerItem;

/// Detach from any previously-attached AVPlayerItem.
- (void)detach;

/// YES if currently attached to a player item.
@property (nonatomic, readonly, getter=isAttached) BOOL attached;

@end

NS_ASSUME_NONNULL_END
