// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import "FVPVideoPlayerPlugin.h"
#import "FVPVideoPlayerPlugin_Test.h"

#import <AVFoundation/AVFoundation.h>
#import <GLKit/GLKit.h>

#import "AVAssetTrackUtils.h"
#import "messages.g.h"

#if !__has_feature(objc_arc)
#error Code Requires ARC.
#endif

@interface FVPFrameUpdater : NSObject
@property(nonatomic) int64_t textureId;
@property(nonatomic, weak, readonly) NSObject<FlutterTextureRegistry> *registry;
// The output that this updater is managing.
@property(nonatomic, weak) AVPlayerItemVideoOutput *videoOutput;
#if TARGET_OS_IOS
- (void)onDisplayLink:(CADisplayLink *)link;
#endif
@end

@implementation FVPFrameUpdater
- (FVPFrameUpdater *)initWithRegistry:(NSObject<FlutterTextureRegistry> *)registry {
  NSAssert(self, @"super init cannot be nil");
  if (self == nil) return nil;
  _registry = registry;
  return self;
}

#if TARGET_OS_IOS
- (void)onDisplayLink:(CADisplayLink *)link {
  // TODO(stuartmorgan): Investigate switching this to displayLinkFired; iOS may also benefit from
  // the availability check there.
  [_registry textureFrameAvailable:_textureId];
}
#endif

- (void)displayLinkFired {
  // Only report a new frame if one is actually available.
  CMTime outputItemTime = [self.videoOutput itemTimeForHostTime:CACurrentMediaTime()];
  if ([self.videoOutput hasNewPixelBufferForItemTime:outputItemTime]) {
    [_registry textureFrameAvailable:_textureId];
  }
}
@end

#if TARGET_OS_OSX
static CVReturn DisplayLinkCallback(CVDisplayLinkRef displayLink, const CVTimeStamp *now,
                                    const CVTimeStamp *outputTime, CVOptionFlags flagsIn,
                                    CVOptionFlags *flagsOut, void *displayLinkSource) {
  // Trigger the main-thread dispatch queue, to drive a frame update check.
  __weak dispatch_source_t source = (__bridge dispatch_source_t)displayLinkSource;
  dispatch_source_merge_data(source, 1);
  return kCVReturnSuccess;
}
#endif

@interface FVPDefaultPlayerFactory : NSObject <FVPPlayerFactory>
@end

@implementation FVPDefaultPlayerFactory
- (AVPlayer *)playerWithPlayerItem:(AVPlayerItem *)playerItem {
  return [AVPlayer playerWithPlayerItem:playerItem];
}

@end

@interface FVPVideoPlayer : NSObject <FlutterTexture, FlutterStreamHandler>
@property(readonly, nonatomic) AVPlayer *player;
@property(readonly, nonatomic) AVPlayerItemVideoOutput *videoOutput;
// This is to fix 2 bugs: 1. blank video for encrypted video streams on iOS 16
// (https://github.com/flutter/flutter/issues/111457) and 2. swapped width and height for some video
// streams (not just iOS 16).  (https://github.com/flutter/flutter/issues/109116).
// An invisible AVPlayerLayer is used to overwrite the protection of pixel buffers in those streams
// for issue #1, and restore the correct width and height for issue #2.
@property(readonly, nonatomic) AVPlayerLayer *playerLayer;
// The plugin registrar, to obtain view information from.
@property(nonatomic, weak) NSObject<FlutterPluginRegistrar> *registrar;
// The CALayer associated with the Flutter view this plugin is associated with, if any.
@property(nonatomic, readonly) CALayer *flutterViewLayer;
@property(nonatomic) FlutterEventChannel *eventChannel;
@property(nonatomic) FlutterEventSink eventSink;
@property(nonatomic) CGAffineTransform preferredTransform;
@property(nonatomic, readonly) BOOL disposed;
@property(nonatomic, readonly) BOOL isPlaying;
@property(nonatomic) BOOL isLooping;
@property(nonatomic, readonly) BOOL isInitialized;
// TODO(stuartmorgan): Extract and abstract the display link to remove all the display-link-related
// ifdefs from this file.
#if TARGET_OS_OSX
// The display link to trigger frame reads from the video player.
@property(nonatomic, assign) CVDisplayLinkRef displayLink;
// A dispatch source to move display link callbacks to the main thread.
@property(nonatomic, strong) dispatch_source_t displayLinkSource;
#else
@property(nonatomic) CADisplayLink *displayLink;
#endif

- (instancetype)initWithURL:(NSURL *)url
               frameUpdater:(FVPFrameUpdater *)frameUpdater
                httpHeaders:(nonnull NSDictionary<NSString *, NSString *> *)headers
              playerFactory:(id<FVPPlayerFactory>)playerFactory
                  registrar:(NSObject<FlutterPluginRegistrar> *)registrar;
@end

static void *timeRangeContext = &timeRangeContext;
static void *statusContext = &statusContext;
static void *presentationSizeContext = &presentationSizeContext;
static void *durationContext = &durationContext;
static void *playbackLikelyToKeepUpContext = &playbackLikelyToKeepUpContext;
static void *rateContext = &rateContext;

@implementation FVPVideoPlayer
- (instancetype)initWithAsset:(NSString *)asset
                 frameUpdater:(FVPFrameUpdater *)frameUpdater
                playerFactory:(id<FVPPlayerFactory>)playerFactory
                    registrar:(NSObject<FlutterPluginRegistrar> *)registrar {
  NSString *path = [[NSBundle mainBundle] pathForResource:asset ofType:nil];
#if TARGET_OS_OSX
  // See https://github.com/flutter/flutter/issues/135302
  // TODO(stuartmorgan): Remove this if the asset APIs are adjusted to work better for macOS.
  if (!path) {
    path = [NSURL URLWithString:asset relativeToURL:NSBundle.mainBundle.bundleURL].path;
  }
#endif
  return [self initWithURL:[NSURL fileURLWithPath:path]
              frameUpdater:frameUpdater
               httpHeaders:@{}
             playerFactory:playerFactory
                 registrar:registrar];
}

- (void)dealloc {
  if (!_disposed) {
    [self removeKeyValueObservers];
  }
}

- (void)addObserversForItem:(AVPlayerItem *)item player:(AVPlayer *)player {
  [item addObserver:self
         forKeyPath:@"loadedTimeRanges"
            options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
            context:timeRangeContext];
  [item addObserver:self
         forKeyPath:@"status"
            options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
            context:statusContext];
  [item addObserver:self
         forKeyPath:@"presentationSize"
            options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
            context:presentationSizeContext];
  [item addObserver:self
         forKeyPath:@"duration"
            options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
            context:durationContext];
  [item addObserver:self
         forKeyPath:@"playbackLikelyToKeepUp"
            options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
            context:playbackLikelyToKeepUpContext];

  // Add observer to AVPlayer instead of AVPlayerItem since the AVPlayerItem does not have a "rate"
  // property
  [player addObserver:self
           forKeyPath:@"rate"
              options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
              context:rateContext];

  // Add an observer that will respond to itemDidPlayToEndTime
  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(itemDidPlayToEndTime:)
                                               name:AVPlayerItemDidPlayToEndTimeNotification
                                             object:item];
}

- (void)itemDidPlayToEndTime:(NSNotification *)notification {
  if (_isLooping) {
    AVPlayerItem *p = [notification object];
    [p seekToTime:kCMTimeZero completionHandler:nil];
  } else {
    if (_eventSink) {
      _eventSink(@{@"event" : @"completed"});
    }
  }
}

const int64_t TIME_UNSET = -9223372036854775807;

NS_INLINE int64_t FVPCMTimeToMillis(CMTime time) {
  // When CMTIME_IS_INDEFINITE return a value that matches TIME_UNSET from ExoPlayer2 on Android.
  // Fixes https://github.com/flutter/flutter/issues/48670
  if (CMTIME_IS_INDEFINITE(time)) return TIME_UNSET;
  if (time.timescale == 0) return 0;
  return time.value * 1000 / time.timescale;
}

NS_INLINE CGFloat radiansToDegrees(CGFloat radians) {
  // Input range [-pi, pi] or [-180, 180]
  CGFloat degrees = GLKMathRadiansToDegrees((float)radians);
  if (degrees < 0) {
    // Convert -90 to 270 and -180 to 180
    return degrees + 360;
  }
  // Output degrees in between [0, 360]
  return degrees;
};

- (AVMutableVideoComposition *)getVideoCompositionWithTransform:(CGAffineTransform)transform
                                                      withAsset:(AVAsset *)asset
                                                 withVideoTrack:(AVAssetTrack *)videoTrack {
  AVMutableVideoCompositionInstruction *instruction =
      [AVMutableVideoCompositionInstruction videoCompositionInstruction];
  instruction.timeRange = CMTimeRangeMake(kCMTimeZero, [asset duration]);
  AVMutableVideoCompositionLayerInstruction *layerInstruction =
      [AVMutableVideoCompositionLayerInstruction
          videoCompositionLayerInstructionWithAssetTrack:videoTrack];
  [layerInstruction setTransform:_preferredTransform atTime:kCMTimeZero];

  AVMutableVideoComposition *videoComposition = [AVMutableVideoComposition videoComposition];
  instruction.layerInstructions = @[ layerInstruction ];
  videoComposition.instructions = @[ instruction ];

  // If in portrait mode, switch the width and height of the video
  CGFloat width = videoTrack.naturalSize.width;
  CGFloat height = videoTrack.naturalSize.height;
  NSInteger rotationDegrees =
      (NSInteger)round(radiansToDegrees(atan2(_preferredTransform.b, _preferredTransform.a)));
  if (rotationDegrees == 90 || rotationDegrees == 270) {
    width = videoTrack.naturalSize.height;
    height = videoTrack.naturalSize.width;
  }
  videoComposition.renderSize = CGSizeMake(width, height);

  // TODO(@recastrodiaz): should we use videoTrack.nominalFrameRate ?
  // Currently set at a constant 30 FPS
  videoComposition.frameDuration = CMTimeMake(1, 30);

  return videoComposition;
}

- (void)createVideoOutputAndDisplayLink:(FVPFrameUpdater *)frameUpdater {
  NSDictionary *pixBuffAttributes = @{
    (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
    (id)kCVPixelBufferIOSurfacePropertiesKey : @{}
  };
  _videoOutput = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:pixBuffAttributes];

#if TARGET_OS_OSX
  frameUpdater.videoOutput = _videoOutput;
  // Create and start the main-thread dispatch queue to drive frameUpdater.
  self.displayLinkSource =
      dispatch_source_create(DISPATCH_SOURCE_TYPE_DATA_ADD, 0, 0, dispatch_get_main_queue());
  dispatch_source_set_event_handler(self.displayLinkSource, ^() {
    @autoreleasepool {
      [frameUpdater displayLinkFired];
    }
  });
  dispatch_resume(self.displayLinkSource);
  if (CVDisplayLinkCreateWithActiveCGDisplays(&_displayLink) == kCVReturnSuccess) {
    CVDisplayLinkSetOutputCallback(_displayLink, &DisplayLinkCallback,
                                   (__bridge void *)(self.displayLinkSource));
  }
#else
  _displayLink = [CADisplayLink displayLinkWithTarget:frameUpdater
                                             selector:@selector(onDisplayLink:)];
  [_displayLink addToRunLoop:[NSRunLoop currentRunLoop] forMode:NSRunLoopCommonModes];
  _displayLink.paused = YES;
#endif
}

- (instancetype)initWithURL:(NSURL *)url
               frameUpdater:(FVPFrameUpdater *)frameUpdater
                httpHeaders:(nonnull NSDictionary<NSString *, NSString *> *)headers
              playerFactory:(id<FVPPlayerFactory>)playerFactory
                  registrar:(NSObject<FlutterPluginRegistrar> *)registrar {
  NSDictionary<NSString *, id> *options = nil;
  if ([headers count] != 0) {
    options = @{@"AVURLAssetHTTPHeaderFieldsKey" : headers};
  }
  AVURLAsset *urlAsset = [AVURLAsset URLAssetWithURL:url options:options];
  AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:urlAsset];
  return [self initWithPlayerItem:item
                     frameUpdater:frameUpdater
                    playerFactory:playerFactory
                        registrar:registrar];
}

- (instancetype)initWithPlayerItem:(AVPlayerItem *)item
                      frameUpdater:(FVPFrameUpdater *)frameUpdater
                     playerFactory:(id<FVPPlayerFactory>)playerFactory
                         registrar:(NSObject<FlutterPluginRegistrar> *)registrar {
  self = [super init];
  NSAssert(self, @"super init cannot be nil");

  _registrar = registrar;

  AVAsset *asset = [item asset];
  void (^assetCompletionHandler)(void) = ^{
    if ([asset statusOfValueForKey:@"tracks" error:nil] == AVKeyValueStatusLoaded) {
      NSArray *tracks = [asset tracksWithMediaType:AVMediaTypeVideo];
      if ([tracks count] > 0) {
        AVAssetTrack *videoTrack = tracks[0];
        void (^trackCompletionHandler)(void) = ^{
          if (self->_disposed) return;
          if ([videoTrack statusOfValueForKey:@"preferredTransform"
                                        error:nil] == AVKeyValueStatusLoaded) {
            // Rotate the video by using a videoComposition and the preferredTransform
            self->_preferredTransform = FVPGetStandardizedTransformForTrack(videoTrack);
            // Note:
            // https://developer.apple.com/documentation/avfoundation/avplayeritem/1388818-videocomposition
            // Video composition can only be used with file-based media and is not supported for
            // use with media served using HTTP Live Streaming.
            AVMutableVideoComposition *videoComposition =
                [self getVideoCompositionWithTransform:self->_preferredTransform
                                             withAsset:asset
                                        withVideoTrack:videoTrack];
            item.videoComposition = videoComposition;
          }
        };
        [videoTrack loadValuesAsynchronouslyForKeys:@[ @"preferredTransform" ]
                                  completionHandler:trackCompletionHandler];
      }
    }
  };

  _player = [playerFactory playerWithPlayerItem:item];
  _player.actionAtItemEnd = AVPlayerActionAtItemEndNone;

  // This is to fix 2 bugs: 1. blank video for encrypted video streams on iOS 16
  // (https://github.com/flutter/flutter/issues/111457) and 2. swapped width and height for some
  // video streams (not just iOS 16).  (https://github.com/flutter/flutter/issues/109116). An
  // invisible AVPlayerLayer is used to overwrite the protection of pixel buffers in those streams
  // for issue #1, and restore the correct width and height for issue #2.
  _playerLayer = [AVPlayerLayer playerLayerWithPlayer:_player];
  [self.flutterViewLayer addSublayer:_playerLayer];

  [self createVideoOutputAndDisplayLink:frameUpdater];

  [self addObserversForItem:item player:_player];

  [asset loadValuesAsynchronouslyForKeys:@[ @"tracks" ] completionHandler:assetCompletionHandler];

  return self;
}

- (void)observeValueForKeyPath:(NSString *)path
                      ofObject:(id)object
                        change:(NSDictionary *)change
                       context:(void *)context {
  if (context == timeRangeContext) {
    if (_eventSink != nil) {
      NSMutableArray<NSArray<NSNumber *> *> *values = [[NSMutableArray alloc] init];
      for (NSValue *rangeValue in [object loadedTimeRanges]) {
        CMTimeRange range = [rangeValue CMTimeRangeValue];
        int64_t start = FVPCMTimeToMillis(range.start);
        [values addObject:@[ @(start), @(start + FVPCMTimeToMillis(range.duration)) ]];
      }
      _eventSink(@{@"event" : @"bufferingUpdate", @"values" : values});
    }
  } else if (context == statusContext) {
    AVPlayerItem *item = (AVPlayerItem *)object;
    switch (item.status) {
      case AVPlayerItemStatusFailed:
        if (_eventSink != nil) {
          _eventSink([FlutterError
              errorWithCode:@"VideoError"
                    message:[@"Failed to load video: "
                                stringByAppendingString:[item.error localizedDescription]]
                    details:nil]);
        }
        break;
      case AVPlayerItemStatusUnknown:
        break;
      case AVPlayerItemStatusReadyToPlay:
        [item addOutput:_videoOutput];
        [self setupEventSinkIfReadyToPlay];
        [self updatePlayingState];
        break;
    }
  } else if (context == presentationSizeContext || context == durationContext) {
    AVPlayerItem *item = (AVPlayerItem *)object;
    if (item.status == AVPlayerItemStatusReadyToPlay) {
      // Due to an apparent bug, when the player item is ready, it still may not have determined
      // its presentation size or duration. When these properties are finally set, re-check if
      // all required properties and instantiate the event sink if it is not already set up.
      [self setupEventSinkIfReadyToPlay];
      [self updatePlayingState];
    }
  } else if (context == playbackLikelyToKeepUpContext) {
    [self updatePlayingState];
    if ([[_player currentItem] isPlaybackLikelyToKeepUp]) {
      if (_eventSink != nil) {
        _eventSink(@{@"event" : @"bufferingEnd"});
      }
    } else {
      if (_eventSink != nil) {
        _eventSink(@{@"event" : @"bufferingStart"});
      }
    }
  } else if (context == rateContext) {
    // Important: Make sure to cast the object to AVPlayer when observing the rate property,
    // as it is not available in AVPlayerItem.
    AVPlayer *player = (AVPlayer *)object;
    if (_eventSink != nil) {
      _eventSink(
          @{@"event" : @"isPlayingStateUpdate", @"isPlaying" : player.rate > 0 ? @YES : @NO});
    }
  }
}

- (void)updatePlayingState {
  if (!_isInitialized) {
    return;
  }
  if (_isPlaying) {
    [_player play];
  } else {
    [_player pause];
  }
#if TARGET_OS_OSX
  if (_displayLink) {
    if (_isPlaying) {
      NSScreen *screen = self.registrar.view.window.screen;
      if (screen) {
        CGDirectDisplayID viewDisplayID =
            (CGDirectDisplayID)[screen.deviceDescription[@"NSScreenNumber"] unsignedIntegerValue];
        CVDisplayLinkSetCurrentCGDisplay(_displayLink, viewDisplayID);
      }
      CVDisplayLinkStart(_displayLink);
    } else {
      CVDisplayLinkStop(_displayLink);
    }
  }
#else
  _displayLink.paused = !_isPlaying;
#endif
}

- (void)setupEventSinkIfReadyToPlay {
  if (_eventSink && !_isInitialized) {
    AVPlayerItem *currentItem = self.player.currentItem;
    CGSize size = currentItem.presentationSize;
    CGFloat width = size.width;
    CGFloat height = size.height;

    // Wait until tracks are loaded to check duration or if there are any videos.
    AVAsset *asset = currentItem.asset;
    if ([asset statusOfValueForKey:@"tracks" error:nil] != AVKeyValueStatusLoaded) {
      void (^trackCompletionHandler)(void) = ^{
        if ([asset statusOfValueForKey:@"tracks" error:nil] != AVKeyValueStatusLoaded) {
          // Cancelled, or something failed.
          return;
        }
        // This completion block will run on an AVFoundation background queue.
        // Hop back to the main thread to set up event sink.
        [self performSelector:_cmd onThread:NSThread.mainThread withObject:self waitUntilDone:NO];
      };
      [asset loadValuesAsynchronouslyForKeys:@[ @"tracks" ]
                           completionHandler:trackCompletionHandler];
      return;
    }

    BOOL hasVideoTracks = [asset tracksWithMediaType:AVMediaTypeVideo].count != 0;
    BOOL hasNoTracks = asset.tracks.count == 0;

    // The player has not yet initialized when it has no size, unless it is an audio-only track.
    // HLS m3u8 video files never load any tracks, and are also not yet initialized until they have
    // a size.
    if ((hasVideoTracks || hasNoTracks) && height == CGSizeZero.height &&
        width == CGSizeZero.width) {
      return;
    }
    // The player may be initialized but still needs to determine the duration.
    int64_t duration = [self duration];
    if (duration == 0) {
      return;
    }

    _isInitialized = YES;
    _eventSink(@{
      @"event" : @"initialized",
      @"duration" : @(duration),
      @"width" : @(width),
      @"height" : @(height)
    });
  }
}

- (void)play {
  _isPlaying = YES;
  [self updatePlayingState];
}

- (void)pause {
  _isPlaying = NO;
  [self updatePlayingState];
}

- (int64_t)position {
  return FVPCMTimeToMillis([_player currentTime]);
}

- (int64_t)duration {
  // Note: https://openradar.appspot.com/radar?id=4968600712511488
  // `[AVPlayerItem duration]` can be `kCMTimeIndefinite`,
  // use `[[AVPlayerItem asset] duration]` instead.
  return FVPCMTimeToMillis([[[_player currentItem] asset] duration]);
}

- (void)seekTo:(int)location completionHandler:(void (^)(BOOL))completionHandler {
  CMTime locationCMT = CMTimeMake(location, 1000);
  CMTimeValue duration = _player.currentItem.asset.duration.value;
  // Without adding tolerance when seeking to duration,
  // seekToTime will never complete, and this call will hang.
  // see issue https://github.com/flutter/flutter/issues/124475.
  CMTime tolerance = location == duration ? CMTimeMake(1, 1000) : kCMTimeZero;
  [_player seekToTime:locationCMT
        toleranceBefore:tolerance
         toleranceAfter:tolerance
      completionHandler:completionHandler];
}

- (void)setIsLooping:(BOOL)isLooping {
  _isLooping = isLooping;
}

- (void)setVolume:(double)volume {
  _player.volume = (float)((volume < 0.0) ? 0.0 : ((volume > 1.0) ? 1.0 : volume));
}

- (void)setPlaybackSpeed:(double)speed {
  // See https://developer.apple.com/library/archive/qa/qa1772/_index.html for an explanation of
  // these checks.
  if (speed > 2.0 && !_player.currentItem.canPlayFastForward) {
    if (_eventSink != nil) {
      _eventSink([FlutterError errorWithCode:@"VideoError"
                                     message:@"Video cannot be fast-forwarded beyond 2.0x"
                                     details:nil]);
    }
    return;
  }

  if (speed < 1.0 && !_player.currentItem.canPlaySlowForward) {
    if (_eventSink != nil) {
      _eventSink([FlutterError errorWithCode:@"VideoError"
                                     message:@"Video cannot be slow-forwarded"
                                     details:nil]);
    }
    return;
  }

  _player.rate = speed;
}

- (CVPixelBufferRef)copyPixelBuffer {
  CMTime outputItemTime = [_videoOutput itemTimeForHostTime:CACurrentMediaTime()];
  if ([_videoOutput hasNewPixelBufferForItemTime:outputItemTime]) {
    return [_videoOutput copyPixelBufferForItemTime:outputItemTime itemTimeForDisplay:NULL];
  } else {
    return NULL;
  }
}

- (void)onTextureUnregistered:(NSObject<FlutterTexture> *)texture {
  dispatch_async(dispatch_get_main_queue(), ^{
    [self dispose];
  });
}

- (FlutterError *_Nullable)onCancelWithArguments:(id _Nullable)arguments {
  _eventSink = nil;
  return nil;
}

- (FlutterError *_Nullable)onListenWithArguments:(id _Nullable)arguments
                                       eventSink:(nonnull FlutterEventSink)events {
  _eventSink = events;
  // TODO(@recastrodiaz): remove the line below when the race condition is resolved:
  // https://github.com/flutter/flutter/issues/21483
  // This line ensures the 'initialized' event is sent when the event
  // 'AVPlayerItemStatusReadyToPlay' fires before _eventSink is set (this function
  // onListenWithArguments is called)
  [self setupEventSinkIfReadyToPlay];
  return nil;
}

/// This method allows you to dispose without touching the event channel.  This
/// is useful for the case where the Engine is in the process of deconstruction
/// so the channel is going to die or is already dead.
- (void)disposeSansEventChannel {
  // This check prevents the crash caused by removing the KVO observers twice.
  // When performing a Hot Restart, the leftover players are disposed once directly
  // by [FVPVideoPlayerPlugin initialize:] method and then disposed again by
  // [FVPVideoPlayer onTextureUnregistered:] call leading to possible over-release.
  if (_disposed) {
    return;
  }

  _disposed = YES;
  [_playerLayer removeFromSuperlayer];
#if TARGET_OS_OSX
  if (_displayLink) {
    CVDisplayLinkStop(_displayLink);
    CVDisplayLinkRelease(_displayLink);
    _displayLink = NULL;
  }
  dispatch_source_cancel(_displayLinkSource);
#else
  [_displayLink invalidate];
#endif
  [self removeKeyValueObservers];

  [self.player replaceCurrentItemWithPlayerItem:nil];
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)dispose {
  [self disposeSansEventChannel];
  [_eventChannel setStreamHandler:nil];
}

- (CALayer *)flutterViewLayer {
#if TARGET_OS_OSX
  return self.registrar.view.layer;
#else
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  // TODO(hellohuanlin): Provide a non-deprecated codepath. See
  // https://github.com/flutter/flutter/issues/104117
  UIViewController *root = UIApplication.sharedApplication.keyWindow.rootViewController;
#pragma clang diagnostic pop
  return root.view.layer;
#endif
}

/// Removes all key-value observers set up for the player.
///
/// This is called from dealloc, so must not use any methods on self.
- (void)removeKeyValueObservers {
  AVPlayerItem *currentItem = _player.currentItem;
  [currentItem removeObserver:self forKeyPath:@"status"];
  [currentItem removeObserver:self forKeyPath:@"loadedTimeRanges"];
  [currentItem removeObserver:self forKeyPath:@"presentationSize"];
  [currentItem removeObserver:self forKeyPath:@"duration"];
  [currentItem removeObserver:self forKeyPath:@"playbackLikelyToKeepUp"];
  [_player removeObserver:self forKeyPath:@"rate"];
}

@end

@interface FVPVideoPlayerPlugin () <FVPAVFoundationVideoPlayerApi>
@property(readonly, weak, nonatomic) NSObject<FlutterTextureRegistry> *registry;
@property(readonly, weak, nonatomic) NSObject<FlutterBinaryMessenger> *messenger;
@property(readonly, strong, nonatomic)
    NSMutableDictionary<NSNumber *, FVPVideoPlayer *> *playersByTextureId;
@property(readonly, strong, nonatomic) NSObject<FlutterPluginRegistrar> *registrar;
@property(nonatomic, strong) id<FVPPlayerFactory> playerFactory;
@end

@implementation FVPVideoPlayerPlugin
+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
  FVPVideoPlayerPlugin *instance = [[FVPVideoPlayerPlugin alloc] initWithRegistrar:registrar];
#if !TARGET_OS_OSX
  // TODO(stuartmorgan): Remove the ifdef once >3.13 reaches stable. See
  // https://github.com/flutter/flutter/issues/135320
  [registrar publish:instance];
#endif
  FVPAVFoundationVideoPlayerApiSetup(registrar.messenger, instance);
}

- (instancetype)initWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
  return [self initWithPlayerFactory:[[FVPDefaultPlayerFactory alloc] init] registrar:registrar];
}

- (instancetype)initWithPlayerFactory:(id<FVPPlayerFactory>)playerFactory
                            registrar:(NSObject<FlutterPluginRegistrar> *)registrar {
  self = [super init];
  NSAssert(self, @"super init cannot be nil");
  _registry = [registrar textures];
  _messenger = [registrar messenger];
  _registrar = registrar;
  _playerFactory = playerFactory;
  _playersByTextureId = [NSMutableDictionary dictionaryWithCapacity:1];
  return self;
}

- (void)detachFromEngineForRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
  [self.playersByTextureId.allValues makeObjectsPerformSelector:@selector(disposeSansEventChannel)];
  [self.playersByTextureId removeAllObjects];
  // TODO(57151): This should be commented out when 57151's fix lands on stable.
  // This is the correct behavior we never did it in the past and the engine
  // doesn't currently support it.
  // FVPAVFoundationVideoPlayerApiSetup(registrar.messenger, nil);
}

- (FVPTextureMessage *)onPlayerSetup:(FVPVideoPlayer *)player
                        frameUpdater:(FVPFrameUpdater *)frameUpdater {
  int64_t textureId = [self.registry registerTexture:player];
  frameUpdater.textureId = textureId;
  FlutterEventChannel *eventChannel = [FlutterEventChannel
      eventChannelWithName:[NSString stringWithFormat:@"flutter.io/videoPlayer/videoEvents%lld",
                                                      textureId]
           binaryMessenger:_messenger];
  [eventChannel setStreamHandler:player];
  player.eventChannel = eventChannel;
  self.playersByTextureId[@(textureId)] = player;
  FVPTextureMessage *result = [FVPTextureMessage makeWithTextureId:@(textureId)];
  return result;
}

- (void)initialize:(FlutterError *__autoreleasing *)error {
#if TARGET_OS_IOS
  // Allow audio playback when the Ring/Silent switch is set to silent
  [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:nil];
#endif

  [self.playersByTextureId
      enumerateKeysAndObjectsUsingBlock:^(NSNumber *textureId, FVPVideoPlayer *player, BOOL *stop) {
        [self.registry unregisterTexture:textureId.unsignedIntegerValue];
        [player dispose];
      }];
  [self.playersByTextureId removeAllObjects];
}

- (FVPTextureMessage *)create:(FVPCreateMessage *)input error:(FlutterError **)error {
  FVPFrameUpdater *frameUpdater = [[FVPFrameUpdater alloc] initWithRegistry:_registry];
  FVPVideoPlayer *player;
  if (input.asset) {
    NSString *assetPath;
    if (input.packageName) {
      assetPath = [_registrar lookupKeyForAsset:input.asset fromPackage:input.packageName];
    } else {
      assetPath = [_registrar lookupKeyForAsset:input.asset];
    }
    @try {
      player = [[FVPVideoPlayer alloc] initWithAsset:assetPath
                                        frameUpdater:frameUpdater
                                       playerFactory:_playerFactory
                                           registrar:self.registrar];
      return [self onPlayerSetup:player frameUpdater:frameUpdater];
    } @catch (NSException *exception) {
      *error = [FlutterError errorWithCode:@"video_player" message:exception.reason details:nil];
      return nil;
    }
  } else if (input.uri) {
    player = [[FVPVideoPlayer alloc] initWithURL:[NSURL URLWithString:input.uri]
                                    frameUpdater:frameUpdater
                                     httpHeaders:input.httpHeaders
                                   playerFactory:_playerFactory
                                       registrar:self.registrar];
    return [self onPlayerSetup:player frameUpdater:frameUpdater];
  } else {
    *error = [FlutterError errorWithCode:@"video_player" message:@"not implemented" details:nil];
    return nil;
  }
}

- (void)dispose:(FVPTextureMessage *)input error:(FlutterError **)error {
  FVPVideoPlayer *player = self.playersByTextureId[input.textureId];
  [self.registry unregisterTexture:input.textureId.intValue];
  [self.playersByTextureId removeObjectForKey:input.textureId];
  // If the Flutter contains https://github.com/flutter/engine/pull/12695,
  // the `player` is disposed via `onTextureUnregistered` at the right time.
  // Without https://github.com/flutter/engine/pull/12695, there is no guarantee that the
  // texture has completed the un-reregistration. It may leads a crash if we dispose the
  // `player` before the texture is unregistered. We add a dispatch_after hack to make sure the
  // texture is unregistered before we dispose the `player`.
  //
  // TODO(cyanglaz): Remove this dispatch block when
  // https://github.com/flutter/flutter/commit/8159a9906095efc9af8b223f5e232cb63542ad0b is in
  // stable And update the min flutter version of the plugin to the stable version.
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
                   if (!player.disposed) {
                     [player dispose];
                   }
                 });
}

- (void)setLooping:(FVPLoopingMessage *)input error:(FlutterError **)error {
  FVPVideoPlayer *player = self.playersByTextureId[input.textureId];
  player.isLooping = input.isLooping.boolValue;
}

- (void)setVolume:(FVPVolumeMessage *)input error:(FlutterError **)error {
  FVPVideoPlayer *player = self.playersByTextureId[input.textureId];
  [player setVolume:input.volume.doubleValue];
}

- (void)setPlaybackSpeed:(FVPPlaybackSpeedMessage *)input error:(FlutterError **)error {
  FVPVideoPlayer *player = self.playersByTextureId[input.textureId];
  [player setPlaybackSpeed:input.speed.doubleValue];
}

- (void)play:(FVPTextureMessage *)input error:(FlutterError **)error {
  FVPVideoPlayer *player = self.playersByTextureId[input.textureId];
  [player play];
}

- (FVPPositionMessage *)position:(FVPTextureMessage *)input error:(FlutterError **)error {
  FVPVideoPlayer *player = self.playersByTextureId[input.textureId];
  FVPPositionMessage *result = [FVPPositionMessage makeWithTextureId:input.textureId
                                                            position:@([player position])];
  return result;
}

- (void)seekTo:(FVPPositionMessage *)input
    completion:(void (^)(FlutterError *_Nullable))completion {
  FVPVideoPlayer *player = self.playersByTextureId[input.textureId];
  [player seekTo:input.position.intValue
      completionHandler:^(BOOL finished) {
        dispatch_async(dispatch_get_main_queue(), ^{
          [self.registry textureFrameAvailable:input.textureId.intValue];
          completion(nil);
        });
      }];
}

- (void)pause:(FVPTextureMessage *)input error:(FlutterError **)error {
  FVPVideoPlayer *player = self.playersByTextureId[input.textureId];
  [player pause];
}

- (void)setMixWithOthers:(FVPMixWithOthersMessage *)input
                   error:(FlutterError *_Nullable __autoreleasing *)error {
#if TARGET_OS_OSX
  // AVAudioSession doesn't exist on macOS, and audio always mixes, so just no-op.
#else
  if (input.mixWithOthers.boolValue) {
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback
                                     withOptions:AVAudioSessionCategoryOptionMixWithOthers
                                           error:nil];
  } else {
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:nil];
  }
#endif
}

@end
