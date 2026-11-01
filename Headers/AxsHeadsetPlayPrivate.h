#pragma once

#import <UIKit/UIKit.h>

@interface BluetoothDevice : NSObject
- (NSString *)name;
- (NSString *)address;
- (BOOL)connected;
- (unsigned int)majorClass;
- (unsigned int)minorClass;
- (BOOL)supportsA2DP;
- (BOOL)isHeadsetDevice;
- (BOOL)isAppleAudioDevice;
@end

@interface BluetoothManager : NSObject
+ (instancetype)sharedInstance;
- (NSArray *)connectedDevices;
- (void)_connectedStatusChanged;
@end

@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (BOOL)applicationIsInstalled:(NSString *)bundleID;
- (BOOL)openApplicationWithBundleID:(NSString *)bundleID;
@end

@interface UIApplication (AxsHeadsetPlayLaunch)
- (BOOL)launchApplicationWithIdentifier:(NSString *)identifier suspended:(BOOL)suspended;
@end
