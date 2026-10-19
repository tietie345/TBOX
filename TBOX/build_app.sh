#!/bin/bash
# 将 swift build 产出的裸二进制打包成规范的 TBOX.app。
# 作用：给应用一个固定 Bundle ID 与稳定安装路径，避免每次重编译后
# 因 adhoc cdhash 变化导致系统设置里的屏幕录制/麦克风授权失配。
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="TBOX"
BUNDLE_ID="com.tbox.app"
APP_DIR="${PROJECT_DIR}/dist/${APP_NAME}.app"
BUNDLE_VERSION="0.1"

echo "==> [1/4] Release 编译…"
cd "$PROJECT_DIR"
swift build -c release

echo "==> [2/4] 组装 .app 目录结构…"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$PROJECT_DIR/.build/release/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"
if [ -f "$PROJECT_DIR/TBOX/Resources/TBOX.icns" ]; then
    cp "$PROJECT_DIR/TBOX/Resources/TBOX.icns" "$APP_DIR/Contents/Resources/TBOX.icns"
fi

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${BUNDLE_VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUNDLE_VERSION}</string>
    <key>CFBundleIconFile</key>
    <string>TBOX.icns</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>用于录制会议或语音备忘，并在本地转写成文字稿。</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>用于将录制的语音在本地转写成文字。</string>
</dict>
</plist>
PLIST

# PkgInfo 标记
echo -n "APPL????" > "$APP_DIR/Contents/PkgInfo"

echo "==> [3/4] 签名 bundle…"
CERT_NAME="TBOX Development"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
    # 用固定自签名证书签名，保证 cdhash 稳定，TCC 屏幕录制/麦克风权限
    # 不会每次重编译后失效。adhoc 签名会导致系统设置里的权限记录错配，
    # SCStream 启动时报 "The operation could not be completed"。
    codesign --force --deep --sign "$CERT_NAME" "$APP_DIR"
    echo "已使用固定证书 '$CERT_NAME' 签名"
else
    echo "⚠️  未找到固定证书 '$CERT_NAME'，回退到 adhoc 签名。"
    echo "    录屏/录音可能因 TCC 权限失效而报错，请先运行 ./setup_cert.sh"
    codesign --force --deep --sign - "$APP_DIR"
fi

echo "==> [4/4] 完成"
echo "应用包：$APP_DIR"
echo "Bundle ID：$BUNDLE_ID"
echo ""
echo "启动方式：open \"$APP_DIR\""
