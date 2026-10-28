TARGET := iphone:clang:latest:14.0
ARCHS := arm64
INSTALL_TARGET_PROCESSES = MobiArmy3HA

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = MobiArmyMod
MobiArmyMod_FILES = MobiArmyMod.mm
MobiArmyMod_FRAMEWORKS = Foundation UIKit CoreGraphics QuartzCore
MobiArmyMod_CFLAGS = -fobjc-arc -Wno-deprecated-declarations

include $(THEOS_MAKE_PATH)/tweak.mk
