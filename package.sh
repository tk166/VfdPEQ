#!/bin/bash
# VfdPEQ 打包：组装 .app bundle 并生成 DMG 安装镜像
# 用法: ./package.sh [--build] [version]
#   --build  一键重新编译全部组件（driver → engine → gui）再打包
#   （不带 --build 则直接使用现有构建产物）
set -e

BUILD=0
VERSION="0.2.1"
for arg in "$@"; do
    case "$arg" in
        --build) BUILD=1 ;;
        *) VERSION="$arg" ;;
    esac
done
APP="VfdPEQ.app"
DMG="VfdPEQ-$VERSION.dmg"
ROOT="$(cd "$(dirname "$0")" && pwd)"

# ---- 可选：全组件重新编译（--build）----
if [ "$BUILD" = "1" ]; then
    echo "==== building all components ===="
    (cd "$ROOT/driver" && rm -rf build && make)   || { echo "driver build failed"; exit 1; }
    (cd "$ROOT/engine" && rm -rf build && make)   || { echo "engine build failed"; exit 1; }
    (cd "$ROOT/gui"     && rm -rf build && make)  || { echo "gui build failed";     exit 1; }
    echo "==== build done ===="
fi

# 前置检查
for b in "$ROOT/gui/build/peq_gui" "$ROOT/engine/build/peq_engine" "$ROOT/driver/build/VfdPEQ.driver"; do
    [ -e "$b" ] || { echo "ERROR: missing $b (run make first)"; exit 1; }
done

pkill -f 'build/peq_gui$' 2>/dev/null || true
pkill -f 'build/peq_engine$' 2>/dev/null || true
sleep 1

# ---- 组装 .app ----
rm -rf "$ROOT/$APP"
mkdir -p "$APP/Contents/MacOS" \
         "$APP/Contents/Resources/assets/status-png" \
         "$APP/Contents/Resources/scripts"

# 主程序与引擎
cp "$ROOT/gui/build/peq_gui"      "$APP/Contents/MacOS/peq_gui"
cp "$ROOT/engine/build/peq_engine" "$APP/Contents/MacOS/VfdPEQengine"

# 驱动 bundle（随 app 分发，首次启动时按需安装）
cp -R "$ROOT/driver/build/VfdPEQ.driver" "$APP/Contents/MacOS/VfdPEQ.driver"

# 资源
cp "$ROOT/engine/peq.conf"        "$APP/Contents/Resources/vfdpeq.conf"
cp "$ROOT/assets/vfdpeq-logo.icns" "$APP/Contents/Resources/"
cp -R "$ROOT/assets/status-png/"  "$APP/Contents/Resources/assets/status-png/"
cp "$ROOT/scripts/install.sh" "$ROOT/scripts/uninstall.sh" "$APP/Contents/Resources/scripts/"

# Info.plist
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>VfdPEQ</string>
    <key>CFBundleDisplayName</key>       <string>VfdPEQ</string>
    <key>CFBundleIdentifier</key>        <string>dev.vfdpeq.gui</string>
    <key>CFBundleExecutable</key>        <string>peq_gui</string>
    <key>CFBundleIconFile</key>          <string>vfdpeq-logo</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key>           <string>$VERSION</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>LSMinimumSystemVersion</key>    <string>12.0</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key> <true/>
</dict>
</plist>
PLIST
echo -n "APPL????" > "$APP/Contents/PkgInfo"

# 签名（ad-hoc）
codesign -s - --force --deep "$APP" 2>/dev/null || codesign -s - --force "$APP"

echo "Built $APP"
# ---- DMG：Applications 快捷方式 + 一键卸载脚本 ----
DMG_STAGING="$ROOT/.dmg_stage"
rm -rf "$DMG_STAGING"; mkdir -p "$DMG_STAGING"
cp -R "$ROOT/$APP" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"
cp "$ROOT/scripts/uninstall.command" "$DMG_STAGING/Uninstall VfdPEQ.command"
chmod +x "$DMG_STAGING/Uninstall VfdPEQ.command"
hdiutil create -volname "VfdPEQ $VERSION" -srcfolder "$DMG_STAGING" -ov -format UDZO "$ROOT/$DMG" 2>&1 | tail -1
rm -rf "$DMG_STAGING"
echo "DMG: $ROOT/$DMG ($(du -h "$DMG" | cut -f1))"
