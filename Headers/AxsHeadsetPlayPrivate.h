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

@interface FBSSystemService : NSObject
+ (instancetype)sharedService;
- (unsigned int)createClientPort;
- (void)openApplication:(NSString *)identifier options:(NSDictionary *)options withResult:(id)result;
- (void)openApplication:(NSString *)identifier options:(NSDictionary *)options clientPort:(unsigned int)port withResult:(id)result;
@end

@interface SBMediaController : NSObject
+ (instancetype)sharedInstance;
- (BOOL)play;
- (BOOL)isPlaying;
@end
