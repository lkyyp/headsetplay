#pragma once

#import <UIKit/UIKit.h>

#ifdef __cplusplus
extern "C" {
#endif

BOOL axs_headsetplay_viewLooksLikeBatteryCard(UIView *view);
void axs_headsetplay_dismissController(UIViewController *controller);
void axs_headsetplay_dismissSystemHeadsetCard(void);
void axs_headsetplay_scheduleSystemHeadsetCardDismiss(void);
void axs_headsetplay_markControllerScheduled(UIViewController *controller);
BOOL axs_headsetplay_controllerWasScheduled(UIViewController *controller);

#ifdef __cplusplus
}
#endif
