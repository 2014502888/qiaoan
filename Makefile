export THEOS_DEVICE_IP ?= 127.0.0.1

include $(THEOS)/makefiles/common.mk

# 纯 runtime swizzle，不依赖 CydiaSubstrate —— TrollStore 注入可直用
LIBRARY_NAME = JoolinkSDReplay

JoolinkSDReplay_FILES = Tweak.m
JoolinkSDReplay_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
JoolinkSDReplay_INSTALL_PATH = /usr/lib
JoolinkSDReplay_LDFLAGS = -install_name @rpath/JoolinkSDReplay.dylib

include $(THEOS_MAKE_PATH)/library.mk

# 备选：不装 Theos 时直接 clang 编译（与编译机现有方式一致）
# xcrun -sdk iphoneos clang -arch arm64 -dynamiclib -fobjc-arc \
#   -miphoneos-version-min=13.0 \
#   -framework UIKit -framework Foundation \
#   Tweak.m -o JoolinkSDReplay.dylib
