DEBUG = 0
FINALPACKAGE = 1

ARCHS = arm64 arm64e

# Share the SDK and deployment targets with the PreferenceBundle.
include AxsHeadsetPlayBuild.mk
include $(THEOS)/makefiles/common.mk

TWEAK_NAME = AxsHeadsetPlay
AxsHeadsetPlay_FILES = Hooks/AxsHeadsetPlayMain.xm Sources/AxsHeadsetPlayController.m Sources/AxsHeadsetPlayConfig.m
AxsHeadsetPlay_CFLAGS = -fobjc-arc -I./Headers -I./Sources
AxsHeadsetPlay_FRAMEWORKS = UIKit Foundation CoreFoundation AVFoundation
AxsHeadsetPlay_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += AxsHeadsetPlayPrefs
include $(THEOS_MAKE_PATH)/aggregate.mk
