#import "AxsHeadsetPlayConfig.h"
#import "AxsHeadsetPlayPreferences.h"

@interface AxsHeadsetPlayConfig ()
@property (atomic, copy) NSDictionary *snapshot;
@property (nonatomic, strong) dispatch_queue_t reloadQueue;
@end

static void axs_headsetplay_preferencesDidChange(CFNotificationCenterRef center, void *observer,
                                          CFStringRef name, const void *object, CFDictionaryRef info) {
    AxsHeadsetPlayConfig *config = (__bridge AxsHeadsetPlayConfig *)observer;
    dispatch_async(config.reloadQueue, ^{
        [config axs_headsetplay_reload];
    });
}

@implementation AxsHeadsetPlayConfig

+ (instancetype)axs_headsetplay_shared {
    static AxsHeadsetPlayConfig *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _reloadQueue = dispatch_queue_create("com.axs.headsetplay.preferences", DISPATCH_QUEUE_SERIAL);
        [self axs_headsetplay_reload];
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
            (__bridge const void *)self, axs_headsetplay_preferencesDidChange,
            (__bridge CFStringRef)AxsHeadsetPlayPreferencesChanged, NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
        // Close the window between the first read and observer registration.
        dispatch_async(_reloadQueue, ^{ [self axs_headsetplay_reload]; });
    }
    return self;
}

- (void)axs_headsetplay_reload {
    self.snapshot = axs_headsetplay_readPreferences();
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:AxsHeadsetPlayPreferencesChanged object:self];
    });
}

- (id)axs_headsetplay_valueForKey:(NSString *)key defaultValue:(id)defaultValue {
    return self.snapshot[key] ?: defaultValue;
}

- (BOOL)axs_headsetplay_isEnabled {
    id value = [self axs_headsetplay_valueForKey:@"enabled" defaultValue:@NO];
    return [value isKindOfClass:[NSNumber class]] ? [value boolValue] : NO;
}

- (NSString *)axs_headsetplay_musicAppBundleID {
    id value = [self axs_headsetplay_valueForKey:@"musicApp" defaultValue:@"com.netease.cloudmusic"];
    return [value isKindOfClass:[NSString class]] && [value length] > 0 ? value : @"com.netease.cloudmusic";
}

- (BOOL)axs_headsetplay_autoPlay {
    id value = [self axs_headsetplay_valueForKey:@"autoPlay" defaultValue:@YES];
    return [value isKindOfClass:[NSNumber class]] ? [value boolValue] : YES;
}

- (BOOL)axs_headsetplay_skipIfPlaying {
    id value = [self axs_headsetplay_valueForKey:@"skipIfPlaying" defaultValue:@YES];
    return [value isKindOfClass:[NSNumber class]] ? [value boolValue] : YES;
}

- (void)dealloc {
    CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                            (__bridge const void *)self);
}

@end
