TARGET := iphone:clang:latest:14.0
ARCHS = arm64e
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = FuDai
FuDai_FILES = Tweak.xm
FuDai_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
FuDai_FRAMEWORKS = UIKit Foundation QuartzCore
FuDai_PRIVATE_FRAMEWORKS = UIKit
FuDai_LOGOS_DEFAULT_GENERATOR = internal

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 Aweme 2>/dev/null || true"
