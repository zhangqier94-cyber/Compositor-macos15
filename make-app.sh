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
# SRC_APP 不再硬编码：旧版把卷名写死（"Compositor 中文体验版"），
# 一旦上游改了卷名/应用名就会失效。现在改为自动探测，也允许用环境变量显式指定。
SRC_APP="${SRC_APP:-}"
DEST_APP="${DEST_APP:-$HOME/Applications/Compositor.app}"

echo "════════════════════════════════════════════"
echo " 装配 Compositor（macOS 15 兼容版）"
echo "════════════════════════════════════════════"

# ---------- 1. 前置检查 ----------
[ -f "$BIN_LOCAL" ] || { echo "✗ 找不到编译产物 ${BIN_LOCAL}，请先编译"; exit 1; }
echo "✓ 编译产物: $(ls -lh "$BIN_LOCAL" | awk '{print $5}')  $(file -b "$BIN_LOCAL" | cut -c1-60)"

# ---------- 2. 准备源 .app（必要时挂载 DMG）----------
# 优先用显式指定的 SRC_APP；否则扫 /Volumes 下卷名含 Compositor 的已挂载卷。
#
# ⚠️ 关键教训：不能只看卷名就取第一个 .app。
# 本机曾同时挂着两个包——/Volumes/Compositor 是上游英文原版 v1.2.4，
# /Volumes/Compositor 中文体验版 才是汉化版 v1.2.2.1。按字母序前者在前，
# 结果把英文资源装配进去，中文本地化直接丢失。所以必须校验候选包内容。
#
# 判定顺序：带 zh-Hans.lproj 的优先（本工程就是要中文）→ 同级取 mtime 最新者。
# 注意：诊断信息一律写 stderr，否则会污染命令替换的返回值。
find_src_app() {
  if [ -n "$SRC_APP" ] && [ -d "$SRC_APP" ]; then printf '%s' "$SRC_APP"; return 0; fi

  ALL=""; ZH=""
  for vol in /Volumes/*; do
    [ -d "$vol" ] || continue
    case "$(basename "$vol")" in
      *Compositor*|*compositor*) ;;
      *) continue ;;
    esac
    for app in "$vol"/*.app; do
      [ -d "$app" ] || continue
      ALL="${ALL}${app}"$'\n'
      [ -d "$app/Contents/Resources/zh-Hans.lproj" ] && ZH="${ZH}${app}"$'\n'
    done
  done

  [ -n "$ALL" ] || return 1

  if [ -n "$ZH" ]; then POOL="$ZH"; else
    POOL="$ALL"
    echo "· ⚠️ 候选里没有一个带 zh-Hans.lproj，装配后将没有中文界面" >&2
  fi

  # 把全部候选（含被排除的）摊开报告，避免"悄悄选错"这种事再次发生
  N_ALL=$(printf '%s' "$ALL" | grep -c . || true)
  if [ "$N_ALL" -gt 1 ]; then
    echo "· 发现 $N_ALL 个候选资源包：" >&2
    while IFS= read -r a; do
      [ -n "$a" ] || continue
      V=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$a/Contents/Info.plist" 2>/dev/null || echo "?")
      if [ -d "$a/Contents/Resources/zh-Hans.lproj" ]; then
        L="含中文 ✓ 可用"
      else
        L="无中文 ✗ 排除"
      fi
      echo "    - $a  (v$V, $L)" >&2
    done <<< "$ALL"
  fi

  BEST=""; BEST_T=0
  while IFS= read -r a; do
    [ -n "$a" ] || continue
    T=$(stat -f %m "$a" 2>/dev/null || echo 0)
    if [ "$T" -gt "$BEST_T" ]; then BEST_T="$T"; BEST="$a"; fi
  done <<< "$POOL"

  [ -n "$BEST" ] || return 1
  printf '%s' "$BEST"
}

if ! DETECTED=$(find_src_app); then
  [ -f "$DMG" ] || { echo "✗ 找不到已挂载的资源来源，也找不到安装包 $DMG"; exit 1; }
  # 先卸载残留的旧卷，避免多个版本同时挂着时选错
  for vol in /Volumes/*; do
    case "$(basename "$vol")" in
      *Compositor*|*compositor*) echo "· 卸载残留卷 $(basename "$vol")"; hdiutil detach "$vol" -quiet 2>/dev/null || true ;;
    esac
  done
  echo "· 挂载安装包镜像 $DMG"
  hdiutil attach -nobrowse -quiet "$DMG"
  sleep 1
  DETECTED=$(find_src_app) || { echo "✗ 挂载后仍找不到源 .app"; exit 1; }
fi
SRC_APP="$DETECTED"
[ -d "$SRC_APP" ] || { echo "✗ 资源来源不是目录: $SRC_APP"; exit 1; }

# 装配前最后一道闸：没有中文本地化就停下来问清楚
HAS_ZH=0
[ -d "$SRC_APP/Contents/Resources/zh-Hans.lproj" ] && HAS_ZH=1
echo "✓ 资源来源: $SRC_APP"
if [ "$HAS_ZH" -eq 0 ]; then
  echo "✗ 该资源包不含 zh-Hans.lproj，装配出来会是英文界面。"
  echo "  若确认要英文，可加 ALLOW_NO_ZH=1 重跑；否则请指定正确的 SRC_APP，例如："
  echo "    SRC_APP=\"/Volumes/Compositor 中文体验版/Compositor 中文体验版.app\" ./make-app.sh"
  [ "${ALLOW_NO_ZH:-0}" = "1" ] || exit 1
fi

# ---------- 3. 拷贝包结构，只换可执行文件 ----------
echo "· 拷贝应用包到 $DEST_APP"
mkdir -p "$(dirname "$DEST_APP")"
rm -rf "$DEST_APP"
ditto "$SRC_APP" "$DEST_APP"

echo "· 替换主可执行文件"
cp "$BIN_LOCAL" "$DEST_APP/Contents/MacOS/Compositor"
chmod +x "$DEST_APP/Contents/MacOS/Compositor"

# ---------- 3.5 补齐移植层的中文文案 ----------
# 应用复用官方 .app 里已编译好的 Localizable.strings —— 没有 Xcode 就没有 actool/xcstringstool
# 能重编这份表。移植层新增的字符串（如工具栏更新按钮）因此要在这里补进去，
# 否则中文界面里会夹着几个英文标签，而且不会有任何报错。
STRINGS="$DEST_APP/Contents/Resources/zh-Hans.lproj/Localizable.strings"
if [ -f port-localizations.json ] && [ -f "$STRINGS" ]; then
  PY=$(command -v python3 || echo /usr/bin/python3)
  if [ -x "$PY" ]; then
    "$PY" merge-strings.py --bundle-strings "$STRINGS" 2>&1 | sed 's/^/   /'
  else
    echo "   ⚠️ 未找到 python3，跳过中文文案补齐（新增的更新按钮会显示英文提示）"
  fi
fi

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
