#import "AxsHeadsetPlayController.h"
#import "AxsHeadsetPlayCatalog.h"
#import "AxsHeadsetPlayConfig.h"
#import "AxsHeadsetPlayPrivate.h"

#import <AVFoundation/AVFoundation.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <os/lock.h>

static const NSTimeInterval kAxsHeadsetPlayCooldown = 12.0;
static const int64_t kAxsHeadsetPlayConnectDelayNs = (int64_t)(2.6 * NSEC_PER_SEC);
static const int64_t kAxsHeadsetPlayRouteWaitNs = (int64_t)(1.0 * NSEC_PER_SEC);
static const NSTimeInterval kAxsHeadsetPlayRetryDelays[] = {1.8, 3.8, 6.5, 10.0};
enum { kAxsHeadsetPlayRetryCount = 4 };
enum { kAxsHeadsetPlayMRPlay = 0 };

static os_unfair_lock gAxsHeadsetPlayLock = OS_UNFAIR_LOCK_INIT;
static NSTimeInterval gAxsHeadsetPlayLastFire = 0;
static dispatch_block_t gAxsHeadsetPlayPending = nil;
static NSSet<NSString *> *gAxsHeadsetPlayKnownAddresses = nil;
static BOOL gAxsHeadsetPlayHasBaseline = NO;
static NSUInteger gAxsHeadsetPlayGeneration = 0;

static void (*axs_headsetplay_MRMediaRemoteSendCommand)(int command, id userInfo);
static void (*axs_headsetplay_MRMediaRemoteGetNowPlayingApplicationIsPlaying)(dispatch_queue_t queue, void (^block)(Boolean isPlaying));

static void axs_headsetplay_loadMediaRemote(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void *handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
        if (!handle) {
            return;
        }
        axs_headsetplay_MRMediaRemoteSendCommand = dlsym(handle, "MRMediaRemoteSendCommand");
        axs_headsetplay_MRMediaRemoteGetNowPlayingApplicationIsPlaying =
            dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    });
}

static void axs_headsetplay_queryPlaying(void (^completion)(BOOL playing)) {
    if (!axs_headsetplay_MRMediaRemoteGetNowPlayingApplicationIsPlaying) {
        completion(NO);
        return;
    }
    axs_headsetplay_MRMediaRemoteGetNowPlayingApplicationIsPlaying(dispatch_get_main_queue(), ^(Boolean isPlaying) {
        completion(isPlaying ? YES : NO);
    });
}

static BOOL axs_headsetplay_applicationInstalled(NSString *bundleID) {
    if (bundleID.length == 0) {
        return NO;
    }
    Class workspaceClass = objc_getClass("LSApplicationWorkspace");
    if (!workspaceClass) {
        return YES;
    }
    LSApplicationWorkspace *workspace = ((id (*)(id, SEL))objc_msgSend)(workspaceClass, @selector(defaultWorkspace));
    if (![workspace respondsToSelector:@selector(applicationIsInstalled:)]) {
        return YES;
    }
    return [workspace applicationIsInstalled:bundleID];
}

static BOOL axs_headsetplay_openApplicationSuspended(NSString *bundleID) {
    if (bundleID.length == 0) {
        return NO;
    }
    UIApplication *application = [UIApplication sharedApplication];
    if ([application respondsToSelector:@selector(launchApplicationWithIdentifier:suspended:)]) {
        if ([application launchApplicationWithIdentifier:bundleID suspended:YES]) {
            return YES;
        }
    }
    Class serviceClass = objc_getClass("FBSSystemService");
    FBSSystemService *service = serviceClass
        ? ((id (*)(id, SEL))objc_msgSend)(serviceClass, @selector(sharedService))
        : nil;
    if (!service) {
        return NO;
    }
    NSDictionary *options = @{
        @"__ActivateSuspended": @YES,
        @"LSLaunchSuspendedAlways": @YES,
        @"UnlockDevice": @YES
    };
    if ([service respondsToSelector:@selector(openApplication:options:withResult:)]) {
        ((void (*)(id, SEL, NSString *, NSDictionary *, id))objc_msgSend)(
            service, @selector(openApplication:options:withResult:), bundleID, options, nil);
        return YES;
    }
    if ([service respondsToSelector:@selector(openApplication:options:clientPort:withResult:)]) {
        unsigned int port = 0;
        if ([service respondsToSelector:@selector(createClientPort)]) {
            port = ((unsigned int (*)(id, SEL))objc_msgSend)(service, @selector(createClientPort));
        }
        ((void (*)(id, SEL, NSString *, NSDictionary *, unsigned int, id))objc_msgSend)(
            service, @selector(openApplication:options:clientPort:withResult:),
            bundleID, options, port, nil);
        return YES;
    }
    return NO;
}

static NSString *axs_headsetplay_resolvedBundleID(NSString *preferred) {
    if (axs_headsetplay_applicationInstalled(preferred)) {
        return preferred;
    }
    for (NSString *alternate in axs_headsetplay_catalogAlternateBundleIDs(preferred)) {
        if (axs_headsetplay_applicationInstalled(alternate)) {
            return alternate;
        }
    }
    return nil;
}

static unsigned int axs_headsetplay_majorClass(id device) {
    if (![device respondsToSelector:@selector(majorClass)]) {
        return 0;
    }
    unsigned int value = ((unsigned int (*)(id, SEL))objc_msgSend)(device, @selector(majorClass));
    if (value > 0x1F) {
        value = (value >> 8) & 0x1F;
    }
    return value;
}

static unsigned int axs_headsetplay_minorClass(id device) {
    if (![device respondsToSelector:@selector(minorClass)]) {
        return 0;
    }
    unsigned int value = ((unsigned int (*)(id, SEL))objc_msgSend)(device, @selector(minorClass));
    if (value > 0x3F) {
        value = (value >> 2) & 0x3F;
    }
    return value;
}

static BOOL axs_headsetplay_nameLooksLikeAudio(NSString *name) {
    if (name.length == 0) {
        return NO;
    }
    NSString *lowered = name.lowercaseString;
    NSArray<NSString *> *keywords = @[
        @"airpods", @"headphone", @"headset", @"earbud", @"earphone", @"earbuds",
        @"buds", @"freebuds", @"wh-", @"wf-", @"beats", @"sony", @"bose",
        @"soundcore", @"galaxy buds", @"pixel buds", @"耳机", @"耳麦"
    ];
    for (NSString *keyword in keywords) {
        if ([lowered containsString:keyword]) {
            return YES;
        }
    }
    return NO;
}

BOOL axs_headsetplay_isAudioDevice(id device) {
    if (!device) {
        return NO;
    }
    if ([device respondsToSelector:@selector(isAppleAudioDevice)] &&
        ((BOOL (*)(id, SEL))objc_msgSend)(device, @selector(isAppleAudioDevice))) {
        return YES;
    }
    if ([device respondsToSelector:@selector(supportsA2DP)] &&
        ((BOOL (*)(id, SEL))objc_msgSend)(device, @selector(supportsA2DP))) {
        return YES;
    }
    if ([device respondsToSelector:@selector(isHeadsetDevice)] &&
        ((BOOL (*)(id, SEL))objc_msgSend)(device, @selector(isHeadsetDevice))) {
        return YES;
    }
    unsigned int major = axs_headsetplay_majorClass(device);
    unsigned int minor = axs_headsetplay_minorClass(device);
    if (major == 4) {
        switch (minor) {
            case 1:
            case 2:
            case 4:
            case 5:
            case 6:
            case 7:
            case 8:
            case 10:
                return YES;
            default:
                break;
        }
    }
    NSString *name = [device respondsToSelector:@selector(name)] ? [device name] : nil;
    return axs_headsetplay_nameLooksLikeAudio(name);
}

static NSSet<NSString *> *axs_headsetplay_connectedAddresses(void) {
    Class managerClass = objc_getClass("BluetoothManager");
    BluetoothManager *manager = managerClass
        ? ((id (*)(id, SEL))objc_msgSend)(managerClass, @selector(sharedInstance))
        : nil;
    if (![manager respondsToSelector:@selector(connectedDevices)]) {
        return [NSSet set];
    }
    NSMutableSet<NSString *> *addresses = [NSMutableSet set];
    for (id device in [manager connectedDevices]) {
        NSString *address = nil;
        if ([device respondsToSelector:@selector(address)]) {
            address = ((NSString *(*)(id, SEL))objc_msgSend)(device, @selector(address));
        }
        if (address.length > 0) {
            [addresses addObject:address];
        }
    }
    return addresses;
}

static BOOL axs_headsetplay_routeHasBluetoothOutput(AVAudioSessionRouteDescription *route) {
    for (AVAudioSessionPortDescription *port in route.outputs) {
        NSString *type = port.portType;
        if ([type isEqualToString:AVAudioSessionPortBluetoothA2DP] ||
            [type isEqualToString:AVAudioSessionPortBluetoothHFP] ||
            [type isEqualToString:AVAudioSessionPortBluetoothLE]) {
            return YES;
        }
    }
    return NO;
}

static void axs_headsetplay_sendPlay(void) {
    if (axs_headsetplay_MRMediaRemoteSendCommand) {
        NSDictionary *info = @{@"kMRMediaRemoteOptionDisableImplicitAppLaunch": @YES};
        axs_headsetplay_MRMediaRemoteSendCommand(kAxsHeadsetPlayMRPlay, info);
        axs_headsetplay_MRMediaRemoteSendCommand(kAxsHeadsetPlayMRPlay, nil);
    }
    Class mediaClass = objc_getClass("SBMediaController");
    SBMediaController *media = mediaClass
        ? ((id (*)(id, SEL))objc_msgSend)(mediaClass, @selector(sharedInstance))
        : nil;
    if ([media respondsToSelector:@selector(play)]) {
        ((BOOL (*)(id, SEL))objc_msgSend)(media, @selector(play));
    }
}

static BOOL axs_headsetplay_generationIsCurrent(NSUInteger generation) {
    os_unfair_lock_lock(&gAxsHeadsetPlayLock);
    BOOL current = (generation == gAxsHeadsetPlayGeneration);
    os_unfair_lock_unlock(&gAxsHeadsetPlayLock);
    return current;
}

static void axs_headsetplay_schedulePlayRetries(NSUInteger generation) {
    AxsHeadsetPlayConfig *config = [AxsHeadsetPlayConfig axs_headsetplay_shared];
    for (NSUInteger index = 0; index < kAxsHeadsetPlayRetryCount; index++) {
        int64_t delay = (int64_t)(kAxsHeadsetPlayRetryDelays[index] * NSEC_PER_SEC);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delay), dispatch_get_main_queue(), ^{
            if (!axs_headsetplay_generationIsCurrent(generation)) {
                return;
            }
            if (![config axs_headsetplay_isEnabled] || ![config axs_headsetplay_autoPlay]) {
                return;
            }
            void (^sendIfNeeded)(BOOL) = ^(BOOL playing) {
                if (!axs_headsetplay_generationIsCurrent(generation)) {
                    return;
                }
                if ([config axs_headsetplay_skipIfPlaying] && playing) {
                    return;
                }
                axs_headsetplay_sendPlay();
            };
            if ([config axs_headsetplay_skipIfPlaying]) {
                axs_headsetplay_queryPlaying(sendIfNeeded);
            } else {
                sendIfNeeded(NO);
            }
        });
    }
}

static void axs_headsetplay_launchThenPlay(NSString *bundleID, NSUInteger generation) {
    (void)axs_headsetplay_openApplicationSuspended(bundleID);
    AxsHeadsetPlayConfig *config = [AxsHeadsetPlayConfig axs_headsetplay_shared];
    if (![config axs_headsetplay_autoPlay]) {
        return;
    }
    axs_headsetplay_schedulePlayRetries(generation);
}

static void axs_headsetplay_runLaunchAndPlay(NSUInteger routeWaitCount) {
    AxsHeadsetPlayConfig *config = [AxsHeadsetPlayConfig axs_headsetplay_shared];
    if (![config axs_headsetplay_isEnabled]) {
        return;
    }
    NSString *bundleID = axs_headsetplay_resolvedBundleID([config axs_headsetplay_musicAppBundleID]);
    if (bundleID.length == 0) {
        return;
    }
    os_unfair_lock_lock(&gAxsHeadsetPlayLock);
    NSUInteger generation = gAxsHeadsetPlayGeneration;
    os_unfair_lock_unlock(&gAxsHeadsetPlayLock);
    BOOL hasBluetooth = axs_headsetplay_routeHasBluetoothOutput([AVAudioSession sharedInstance].currentRoute);
    if (!hasBluetooth && routeWaitCount < 2) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, kAxsHeadsetPlayRouteWaitNs), dispatch_get_main_queue(), ^{
            if (!axs_headsetplay_generationIsCurrent(generation)) {
                return;
            }
            axs_headsetplay_runLaunchAndPlay(routeWaitCount + 1);
        });
        return;
    }
    void (^proceed)(BOOL) = ^(BOOL playing) {
        if (!axs_headsetplay_generationIsCurrent(generation)) {
            return;
        }
        if ([config axs_headsetplay_skipIfPlaying] && playing) {
            return;
        }
        axs_headsetplay_launchThenPlay(bundleID, generation);
    };
    if ([config axs_headsetplay_skipIfPlaying]) {
        axs_headsetplay_queryPlaying(proceed);
    } else {
        proceed(NO);
    }
}

static void axs_headsetplay_scheduleAfterAudioConnect(void) {
    AxsHeadsetPlayConfig *config = [AxsHeadsetPlayConfig axs_headsetplay_shared];
    if (![config axs_headsetplay_isEnabled]) {
        return;
    }
    os_unfair_lock_lock(&gAxsHeadsetPlayLock);
    BOOL ready = gAxsHeadsetPlayHasBaseline;
    os_unfair_lock_unlock(&gAxsHeadsetPlayLock);
    if (!ready) {
        return;
    }
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    os_unfair_lock_lock(&gAxsHeadsetPlayLock);
    if (now - gAxsHeadsetPlayLastFire < kAxsHeadsetPlayCooldown) {
        os_unfair_lock_unlock(&gAxsHeadsetPlayLock);
        return;
    }
    if (gAxsHeadsetPlayPending) {
        dispatch_block_cancel(gAxsHeadsetPlayPending);
        gAxsHeadsetPlayPending = nil;
    }
    gAxsHeadsetPlayGeneration += 1;
    dispatch_block_t work = dispatch_block_create(0, ^{
        os_unfair_lock_lock(&gAxsHeadsetPlayLock);
        gAxsHeadsetPlayPending = nil;
        gAxsHeadsetPlayLastFire = [NSDate date].timeIntervalSince1970;
        os_unfair_lock_unlock(&gAxsHeadsetPlayLock);
        axs_headsetplay_runLaunchAndPlay(0);
    });
    gAxsHeadsetPlayPending = work;
    os_unfair_lock_unlock(&gAxsHeadsetPlayLock);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, kAxsHeadsetPlayConnectDelayNs), dispatch_get_main_queue(), work);
}

void axs_headsetplay_handleConnectedStatusChanged(void) {
    NSSet<NSString *> *current = axs_headsetplay_connectedAddresses();
    os_unfair_lock_lock(&gAxsHeadsetPlayLock);
    NSSet<NSString *> *previous = gAxsHeadsetPlayKnownAddresses ?: [NSSet set];
    BOOL hasBaseline = gAxsHeadsetPlayHasBaseline;
    if (hasBaseline) {
        gAxsHeadsetPlayKnownAddresses = current;
    }
    os_unfair_lock_unlock(&gAxsHeadsetPlayLock);
    if (!hasBaseline) {
        return;
    }
    Class managerClass = objc_getClass("BluetoothManager");
    BluetoothManager *manager = managerClass
        ? ((id (*)(id, SEL))objc_msgSend)(managerClass, @selector(sharedInstance))
        : nil;
    if (![manager respondsToSelector:@selector(connectedDevices)]) {
        return;
    }
    BOOL foundAudio = NO;
    for (id device in [manager connectedDevices]) {
        NSString *address = nil;
        if ([device respondsToSelector:@selector(address)]) {
            address = ((NSString *(*)(id, SEL))objc_msgSend)(device, @selector(address));
        }
        if (address.length == 0 || [previous containsObject:address]) {
            continue;
        }
        if (axs_headsetplay_isAudioDevice(device)) {
            foundAudio = YES;
            break;
        }
    }
    if (foundAudio) {
        axs_headsetplay_scheduleAfterAudioConnect();
    }
}

void axs_headsetplay_handleConnectNotification(NSNotification *notification) {
    id device = notification.object;
    if (!axs_headsetplay_isAudioDevice(device)) {
        axs_headsetplay_handleConnectedStatusChanged();
        return;
    }
    axs_headsetplay_scheduleAfterAudioConnect();
}

void axs_headsetplay_handleRouteChange(NSNotification *notification) {
    NSNumber *reason = notification.userInfo[AVAudioSessionRouteChangeReasonKey];
    if (reason.unsignedIntegerValue != AVAudioSessionRouteChangeReasonNewDeviceAvailable) {
        return;
    }
    AVAudioSessionRouteDescription *previous =
        notification.userInfo[AVAudioSessionRouteChangePreviousRouteKey];
    BOOL hadBluetooth = axs_headsetplay_routeHasBluetoothOutput(previous);
    BOOL hasBluetooth = axs_headsetplay_routeHasBluetoothOutput([AVAudioSession sharedInstance].currentRoute);
    if (hasBluetooth && !hadBluetooth) {
        axs_headsetplay_scheduleAfterAudioConnect();
    }
}

void axs_headsetplay_start(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        axs_headsetplay_loadMediaRemote();
        [AxsHeadsetPlayConfig axs_headsetplay_shared];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            NSSet<NSString *> *current = axs_headsetplay_connectedAddresses();
            os_unfair_lock_lock(&gAxsHeadsetPlayLock);
            gAxsHeadsetPlayKnownAddresses = current;
            gAxsHeadsetPlayHasBaseline = YES;
            os_unfair_lock_unlock(&gAxsHeadsetPlayLock);
        });
        NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
        NSOperationQueue *queue = [NSOperationQueue mainQueue];
        static id axs_headsetplay_connectObserver;
        static id axs_headsetplay_routeObserver;
        axs_headsetplay_connectObserver = [center addObserverForName:@"BluetoothDeviceConnectSuccessNotification"
                                                              object:nil
                                                               queue:queue
                                                          usingBlock:^(NSNotification *notification) {
            axs_headsetplay_handleConnectNotification(notification);
        }];
        axs_headsetplay_routeObserver = [center addObserverForName:AVAudioSessionRouteChangeNotification
                                                            object:nil
                                                             queue:queue
                                                        usingBlock:^(NSNotification *notification) {
            axs_headsetplay_handleRouteChange(notification);
        }];
        (void)axs_headsetplay_connectObserver;
        (void)axs_headsetplay_routeObserver;
    });
}
