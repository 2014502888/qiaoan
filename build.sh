#!/bin/bash
# 直接 clang 编译 dylib（与编译机现有方式一致，无需 Theos）
# 用法：bash build.sh
set -e
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
xcrun --sdk iphoneos clang -arch arm64 -dynamiclib -fobjc-arc \
  -miphoneos-version-min=13.0 \
  -isysroot "$SDK" \
  -framework UIKit -framework Foundation \
  Tweak.m -o JoolinkSDReplay-v1.3.dylib
echo "OK -> JoolinkSDReplay-v1.3.dylib"
