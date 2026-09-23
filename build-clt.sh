#!/bin/bash
#
# build-clt.sh — 只用命令行工具链编译 Compositor（不需要 Xcode，不需要 Apple ID）
#
# 原理：macOS 自带的 Command Line Tools 里已经有 swiftc、clang 和完整的 macOS SDK，
# 足够编译这个工程。工程本身零远程依赖（无 SPM 包），所以绕开 xcodebuild 完全可行。
#
# 用法：
#   ./build-clt.sh            # 编译到 /tmp/cbuild/Compositor
#   BIN_OUT=./Compositor ./build-clt.sh
#
set -euo pipefail
cd "$(dirname "$0")"

BIN_OUT="${BIN_OUT:-/tmp/cbuild/Compositor}"
mkdir -p "$(dirname "$BIN_OUT")"

echo "════════════════════════════════════════════"
echo " 编译 Compositor（命令行工具链）"
echo "════════════════════════════════════════════"

# ---------- 1. 选择与编译器匹配的 SDK ----------
# 关键：SDK 必须与 swiftc 版本匹配。
# 本机曾出现 CLT 编译器 6.1.2 遇上 Swift 6.2 构建的 MacOSX26.2.sdk，
# 直接报 "this SDK is not supported by the compiler"。所以这里逐个试。
SWIFT_VER=$(swift --version 2>&1 | sed -nE 's/.*Apple Swift version ([0-9.]+).*/\1/p')
echo "· 编译器: swift $SWIFT_VER"

SDK=""
for cand in ${SDK:-} $(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX15*.sdk 2>/dev/null | sort -r) \
            /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk; do
  [ -n "$cand" ] && [ -d "$cand" ] || continue
  printf 'import Foundation\n' > /tmp/_sdk_probe.swift
  if xcrun swiftc -sdk "$cand" -target x86_64-apple-macos15.0 -typecheck \
       /tmp/_sdk_probe.swift >/dev/null 2>&1; then
    SDK="$cand"; break
  fi
done

if [ -z "$SDK" ]; then
  echo "✗ 找不到能与当前 swiftc 匹配的 macOS SDK。"
  echo "  可用的 SDK："; ls -1 /Library/Developer/CommandLineTools/SDKs/ | sed 's/^/    /'
  echo "  提示：装一个与本机系统同时期的 Command Line Tools（xcode-select --install）通常即可解决。"
  exit 1
fi
echo "· 使用 SDK: $SDK"

# ---------- 2. 收集源文件 ----------
# 注意：工程是 Swift + C 混合，8 个 C 文件通过桥接头暴露给 Swift。
# 只喂 .swift 会报 "cannot find 'heal_coverage_bounds' in scope" 之类的错。
find Compositor -name "*.swift" | sort > /tmp/_compositor_swift.txt
ls Compositor/Rendering/*.c > /tmp/_compositor_c.txt
echo "· 源文件: $(wc -l < /tmp/_compositor_swift.txt | tr -d ' ') 个 Swift + $(wc -l < /tmp/_compositor_c.txt | tr -d ' ') 个 C"

# ---------- 3. 编译 ----------
# -swift-version 5      工程原本就是 Swift 5 语言模式
# -import-objc-header   工程自带的桥接头，缺了 C 函数就找不到
# 部署目标 15.0         本机 macOS 15.8 可用
echo "· 开始编译…"
set +e
xcrun swiftc \
  -sdk "$SDK" \
  -target x86_64-apple-macos15.0 \
  -swift-version 5 \
  -module-name Compositor \
  -Onone \
  -import-objc-header Compositor/Compositor-Bridging-Header.h \
  -o "$BIN_OUT" \
  @/tmp/_compositor_swift.txt @/tmp/_compositor_c.txt
STATUS=$?
set -e

if [ $STATUS -ne 0 ]; then
  echo
  echo "✗ 编译失败。常见原因："
  echo "  · 报 'main actor-isolated … in a synchronous nonisolated context'"
  echo "    → 工程用 -default-isolation MainActor 编译，本工具链不支持该开关，"
  echo "      需在报错处补 @MainActor（或对纯数据类型改成 nonisolated）"
  echo "  · 报 'cannot find …' 找不到某个 C 函数 → 检查桥接头是否包含对应头文件"
  exit $STATUS
fi

# ---------- 4. 结果 ----------
echo
echo "✓ 编译成功"
SIZE=$(ls -lh "$BIN_OUT" | awk '{print $5}')
echo "  产物:     ${BIN_OUT}  （${SIZE}）"
echo "  架构:     $(lipo -info "$BIN_OUT" | sed 's/.*: //')"
echo "  最低系统: $(otool -l "$BIN_OUT" | grep -A3 LC_BUILD_VERSION | grep minos | head -1 | awk '{print $2}')"
echo
echo "下一步：./make-app.sh   # 装配成可运行的 .app"
