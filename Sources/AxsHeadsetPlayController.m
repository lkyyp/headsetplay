#import "AxsHeadsetPlayController.h"
#import "AxsHeadsetPlayCatalog.h"
#import "AxsHeadsetPlayConfig.h"
#import "AxsHeadsetPlayPrivate.h"

#import <AVFoundation/AVFoundation.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <os/lock.h>

static const NSTimeInterval kAxsHeadsetPlayCooldown = 4.0;
static const int64_t kAxsHeadsetPlayConnectDelayNs = (int64_t)(5.8 * NSEC_PER_SEC);
static const int64_t kAxsHeadsetPlayRouteWaitNs = (int64_t)(1.0 * NSEC_PER_SEC);
static const NSTimeInterval kAxsHeadsetPlayRetryDelays[] = {1.6, 3.2};
enum { kAxsHeadsetPlayRetryCount = 2 };
enum { kAxsHeadsetPlayMRPlay = 0 };

static os_unfair_lock gAxsHeadsetPlayLock = OS_UNFAIR_LOCK_INIT;
static NSTimeInterval gAxsHeadsetPlayLastFire = 0;
static dispatch_block_t gAxsHeadsetPlayPending = nil;
static NSSet<NSString *> *gAxsHeadsetPlayKnownAddresses = nil;
static BOOL gAxsHeadsetPlayHasBaseline = NO;
static NSUInteger gAxsHeadsetPlayGeneration = 0;
static BOOL gAxsHeadsetPlayDidPlay = NO;

static void (*axs_headsetplay_MRMediaRemoteSendCommand)(int command, id userInfo);
static void (*axs_headsetplay_MRMediaRemoteGetNowPlayingApplicationIsPlaying)(dispatch_queue_t queue, void (^block)(Boolean isPlaying));

static void axs_headsetplay_abortSession(void);

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

static BOOL axs_headsetplay_applicationIsRunning(NSString *bundleID) {
    if (bundleID.length == 0) {
        return NO;
    }
    Class controllerClass = objc_getClass("SBApplicationController");
    id controller = controllerClass
        ? ((id (*)(id, SEL))objc_msgSend)(controllerClass, @selector(sharedInstance))
        : nil;
    if (![controller respondsToSelector:@selector(applicationWithBundleIdentifier:)]) {
        return NO;
    }
    id application = ((id (*)(id, SEL, NSString *))objc_msgSend)(
        controller, @selector(applicationWithBundleIdentifier:), bundleID);
    if (![application respondsToSelector:@selector(isRunning)]) {
        return NO;
    }
    return ((BOOL (*)(id, SEL))objc_msgSend)(application, @selector(isRunning));
}

static BOOL axs_headsetplay_openApplicationSuspended(NSString *bundleID) {
    if (bundleID.length == 0) {
        return NO;
    }
    if (axs_headsetplay_applicationIsRunning(bundleID)) {
        return YES;
    }
    UIApplication *application = [UIApplication sharedApplication];
    if ([application respondsToSelector:@selector(launchApplicationWithIdentifier:suspended:)]) {
        return [application launchApplicationWithIdentifier:bundleID suspended:YES];
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

static NSString *axs_headsetplay_deviceAddress(id device) {
    if (![device respondsToSelector:@selector(address)]) {
        return nil;
    }
    return ((NSString *(*)(id, SEL))objc_msgSend)(device, @selector(address));
}

static BOOL axs_headsetplay_deviceIsInEar(id device) {
    if ([device respondsToSelector:@selector(inEar)]) {
        return ((BOOL (*)(id, SEL))objc_msgSend)(device, @selector(inEar));
    }
    if ([device respondsToSelector:@selector(isInEar)]) {
        return ((BOOL (*)(id, SEL))objc_msgSend)(device, @selector(isInEar));
    }
    return YES;
}

static BOOL axs_headsetplay_deviceReportsEarState(id device) {
    return [device respondsToSelector:@selector(inEar)] || [device respondsToSelector:@selector(isInEar)];
}

static NSArray *axs_headsetplay_connectedDevices(void) {
    Class managerClass = objc_getClass("BluetoothManager");
    BluetoothManager *manager = managerClass
        ? ((id (*)(id, SEL))objc_msgSend)(managerClass, @selector(sharedInstance))
        : nil;
    if (![manager respondsToSelector:@selector(connectedDevices)]) {
        return @[];
    }
    NSArray *devices = [manager connectedDevices];
    return [devices isKindOfClass:[NSArray class]] ? devices : @[];
}

static NSSet<NSString *> *axs_headsetplay_connectedAddresses(void) {
    NSMutableSet<NSString *> *addresses = [NSMutableSet set];
    for (id device in axs_headsetplay_connectedDevices()) {
        NSString *address = axs_headsetplay_deviceAddress(device);
        if (address.length > 0) {
            [addresses addObject:address];
        }
    }
    return addresses;
}

static BOOL axs_headsetplay_hasConnectedAudioDevice(void) {
    for (id device in axs_headsetplay_connectedDevices()) {
        if (axs_headsetplay_isAudioDevice(device)) {
            return YES;
        }
    }
    return NO;
}

static BOOL axs_headsetplay_shouldSkipBecauseOutOfEar(void) {
    BOOL sawEarState = NO;
    BOOL anyInEar = NO;
    for (id device in axs_headsetplay_connectedDevices()) {
        if (!axs_headsetplay_isAudioDevice(device) || !axs_headsetplay_deviceReportsEarState(device)) {
            continue;
        }
        sawEarState = YES;
        if (axs_headsetplay_deviceIsInEar(device)) {
            anyInEar = YES;
        }
    }
    return sawEarState && !anyInEar;
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

static BOOL axs_headsetplay_generationIsCurrent(NSUInteger generation) {
    os_unfair_lock_lock(&gAxsHeadsetPlayLock);
    BOOL current = (generation == gAxsHeadsetPlayGeneration);
    os_unfair_lock_unlock(&gAxsHeadsetPlayLock);
    return current;
}

static void axs_headsetplay_abortSession(void) {
    os_unfair_lock_lock(&gAxsHeadsetPlayLock);
    if (gAxsHeadsetPlayPending) {
        dispatch_block_cancel(gAxsHeadsetPlayPending);
        gAxsHeadsetPlayPending = nil;
    }
    gAxsHeadsetPlayGeneration += 1;
    gAxsHeadsetPlayDidPlay = NO;
    gAxsHeadsetPlayLastFire = 0;
    os_unfair_lock_unlock(&gAxsHeadsetPlayLock);
}

static BOOL axs_headsetplay_sessionStillValid(NSUInteger generation) {
    if (!axs_headsetplay_generationIsCurrent(generation)) {
        return NO;
    }
    if (!axs_headsetplay_hasConnectedAudioDevice()) {
        axs_headsetplay_abortSession();
        return NO;
    }
    if (!axs_headsetplay_routeHasBluetoothOutput([AVAudioSession sharedInstance].currentRoute)) {
        axs_headsetplay_abortSession();
        return NO;
    }
    if (axs_headsetplay_shouldSkipBecauseOutOfEar()) {
        axs_headsetplay_abortSession();
        return NO;
    }
    return YES;
}

static void axs_headsetplay_sendPlay(void) {
    if (!axs_headsetplay_MRMediaRemoteSendCommand) {
        return;
    }
    NSDictionary *info = @{@"kMRMediaRemoteOptionDisableImplicitAppLaunch": @YES};
    axs_headsetplay_MRMediaRemoteSendCommand(kAxsHeadsetPlayMRPlay, info);
}

static void axs_headsetplay_watchPlayback(NSUInteger generation, NSUInteger remaining) {
    if (remaining == 0) {
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!axs_headsetplay_generationIsCurrent(generation)) {
            return;
        }
        axs_headsetplay_queryPlaying(^(BOOL playing) {
            if (!axs_headsetplay_generationIsCurrent(generation)) {
                return;
            }
            os_unfair_lock_lock(&gAxsHeadsetPlayLock);
            BOOL didPlay = gAxsHeadsetPlayDidPlay;
            if (playing) {
                gAxsHeadsetPlayDidPlay = YES;
                didPlay = YES;
            }
            os_unfair_lock_unlock(&gAxsHeadsetPlayLock);
            if (!playing && didPlay) {
                axs_headsetplay_abortSession();
                return;
            }
            if (!axs_headsetplay_sessionStillValid(generation)) {
                return;
            }
            axs_headsetplay_watchPlayback(generation, remaining - 1);
        });
    });
}

static void axs_headsetplay_schedulePlayRetries(NSUInteger generation) {
    AxsHeadsetPlayConfig *config = [AxsHeadsetPlayConfig axs_headsetplay_shared];
    for (NSUInteger index = 0; index < kAxsHeadsetPlayRetryCount; index++) {
        int64_t delay = (int64_t)(kAxsHeadsetPlayRetryDelays[index] * NSEC_PER_SEC);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delay), dispatch_get_main_queue(), ^{
            if (![config axs_headsetplay_isEnabled] || ![config axs_headsetplay_autoPlay]) {
                return;
            }
            if (!axs_headsetplay_sessionStillValid(generation)) {
                return;
            }
            axs_headsetplay_queryPlaying(^(BOOL playing) {
                if (!axs_headsetplay_generationIsCurrent(generation)) {
                    return;
                }
                os_unfair_lock_lock(&gAxsHeadsetPlayLock);
                BOOL didPlay = gAxsHeadsetPlayDidPlay;
                if (playing) {
                    gAxsHeadsetPlayDidPlay = YES;
                    didPlay = YES;
                }
                os_unfair_lock_unlock(&gAxsHeadsetPlayLock);
                if (playing || didPlay) {
                    return;
                }
                if (!axs_headsetplay_sessionStillValid(generation)) {
                    return;
                }
                axs_headsetplay_sendPlay();
                axs_headsetplay_watchPlayback(generation, 8);
            });
        });
    }
}

static void axs_headsetplay_launchThenPlay(NSString *bundleID, NSUInteger generation) {
    if (!axs_headsetplay_sessionStillValid(generation)) {
        return;
    }
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
    if (!axs_headsetplay_hasConnectedAudioDevice()) {
        axs_headsetplay_abortSession();
        return;
    }
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
    if (!hasBluetooth) {
        return;
    }
    if (axs_headsetplay_shouldSkipBecauseOutOfEar()) {
        return;
    }
    void (^proceed)(BOOL) = ^(BOOL playing) {
        if (!axs_headsetplay_generationIsCurrent(generation)) {
            return;
        }
        if (playing) {
            os_unfair_lock_lock(&gAxsHeadsetPlayLock);
            gAxsHeadsetPlayDidPlay = YES;
            os_unfair_lock_unlock(&gAxsHeadsetPlayLock);
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
    if (now - gAxsHeadsetPlayLastFire < kAxsHeadsetPlayCooldown && gAxsHeadsetPlayLastFire > 0) {
        os_unfair_lock_unlock(&gAxsHeadsetPlayLock);
        return;
    }
    if (gAxsHeadsetPlayPending) {
        dispatch_block_cancel(gAxsHeadsetPlayPending);
        gAxsHeadsetPlayPending = nil;
    }
    gAxsHeadsetPlayGeneration += 1;
    gAxsHeadsetPlayDidPlay = NO;
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
    if (!axs_headsetplay_hasConnectedAudioDevice()) {
        axs_headsetplay_abortSession();
        return;
    }
    BOOL foundAudio = NO;
    for (id device in axs_headsetplay_connectedDevices()) {
        NSString *address = axs_headsetplay_deviceAddress(device);
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
    axs_headsetplay_handleConnectedStatusChanged();
}

void axs_headsetplay_handleRouteChange(NSNotification *notification) {
    NSNumber *reason = notification.userInfo[AVAudioSessionRouteChangeReasonKey];
    NSUInteger value = reason.unsignedIntegerValue;
    BOOL hasBluetooth = axs_headsetplay_routeHasBluetoothOutput([AVAudioSession sharedInstance].currentRoute);
    if (value == AVAudioSessionRouteChangeReasonOldDeviceUnavailable && !hasBluetooth) {
        axs_headsetplay_abortSession();
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
        static id axs_headsetplay_disconnectObserver;
        static id axs_headsetplay_routeObserver;
        axs_headsetplay_connectObserver = [center addObserverForName:@"BluetoothDeviceConnectSuccessNotification"
                                                              object:nil
                                                               queue:queue
                                                          usingBlock:^(NSNotification *notification) {
            axs_headsetplay_handleConnectNotification(notification);
        }];
        axs_headsetplay_disconnectObserver = [center addObserverForName:@"BluetoothDeviceDisconnectSuccessNotification"
                                                                 object:nil
                                                                  queue:queue
                                                             usingBlock:^(NSNotification *notification) {
            (void)notification;
            axs_headsetplay_handleConnectedStatusChanged();
        }];
        axs_headsetplay_routeObserver = [center addObserverForName:AVAudioSessionRouteChangeNotification
                                                            object:nil
                                                             queue:queue
                                                        usingBlock:^(NSNotification *notification) {
            axs_headsetplay_handleRouteChange(notification);
        }];
        (void)axs_headsetplay_connectObserver;
        (void)axs_headsetplay_disconnectObserver;
        (void)axs_headsetplay_routeObserver;
    });
}
