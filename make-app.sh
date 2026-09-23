#!/bin/bash
#
# make-app.sh — 把本地编译出的可执行文件装配成可运行的 .app
#
# 思路：官方 DMG 里的 .app 已经包含了编译好的资源（Assets.car 图像资源、
# zh-Hans.lproj 中文本地化、AppIcon.icns 图标、Info.plist）。这些资源与
# 源码版本完全对应，可以直接复用。本脚本只把 Main executable 换成我们用
# 命令行工具链（目标 macOS 15.0）重新编译出来的那份，然后改成新签名。
#
# 用法： ./make-app.sh
#
set -euo pipefail

cd "$(dirname "$0")"

BIN_LOCAL="${BIN_LOCAL:-/tmp/cbuild/Compositor}"
DMG="${DMG:-/tmp/compdmg/c.dmg}"
SRC_APP="/Volumes/Compositor 中文体验版/Compositor 中文体验版.app"
DEST_APP="${DEST_APP:-$HOME/Applications/Compositor.app}"

echo "════════════════════════════════════════════"
echo " 装配 Compositor（macOS 15 兼容版）"
echo "════════════════════════════════════════════"

# ---------- 1. 前置检查 ----------
[ -f "$BIN_LOCAL" ] || { echo "✗ 找不到编译产物 $BIN_LOCAL，请先编译"; exit 1; }
echo "✓ 编译产物: $(ls -lh "$BIN_LOCAL" | awk '{print $5}')  $(file -b "$BIN_LOCAL" | cut -c1-60)"

# ---------- 2. 准备源 .app（必要时挂载 DMG）----------
if [ ! -d "$SRC_APP" ]; then
  [ -f "$DMG" ] || { echo "✗ 找不到 $SRC_APP，也找不到安装包 $DMG"; exit 1; }
  echo "· 挂载安装包镜像…"
  hdiutil attach -nobrowse -quiet "$DMG"
  sleep 1
fi
[ -d "$SRC_APP" ] || { echo "✗ 挂载后仍找不到源 .app"; exit 1; }
echo "✓ 资源来源: $SRC_APP"

# ---------- 3. 拷贝包结构，只换可执行文件 ----------
echo "· 拷贝应用包到 $DEST_APP"
mkdir -p "$(dirname "$DEST_APP")"
rm -rf "$DEST_APP"
ditto "$SRC_APP" "$DEST_APP"

echo "· 替换主可执行文件"
cp "$BIN_LOCAL" "$DEST_APP/Contents/MacOS/Compositor"
chmod +x "$DEST_APP/Contents/MacOS/Compositor"

# ---------- 4. 改写 Info.plist ----------
PLIST="$DEST_APP/Contents/Info.plist"
echo "· 修改最低系统版本要求"
OLD_MIN=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$PLIST" 2>/dev/null || echo "（无此键）")
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion 15.0" "$PLIST" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string 15.0" "$PLIST"
# 顺手清理只反映构建环境的字段，避免误导
for k in DTSDKName DTSDKBuild DTXcode DTXcodeBuild DTPlatformVersion DTCompiler BuildMachineOSBuild; do
  /usr/libexec/PlistBuddy -c "Delete :$k" "$PLIST" 2>/dev/null || true
done
NEW_MIN=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$PLIST")
echo "   LSMinimumSystemVersion: $OLD_MIN → $NEW_MIN"

# ---------- 5. 重新签名（本地临时签名，无需开发者证书）----------
echo "· 移除旧签名并重新临时签名"
rm -rf "$DEST_APP/Contents/_CodeSignature"
codesign --force --deep --sign - "$DEST_APP" 2>&1 | sed 's/^/   /'

# ---------- 6. 校验 ----------
echo
echo "════════════════════════════════════════════"
echo " 校验"
echo "════════════════════════════════════════════"
EXE="$DEST_APP/Contents/MacOS/Compositor"
echo "· 架构:        $(lipo -info "$EXE" 2>/dev/null | sed 's/.*: //')"
echo "· 最低系统:    $(otool -l "$EXE" | grep -A3 LC_BUILD_VERSION | grep minos | head -1 | awk '{print $2}')"
echo "· 资源检查:    $(ls "$DEST_APP/Contents/Resources/Assets.car" >/dev/null 2>&1 && echo '图像资源 ✓' || echo '图像资源 ✗')  $(ls -d "$DEST_APP/Contents/Resources/zh-Hans.lproj" >/dev/null 2>&1 && echo '中文本地化 ✓' || echo '中文本地化 ✗')"
echo "· 签名:        $(codesign -dv "$DEST_APP" 2>&1 | grep -E 'Signature|Format' | head -2 | tr '\n' ' ')"
if dyld_info -imports -arch x86_64 "$EXE" 2>/dev/null | grep -qE 'ToolbarSpacer|_TaskValueModifier2|sharedBackgroundVisibility'; then
  echo "· 符号自检:    ✗ 仍含 macOS 26 专属符号"
else
  echo "· 符号自检:    ✓ 未引用 macOS 26 专属符号"
fi

echo
echo "════════════════════════════════════════════"
echo " 完成"
echo "════════════════════════════════════════════"
echo "应用位置: $DEST_APP"
echo
echo "启动方式一：open \"$DEST_APP\""
echo "启动方式二：Finder 里到 ~/Applications 双击"
echo
echo "如果 macOS 提示「无法验证开发者」：右键点应用 → 打开 → 再点「打开」即可。"
