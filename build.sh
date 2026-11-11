#!/bin/bash
# 编译并打包 FinderPlus.app（Apple 芯片）
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="FinderPlus"
OUT_DIR="build"
APP="$OUT_DIR/$APP_NAME.app"

echo "==> 编译 (release)"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

echo "==> 组装 .app"
rm -rf "$OUT_DIR"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"

echo "==> 生成图标（失败不影响使用）"
(
  set +e
  ICONSET="$OUT_DIR/AppIcon.iconset"
  mkdir -p "$ICONSET"
  swift Scripts/make_icon.swift "$OUT_DIR/icon_1024.png" || exit 0
  [ -f "$OUT_DIR/icon_1024.png" ] || exit 0
  mk() { sips -z "$1" "$1" "$OUT_DIR/icon_1024.png" --out "$ICONSET/$2" >/dev/null; }
  mk 16 icon_16x16.png;      mk 32 icon_16x16@2x.png
  mk 32 icon_32x32.png;      mk 64 icon_32x32@2x.png
  mk 128 icon_128x128.png;   mk 256 icon_128x128@2x.png
  mk 256 icon_256x256.png;   mk 512 icon_256x256@2x.png
  mk 512 icon_512x512.png;   mk 1024 icon_512x512@2x.png
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
) || echo "图标生成跳过"

echo "==> 临时签名 (ad-hoc)"
codesign --force --deep --sign - "$APP"

echo "==> 压缩"
(cd "$OUT_DIR" && ditto -c -k --sequesterRsrc --keepParent "$APP_NAME.app" "$APP_NAME.zip")

echo "完成: $OUT_DIR/$APP_NAME.zip"
