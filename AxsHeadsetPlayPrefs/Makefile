include ../AxsHeadsetPlayBuild.mk
include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = AxsHeadsetPlayPrefs
AxsHeadsetPlayPrefs_FILES = $(wildcard *.m)
AxsHeadsetPlayPrefs_CFLAGS = -fobjc-arc -I../Sources
AxsHeadsetPlayPrefs_FRAMEWORKS = UIKit Foundation CoreFoundation
AxsHeadsetPlayPrefs_PRIVATE_FRAMEWORKS = Preferences
AxsHeadsetPlayPrefs_INSTALL_PATH = /Library/PreferenceBundles

include $(THEOS_MAKE_PATH)/bundle.mk
