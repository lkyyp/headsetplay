#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import "AxsHeadsetPlayController.h"
#import "AxsHeadsetPlayPopup.h"

@interface SBRemoteTransientOverlayViewController : UIViewController
@end

%group AxsHeadsetPlaySpringBoardBluetooth
%hook BluetoothManager

- (void)_connectedStatusChanged {
    %orig;
    axs_headsetplay_handleConnectedStatusChanged();
}

%end
%end

%group AxsHeadsetPlaySpringBoardOverlay
%hook SBRemoteTransientOverlayViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    NSString *bundleID = nil;
    if ([self respondsToSelector:@selector(serviceBundleIdentifier)]) {
        bundleID = ((id (*)(id, SEL))objc_msgSend)(self, @selector(serviceBundleIdentifier));
    }
    if (![bundleID isEqualToString:@"com.apple.SharingViewService"]) {
        return;
    }
    if (axs_headsetplay_controllerWasScheduled(self)) {
        return;
    }
    axs_headsetplay_markControllerScheduled(self);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!axs_headsetplay_viewLooksLikeBatteryCard(self.view)) {
            return;
        }
        axs_headsetplay_dismissController(self);
    });
}
%end
%end

%ctor {
    @autoreleasepool {
        NSString *bundleID = [NSBundle mainBundle].bundleIdentifier;
        if (![bundleID isEqualToString:@"com.apple.springboard"]) {
            return;
        }
        dlopen("/System/Library/PrivateFrameworks/BluetoothManager.framework/BluetoothManager", RTLD_LAZY);
        axs_headsetplay_start();
        %init(AxsHeadsetPlaySpringBoardBluetooth);
        if (objc_getClass("SBRemoteTransientOverlayViewController")) {
            %init(AxsHeadsetPlaySpringBoardOverlay);
        }
    }
}
