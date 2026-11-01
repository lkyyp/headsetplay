#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import "AxsHeadsetPlayController.h"

%hook BluetoothManager

- (void)_connectedStatusChanged {
    %orig;
    axs_headsetplay_handleConnectedStatusChanged();
}

%end

%ctor {
    @autoreleasepool {
        dlopen("/System/Library/PrivateFrameworks/BluetoothManager.framework/BluetoothManager", RTLD_LAZY);
        axs_headsetplay_start();
        %init;
    }
}
