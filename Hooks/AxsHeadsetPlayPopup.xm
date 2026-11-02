#import <UIKit/UIKit.h>
#import <objc/runtime.h>

@interface ProximityPairingViewController : UIViewController
@end

%group AxsHeadsetPlayProximityCard
%hook ProximityPairingViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;

    __weak UIViewController *weakController = self;
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
            UIViewController *controller = weakController;
            if (!controller || !controller.viewIfLoaded.window) {
                return;
            }
            [controller dismissViewControllerAnimated:YES completion:nil];
        }
    );
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
            %init(AxsHeadsetPlayProximityCard);
        }
    }
}
