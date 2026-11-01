#pragma once

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

void axs_headsetplay_start(void);
void axs_headsetplay_handleConnectedStatusChanged(void);
void axs_headsetplay_handleConnectNotification(NSNotification *notification);
void axs_headsetplay_handleRouteChange(NSNotification *notification);
BOOL axs_headsetplay_isAudioDevice(id device);

#ifdef __cplusplus
}
#endif
