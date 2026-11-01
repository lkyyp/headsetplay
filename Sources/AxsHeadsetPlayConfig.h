#pragma once

#import <Foundation/Foundation.h>

@interface AxsHeadsetPlayConfig : NSObject
+ (instancetype)axs_headsetplay_shared;
- (BOOL)axs_headsetplay_isEnabled;
- (NSString *)axs_headsetplay_musicAppBundleID;
- (BOOL)axs_headsetplay_autoPlay;
- (BOOL)axs_headsetplay_skipIfPlaying;
- (id)axs_headsetplay_valueForKey:(NSString *)key defaultValue:(id)defaultValue;
- (void)axs_headsetplay_reload;
@end
