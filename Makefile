export THEOS_PACKAGE_SCHEME = rootless
ARCHS = arm64 arm64e
TARGET := iphone:clang:latest:15.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = NKDeviceIDChangerIOS
NKDeviceIDChangerIOS_FILES = Tweak.xm
NKDeviceIDChangerIOS_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
NKDeviceIDChangerIOS_FRAMEWORKS = Foundation UIKit

include $(THEOS_MAKE_PATH)/tweak.mk

# Only relevant when installing live over SSH from a dev machine (make install);
# GitHub Actions packaging (make package) never reaches this target.
internal-install-plist::
	install.exec "killall -9 SpringBoard"
