#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import "AxsHeadsetPlayController.h"

%group AxsHeadsetPlaySpringBoardBluetooth
%hook BluetoothManager

- (void)_connectedStatusChanged {
    %orig;
    axs_headsetplay_handleConnectedStatusChanged();
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
    }
}
