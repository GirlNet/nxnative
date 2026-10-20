#import <CoreHaptics/CoreHaptics.h>
#import <UIKit/UIKit.h>
#include <math.h>
#include <stdio.h>
#include "DmHaptics.h"

@interface DmHaptics : NSObject
@end

@implementation DmHaptics {
    dispatch_queue_t _queue;
    CHHapticEngine *_engine;
    id<CHHapticAdvancedPatternPlayer> _player;
    BOOL _running, _suspended;
    float _intensity, _sharpness;
}

static DmHaptics *g_haptics;
static float clamp01(float x) { return x < 0 ? 0 : x > 1 ? 1 : x; }

- (instancetype)init {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("dm.haptics", DISPATCH_QUEUE_SERIAL);
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        [nc addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:nil usingBlock:^(__unused NSNotification *n) {
            dispatch_async(self->_queue, ^{ self->_suspended = YES; [self stop]; });
        }];
        [nc addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:nil usingBlock:^(__unused NSNotification *n) {
            dispatch_async(self->_queue, ^{ self->_suspended = YES; [self stop]; });
        }];
        [nc addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:nil usingBlock:^(__unused NSNotification *n) {
            dispatch_async(self->_queue, ^{ self->_suspended = NO; [self apply]; });
        }];
    }
    return self;
}

- (void)stop {
    if (_player) { [_player stopAtTime:CHHapticTimeImmediate error:nil]; _player = nil; }
    if (_engine && _running) { [_engine stopWithCompletionHandler:nil]; _running = NO; }
}

- (BOOL)start {
    if (_running) return YES;
    if (!_engine) {
        _engine = [[CHHapticEngine alloc] initWithAudioSession:nil error:nil];
        if (!_engine) return NO;
        _engine.playsHapticsOnly = YES;
        _engine.autoShutdownEnabled = YES;
        __weak DmHaptics *weakSelf = self;
        _engine.stoppedHandler = ^(__unused CHHapticEngineStoppedReason reason) {
            DmHaptics *owner = weakSelf;
            if (!owner) return;
            dispatch_async(owner->_queue, ^{ owner->_running = NO; owner->_player = nil; [owner apply]; });
        };
        _engine.resetHandler = ^{
            DmHaptics *owner = weakSelf;
            if (!owner) return;
            dispatch_async(owner->_queue, ^{ owner->_running = NO; owner->_player = nil; [owner apply]; });
        };
    }
    NSError *error = nil;
    if (![_engine startAndReturnError:&error]) {
        fprintf(stderr, "HAPTIC start failed: %s\n", error.description.UTF8String);
        return NO;
    }
    _running = YES;
    return YES;
}

- (void)apply {
    if (_suspended || _intensity <= 0.002f) { [self stop]; return; }
    if (![self start]) return;
    NSArray *params = @[
        [[CHHapticDynamicParameter alloc] initWithParameterID:CHHapticDynamicParameterIDHapticIntensityControl value:_intensity relativeTime:0],
        [[CHHapticDynamicParameter alloc] initWithParameterID:CHHapticDynamicParameterIDHapticSharpnessControl value:_sharpness - 0.5f relativeTime:0],
    ];
    NSError *error = nil;
    if (!_player) {
        CHHapticEvent *event = [[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticContinuous parameters:@[
            [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity value:1],
            [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticSharpness value:0.5],
        ] relativeTime:0 duration:30];
        CHHapticPattern *pattern = [[CHHapticPattern alloc] initWithEvents:@[event] parameters:@[] error:&error];
        if (!pattern) return;
        _player = [_engine createAdvancedPlayerWithPattern:pattern error:&error];
        if (!_player) return;
        _player.loopEnabled = YES;
        _player.isMuted = YES;
        if (![_player startAtTime:CHHapticTimeImmediate error:&error]) { _player = nil; _running = NO; return; }
        if (![_player sendParameters:params atTime:CHHapticTimeImmediate error:&error]) { [self stop]; return; }
        _player.isMuted = NO;
    } else {
        [_player sendParameters:params atTime:CHHapticTimeImmediate error:&error];
    }
}

- (void)updateLow:(float)loAmp lowHz:(float)loHz high:(float)hiAmp highHz:(float)hiHz {
    float la = clamp01(loAmp), ha = clamp01(hiAmp);
    _intensity = fmaxf(la, ha);
    _sharpness = clamp01((la >= ha ? loHz : hiHz) / 1200.0f);
    dispatch_async(_queue, ^{ [self apply]; });
}
@end

void dm_haptic_update(float low_amp, float low_hz, float high_amp, float high_hz) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ g_haptics = [DmHaptics new]; });
    [g_haptics updateLow:low_amp lowHz:low_hz high:high_amp highHz:high_hz];
}
