#import "AxsHeadsetPlayPopup.h"

#import <objc/message.h>
#import <objc/runtime.h>

static const int64_t kAxsHeadsetPlayCardDismissDelayNs = (int64_t)(5.0 * NSEC_PER_SEC);
static const void *kAxsHeadsetPlayCardScheduledKey = &kAxsHeadsetPlayCardScheduledKey;

static BOOL axs_headsetplay_labelLooksLikeBatteryPercent(UILabel *label) {
    NSString *text = label.text;
    if (text.length == 0) {
        return NO;
    }
    return [text containsString:@"%"];
}

BOOL axs_headsetplay_viewLooksLikeBatteryCard(UIView *view) {
    if (!view) {
        return NO;
    }
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:view];
    while (stack.count > 0) {
        UIView *current = stack.lastObject;
        [stack removeLastObject];
        if ([current isKindOfClass:[UILabel class]] &&
            axs_headsetplay_labelLooksLikeBatteryPercent((UILabel *)current)) {
            return YES;
        }
        [stack addObjectsFromArray:current.subviews];
    }
    return NO;
}

static UIViewController *axs_headsetplay_topPresentedController(UIViewController *controller) {
    UIViewController *current = controller;
    while (current.parentViewController) {
        current = current.parentViewController;
    }
    if (current.presentingViewController) {
        return current.presentingViewController;
    }
    return current;
}

void axs_headsetplay_dismissController(UIViewController *controller) {
    if (!controller) {
        return;
    }
    if ([controller respondsToSelector:@selector(dismissCardAnimated:)]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(controller, @selector(dismissCardAnimated:), YES);
        return;
    }
    if ([controller respondsToSelector:@selector(_dismissCardAnimated:)]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(controller, @selector(_dismissCardAnimated:), YES);
        return;
    }
    id handle = nil;
    if ([controller respondsToSelector:@selector(remoteAlertHandle)]) {
        handle = ((id (*)(id, SEL))objc_msgSend)(controller, @selector(remoteAlertHandle));
    }
    if ([handle respondsToSelector:@selector(invalidate)]) {
        ((void (*)(id, SEL))objc_msgSend)(handle, @selector(invalidate));
        return;
    }
    if ([controller respondsToSelector:@selector(dismissSelfWithCompletion:)]) {
        ((void (*)(id, SEL, id))objc_msgSend)(controller, @selector(dismissSelfWithCompletion:), nil);
        return;
    }
    UIViewController *host = axs_headsetplay_topPresentedController(controller);
    if (host != controller && [host respondsToSelector:@selector(dismissViewControllerAnimated:completion:)]) {
        [host dismissViewControllerAnimated:YES completion:nil];
        return;
    }
    if ([controller respondsToSelector:@selector(dismissViewControllerAnimated:completion:)]) {
        [controller dismissViewControllerAnimated:YES completion:nil];
    }
}

static void axs_headsetplay_collectControllers(UIViewController *root, NSMutableArray<UIViewController *> *out) {
    if (!root) {
        return;
    }
    [out addObject:root];
    for (UIViewController *child in root.childViewControllers) {
        axs_headsetplay_collectControllers(child, out);
    }
    if (root.presentedViewController) {
        axs_headsetplay_collectControllers(root.presentedViewController, out);
    }
}

static void axs_headsetplay_dismissWindowsLookingLikeBatteryCard(void) {
    NSArray<UIWindow *> *windows = [UIApplication sharedApplication].windows;
    for (UIWindow *window in windows) {
        NSMutableArray<UIViewController *> *controllers = [NSMutableArray array];
        axs_headsetplay_collectControllers(window.rootViewController, controllers);
        for (UIViewController *controller in controllers) {
            if (!axs_headsetplay_viewLooksLikeBatteryCard(controller.view)) {
                continue;
            }
            axs_headsetplay_dismissController(controller);
        }
    }
}

static void axs_headsetplay_deactivateSharingRemoteSessions(void) {
    Class managerClass = objc_getClass("SBRemoteTransientOverlaySessionManager");
    id manager = managerClass
        ? ((id (*)(id, SEL))objc_msgSend)(managerClass, @selector(sharedInstance))
        : nil;
    if (![manager respondsToSelector:@selector(activeSessions)]) {
        return;
    }
    NSArray *sessions = ((id (*)(id, SEL))objc_msgSend)(manager, @selector(activeSessions));
    if (![sessions isKindOfClass:[NSArray class]]) {
        return;
    }
    for (id session in sessions) {
        NSString *bundleID = nil;
        if ([session respondsToSelector:@selector(serviceBundleIdentifier)]) {
            bundleID = ((id (*)(id, SEL))objc_msgSend)(session, @selector(serviceBundleIdentifier));
        } else if ([session respondsToSelector:@selector(definition)]) {
            id definition = ((id (*)(id, SEL))objc_msgSend)(session, @selector(definition));
            if ([definition respondsToSelector:@selector(serviceBundleIdentifier)]) {
                bundleID = ((id (*)(id, SEL))objc_msgSend)(definition, @selector(serviceBundleIdentifier));
            }
        }
        if (![bundleID isEqualToString:@"com.apple.SharingViewService"]) {
            continue;
        }
        id presented = nil;
        if ([session respondsToSelector:@selector(viewController)]) {
            presented = ((id (*)(id, SEL))objc_msgSend)(session, @selector(viewController));
        }
        BOOL looksLikeBattery = [presented isKindOfClass:[UIViewController class]] &&
            axs_headsetplay_viewLooksLikeBatteryCard(((UIViewController *)presented).view);
        if (!looksLikeBattery) {
            continue;
        }
        if ([session respondsToSelector:@selector(deactivateWithError:)]) {
            ((void (*)(id, SEL, id))objc_msgSend)(session, @selector(deactivateWithError:), nil);
        } else if ([session respondsToSelector:@selector(deactivate)]) {
            ((void (*)(id, SEL))objc_msgSend)(session, @selector(deactivate));
        }
    }
}

void axs_headsetplay_dismissSystemHeadsetCard(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        axs_headsetplay_deactivateSharingRemoteSessions();
        axs_headsetplay_dismissWindowsLookingLikeBatteryCard();
    });
}

void axs_headsetplay_scheduleSystemHeadsetCardDismiss(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, kAxsHeadsetPlayCardDismissDelayNs), dispatch_get_main_queue(), ^{
        axs_headsetplay_dismissSystemHeadsetCard();
    });
}

void axs_headsetplay_markControllerScheduled(UIViewController *controller) {
    if (!controller) {
        return;
    }
    objc_setAssociatedObject(controller, kAxsHeadsetPlayCardScheduledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

BOOL axs_headsetplay_controllerWasScheduled(UIViewController *controller) {
    return [objc_getAssociatedObject(controller, kAxsHeadsetPlayCardScheduledKey) boolValue];
}
