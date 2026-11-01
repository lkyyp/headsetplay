#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "AxsHeadsetPlayPopup.h"

static void axs_headsetplay_scheduleControllerDismiss(id candidate) {
    if (![candidate isKindOfClass:[UIViewController class]]) return;
    UIViewController *controller = (UIViewController *)candidate;
    if (axs_headsetplay_controllerWasScheduled(controller)) {
        return;
    }
    axs_headsetplay_markControllerScheduled(controller);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!axs_headsetplay_viewLooksLikeBatteryCard(controller.view)) {
            return;
        }
        axs_headsetplay_dismissController(controller);
    });
}

%group AxsHeadsetPlaySharingPairing
%hook ProximityPairingViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    axs_headsetplay_scheduleControllerDismiss(self);
}
%end
%end

%group AxsHeadsetPlaySharingPRX
%hook PRXCardContainerViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    axs_headsetplay_scheduleControllerDismiss(self);
}
%end
%end

%group AxsHeadsetPlaySharingSVS
%hook SVSCardContainerViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    axs_headsetplay_scheduleControllerDismiss(self);
}
%end
%end

%group AxsHeadsetPlaySharingRemoteAlert
%hook SBUIRemoteAlertServiceViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    axs_headsetplay_scheduleControllerDismiss(self);
}
%end
%end

%group AxsHeadsetPlaySharingAnyCard
%hook UIViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    axs_headsetplay_scheduleControllerDismiss(self);
}
%end
%end

%ctor {
    @autoreleasepool {
        NSString *bundleID = [NSBundle mainBundle].bundleIdentifier;
        if (![bundleID isEqualToString:@"com.apple.SharingViewService"]) {
            return;
        }
        if (objc_getClass("ProximityPairingViewController")) {
            %init(AxsHeadsetPlaySharingPairing);
        }
        if (objc_getClass("PRXCardContainerViewController")) {
            %init(AxsHeadsetPlaySharingPRX);
        }
        if (objc_getClass("SVSCardContainerViewController")) {
            %init(AxsHeadsetPlaySharingSVS);
        }
        if (objc_getClass("SBUIRemoteAlertServiceViewController")) {
            %init(AxsHeadsetPlaySharingRemoteAlert);
        }
        %init(AxsHeadsetPlaySharingAnyCard);
    }
}
