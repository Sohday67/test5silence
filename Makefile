ARCHS = arm64
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
# NOTE: YouTubeHeader is a headers-only clone at $THEOS/include/YouTubeHeader.
# Do NOT list it in _PRIVATE_FRAMEWORKS — that would make Theos emit
# `-framework YouTubeHeader` at link time, which fails with
# "framework not found YouTubeHeader". Just importing the headers via
# #import <YouTubeHeader/...> is enough.
$(TWEAK_NAME)_FRAMEWORKS = UIKit AVFoundation MediaToolbox AudioToolbox

include $(THEOS_MAKE_PATH)/tweak.mk
