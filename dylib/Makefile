THEOS ?= $(CURDIR)/../theos
TARGET := iphone:clang:latest:15.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ZolaAntiRecall
ZolaAntiRecall_FILES = Tweak.xm Core/ZARLogger.m Diagnostics/ZARMessageTrace.m
ZolaAntiRecall_CFLAGS = -fobjc-arc
ZolaAntiRecall_FRAMEWORKS = Foundation UIKit
ZolaAntiRecall_LDFLAGS = -install_name @rpath/ZolaAntiRecall.dylib

include $(THEOS_MAKE_PATH)/tweak.mk
