#!/bin/bash
# Compositor macOS 15 兼容版 — 一键构建脚本
#
# 用法：
#   chmod +x build.sh
#   ./build.sh
#
# 产物：build/Build/Products/Release/Compositor.app
#
# 说明：本脚本通过 DEVELOPER_DIR 指定 Xcode，不需要 sudo、不需要改全局 xcode-select。

set -o pipefail
cd "$(dirname "$0")" || exit 1

echo "==================================================="
echo " Compositor macOS 15 兼容版 构建"
echo "==================================================="
echo

# ---------- 1. 定位 Xcode ----------
echo "[1/5] 定位 Xcode"

XC=""
if [ -n "$DEVELOPER_DIR" ] && [ -d "$DEVELOPER_DIR" ]; then
  XC="$DEVELOPER_DIR"
else
  # 优先取 /Applications 下的 Xcode 26.x
  for cand in /Applications/Xcode.app /Applications/Xcode-26.*.app /Applications/Xcode_26*.app; do
    if [ -d "$cand/Contents/Developer" ]; then XC="$cand/Contents/Developer"; break; fi
  done
fi

if [ -z "$XC" ]; then
  CUR=$(xcode-select -p 2>/dev/null)
  if echo "$CUR" | grep -q "Xcode.app"; then XC="$CUR"; fi
fi

if [ -z "$XC" ]; then
  echo
  echo "  ✗ 没找到完整的 Xcode（只有 Command Line Tools 无法构建本工程）。"
  echo
  echo "  请先安装 Xcode 26.0 ~ 26.3，装好后确认它位于 /Applications 下。"
  echo "  注意：Xcode 26.4 起要求 macOS 26.2 且仅提供 Apple Silicon 版本，本机用不了。"
  echo
  exit 1
fi

export DEVELOPER_DIR="$XC"
echo "  使用: $XC"
xcodebuild -version 2>/dev/null | sed 's/^/  /'

XV=$(xcodebuild -version 2>/dev/null | head -1 | awk '{print $2}')
case "$XV" in
  26.0|26.0.*|26.1|26.1.*|26.2|26.2.*|26.3|26.3.*)
    echo "  ✓ Xcode $XV 可用" ;;
  *)
    echo "  ⚠ 当前为 Xcode $XV。本工程已按 Xcode 26.0–26.3 验证，其他版本可能需额外调整。" ;;
esac
echo

# ---------- 2. 确认部署目标已下调 ----------
echo "[2/5] 检查部署目标"
TARGETS=$(grep -o "MACOSX_DEPLOYMENT_TARGET = [0-9.]*" Compositor.xcodeproj/project.pbxproj | sort -u)
echo "  $TARGETS" | sed 's/^/  /'
if echo "$TARGETS" | grep -q "MACOSX_DEPLOYMENT_TARGET = 2[6-9]"; then
  echo "  ✗ 仍存在 26.x 的部署目标，请把 project.pbxproj 里所有 MACOSX_DEPLOYMENT_TARGET 改为 15.0"
  exit 1
fi
echo "  ✓ 部署目标已下调"
echo

# ---------- 3. 确认 scheme ----------
echo "[3/5] 检查 scheme"
if ! ls Compositor.xcodeproj/xcshareddata/xcschemes/*.xcscheme >/dev/null 2>&1; then
  echo "  ✗ 缺少共享 scheme，无法用 xcodebuild 构建。"
  exit 1
fi
echo "  ✓ $(ls Compositor.xcodeproj/xcshareddata/xcschemes/ | tr '\n' ' ')"
echo

# ---------- 4. 清理旧产物（可选） ----------
if [ "${1:-}" = "--clean" ]; then
  echo "[4/5] 清理旧的构建产物"
  rm -rf build
  echo "  ✓ 已清理"
else
  echo "[4/5] 跳过清理（加 --clean 可全量重建）"
fi
echo

# ---------- 5. 构建 ----------
echo "[5/5] 开始构建（Release / ad-hoc 本地签名）"
echo
echo "  DEVELOPER_DIR=$DEVELOPER_DIR xcodebuild -scheme Compositor ..."
echo

xcodebuild \
  -project Compositor.xcodeproj \
  -scheme Compositor \
  -configuration Release \
  -derivedDataPath build \
  -destination 'generic/platform=macOS' \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="" \
  build

STATUS=$?

echo
if [ $STATUS -ne 0 ]; then
  echo "==================================================="
  echo " 构建失败（退出码 $STATUS）"
  echo "==================================================="
  echo
  echo "排查顺序："
  echo "  1. 报某 API「is only available in macOS X.Y or newer」"
  echo "     → project.pbxproj 里搜索 MACOSX_DEPLOYMENT_TARGET，把 15.0 调高到提示的版本；"
  echo "       若提示的是 macOS 26 API，说明还有漏改的调用点，按文件行号处理。"
  echo "  2. 报「unable to type-check this expression in reasonable time」"
  echo "     → Xcode 对超大 ViewBuilder 的已知限制，把报错那行的表达式拆成几个局部变量。"
  echo "  3. 报签名相关错误"
  echo "     → 本脚本已用 ad-hoc 签名(-)，若仍失败，可在 Xcode 里把 Signing 设为"
  echo "        \"Sign to Run Locally\"，或关闭 ENABLE_APP_SANDBOX。"
  echo "  4. 想看完整日志，在命令末尾加 2>&1 | tee build.log"
  echo
  exit $STATUS
fi

echo "==================================================="
echo " 构建成功"
echo "==================================================="
echo
APP="build/Build/Products/Release/Compositor.app"
if [ -d "$APP" ]; then
  APPABS="$(cd "$APP/.." && pwd)/$(basename "$APP")"
  echo "应用位置： $APPABS"
  echo
  echo "运行：  open \"$APPABS\""
  echo "装机：  cp -R \"$APPABS\" /Applications/"
  echo
  echo "首次运行若是被 Gatekeeper 拦截（本地 ad-hoc 签名，未公证）："
  echo "  右键点应用 > 打开 > 再点「打开」；或执行："
  echo "  xattr -dr com.apple.quarantine \"$APPABS\""
else
  echo "未找到预期的 .app，请检查上面的输出。"
  exit 1
fi
echo
