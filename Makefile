ifeq ($(THEOS_PACKAGE_SCHEME),rootless)
TARGET = iphone:clang:latest:15.0
else ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
TARGET = iphone:clang:latest:15.0
else
TARGET = iphone:clang:latest:13.0
endif

ARCHS = arm64
INSTALL_TARGET_PROCESSES = YouTube

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = YTSkipSilence

YTSkipSilence_FILES = Tweak.xm \
                      Sources/YTSSSilenceController.m \
                      Sources/YTSSIconFactory.m \
                      Sources/YTSSHUD.m
YTSkipSilence_CFLAGS = -fobjc-arc -I. -ISources -IVendor -Wno-deprecated-declarations -Wno-unused-function -Wno-objc-method-access -Wno-unguarded-availability-new
YTSkipSilence_FRAMEWORKS = UIKit AVFoundation CoreMedia AudioToolbox QuartzCore

include $(THEOS_MAKE_PATH)/tweak.mk
