ARCHS = arm64 arm64e
ifeq ($(SIMULATOR),1)
	TARGET = simulator:clang:latest:15.0
else
	ifeq ($(THEOS_PACKAGE_SCHEME),rootless)
		TARGET = iphone:clang:latest:15.0
	else ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
		TARGET = iphone:clang:latest:15.0
	else
		TARGET = iphone:clang:latest:11.0
	endif
endif

INSTALL_TARGET_PROCESSES = YouTube

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = YTSkipSilence

$(TWEAK_NAME)_FILES = \
	Tweak.x \
	Source/SkipSilenceSettings.m \
	Source/SkipSilenceDetector.m \
	Source/SkipSilenceAudioTap.m \
	Source/SkipSilenceManager.m

$(TWEAK_NAME)_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-variable -Wno-unused-function
$(TWEAK_NAME)_FRAMEWORKS = UIKit AVFoundation CoreMedia MediaToolbox CoreAudio AudioToolbox
# NOTE: YouTubeHeader is a headers-only collection (provided on the include path
# by the parent project) — it is NOT a linkable framework. Listing it here made
# the linker fail with "framework 'YouTubeHeader' not found".

include $(THEOS_MAKE_PATH)/tweak.mk
