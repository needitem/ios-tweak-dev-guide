TARGET := iphone:clang:16.5:14.0
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = HelloLine
HelloLine_FILES = Tweak.x
HelloLine_FRAMEWORKS = UIKit Foundation
HelloLine_CFLAGS = -fobjc-arc -Wno-deprecated-declarations

include $(THEOS_MAKE_PATH)/tweak.mk
