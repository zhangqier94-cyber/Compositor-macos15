#!/bin/bash
#
# update.sh — 跟随上游汉化版更新，重建可在 macOS 15 上运行的 .app
#
# 背景：
#   本工程是 Penny777btc/Compositor（汉化 fork）在 macOS 15 上的降级移植。
#   fork 每发一个新 tag（zh-beta-vX.Y.Z），就可以用本脚本自动跟一遍：
#     拉取 tag → 把移植补丁搬到新 tag 上 → 编译 → 装配 → 校验
#
# 用法：
#   ./update.sh --check          # 只查有没有新版，不改动任何文件
#   ./update.sh                  # 跟随更新（会先确认）
#   ./update.sh --yes            # 跳过确认（适合自动化）
#   ./update.sh --no-build       # 只把补丁搬到新 tag，不编译
#
# 环境要求：macOS + Command Line Tools（不需要 Xcode、不需要 Apple ID）
#
# 注意：macOS 自带 bash 是 3.2，本脚本刻意避开 bash 4 语法
#      （无关联数组、无 ${var,,}、无 mapfile），空数组也不做直接展开
#      （bash 3.2 下 `"${arr[@]}"` 遇 set -u 会报 unbound variable）。
#
set -euo pipefail
cd "$(dirname "$0")"

BRANCH="macos15-port"
FORK="Penny777btc/Compositor"        # 汉化 fork：真正要跟的对象
ORIG="robbietilton/Compositor"       # 原版上游：仅用于提示汉化进度落后多少
DMG_DIR="/tmp/compdmg"
PBX="Compositor.xcodeproj/project.pbxproj"

# ASCII 引号在本脚本里是语法的一部分，说明文字里出现的全角引号不影响执行。

CHECK_ONLY=0
ASSUME_YES=0
DO_BUILD=1
for arg in "$@"; do
  case "$arg" in
    --check)    CHECK_ONLY=1 ;;
    --yes|-y)   ASSUME_YES=1 ;;
    --no-build) DO_BUILD=0 ;;
    -h|--help)  sed -n '3,20p' "$0"; exit 0 ;;
    *) echo "未知参数: $arg"; exit 2 ;;
  esac
done

echo "════════════════════════════════════════════"
echo " Compositor 跟随更新（macOS 15 兼容版）"
echo "════════════════════════════════════════════"

# ---------- 工具函数 ----------

# 把 tag 变成可排序的键：zh-beta-v1.2.2.1 → 0001000200020001
# 不用 sort -V，因为不保证所有 macOS 版本都有
verkey() {
  printf '%s' "$1" | sed -E 's/^zh-beta-v//' \
    | awk -F. '{printf "%04d%04d%04d%04d", $1, $2, $3, (($4=="")?0:$4)}'
}

# 本地已有的最新汉化 tag
newest_local_tag() {
  git tag | while IFS= read -r t; do
    printf '%s %s\n' "$(verkey "$t")" "$t"
  done | sort | tail -1 | awk '{print $2}'
}

# 从 GitHub API 取某仓库最新 release 的 tag（失败返回空，不中断）
latest_release_tag() {
  curl -fsSL --max-time 20 "https://api.github.com/repos/$1/releases?per_page=1" 2>/dev/null \
    | grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"' | head -1 \
    | sed -E 's/.*"([^"]+)"$/\1/' || true
}

# 取某 tag 的 DMG 资产下载地址
release_dmg_url() {
  curl -fsSL --max-time 30 "https://api.github.com/repos/$FORK/releases/tags/$1" 2>/dev/null \
    | grep -oE '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]+\.dmg"' | head -1 \
    | sed -E 's/.*"(https:[^"]+)".*/\1/' || true
}

# 取某 tag 的 .sha256 资产下载地址
release_sha_url() {
  curl -fsSL --max-time 30 "https://api.github.com/repos/$FORK/releases/tags/$1" 2>/dev/null \
    | grep -oE '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]+\.sha256"' | head -1 \
    | sed -E 's/.*"(https:[^"]+)".*/\1/' || true
}

# ---------- 0. 前置检查 ----------
if [ ! -d .git ]; then echo "✗ 当前目录不是 git 仓库"; exit 1; fi
CUR_BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [ "$CUR_BRANCH" != "$BRANCH" ]; then
  echo "✗ 当前在分支 $CUR_BRANCH，期望 $BRANCH。"
  echo "  先执行： git checkout $BRANCH"
  exit 1
fi
if [ -n "$(git status --porcelain)" ]; then
  echo "✗ 工作区有未提交改动，更新会覆盖它们。请先提交或 stash："
  git status --short | sed 's/^/    /'
  exit 1
fi
PORT_COMMIT=$(git rev-parse "$BRANCH")
BASE=$(git rev-parse "$BRANCH~1")
echo "· 当前分支:   $BRANCH ($(git rev-parse --short "$PORT_COMMIT"))"
echo "· 移植基线:   $(git rev-parse --short "$BASE")  $(git describe --tags "$BASE" 2>/dev/null || echo '')"

# ---------- 1. 拉取最新 tag ----------
echo "· 拉取上游 tag…"
git fetch origin --tags --depth=1 --quiet
NEW=$(newest_local_tag)
if [ -z "$NEW" ]; then echo "✗ 没找到任何 zh-beta 标签"; exit 1; fi
echo "· 最新汉化版: $NEW"

# 顺带提示汉化落后原版多少（不阻塞流程）
ORIG_TAG=$(latest_release_tag "$ORIG")
[ -n "$ORIG_TAG" ] && echo "· 原版上游:   $ORIG_TAG （仅英文，仅供参考汉化进度）"

if [ "$BASE" = "$(git rev-parse "$NEW^{commit}")" ]; then
  echo
  echo "✓ 已是最新（基线就是 $NEW），无需更新。"
  # 顺手核对一下已装应用是否与当前基线的版本号一致
  if [ -f "$HOME/Applications/Compositor.app/Contents/Info.plist" ]; then
    CUR_V=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
              "$HOME/Applications/Compositor.app/Contents/Info.plist" 2>/dev/null || echo "?")
    echo "  已安装应用版本: $CUR_V"
  fi
  exit 0
fi

NEW_VER=$(printf '%s' "$NEW" | sed -E 's/^zh-beta-v//')
echo "· 可更新到:   $NEW  (v$NEW_VER)"

if [ "$CHECK_ONLY" -eq 1 ]; then
  echo
  echo "（--check 模式，未做任何改动）"
  echo "新版本包含的提交："
  git log --oneline "$BASE..$NEW" 2>/dev/null | sed 's/^/    /' || echo "    （浅克隆，无法列出）"
  exit 0
fi

if [ "$ASSUME_YES" -eq 0 ]; then
  printf '确认更新到 %s 并重新编译？[y/N] ' "$NEW"
  read -r ans || ans=""
  case "$ans" in y|Y|yes|YES) ;; *) echo "已取消"; exit 0 ;; esac
fi

# ---------- 2. 备份当前分支 ----------
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP="backup/before-$NEW_VER-$STAMP"
git branch "$BACKUP" "$BRANCH"
echo "· 已备份当前分支到 $BACKUP"

# ---------- 3. 下载新版本资源包（装配时要用新版资源，不能复用旧的）----------
DMG_PATH="$DMG_DIR/compositor-$NEW_VER.dmg"
mkdir -p "$DMG_DIR"
if [ -f "$DMG_PATH" ]; then
  echo "· 资源包已存在，跳过下载: $DMG_PATH"
else
  URL=$(release_dmg_url "$NEW")
  if [ -z "$URL" ]; then
    echo "✗ 没能从 release 里找到 $NEW 的 .dmg 资产。"
    echo "  请手动下载后放到 $DMG_PATH 再重跑。"
    echo "  发布页： https://github.com/$FORK/releases/tag/$NEW"
    exit 1
  fi
  echo "· 下载 $URL"
  curl -fL --max-time 300 --progress-bar -o "$DMG_PATH.part" "$URL" || {
    echo "✗ 下载失败"; rm -f "$DMG_PATH.part"; exit 1; }
  mv "$DMG_PATH.part" "$DMG_PATH"
  echo "  已保存: $DMG_PATH  ($(ls -lh "$DMG_PATH" | awk '{print $5}'))"

  # 校验（release 附带 .sha256，尽力而为）
  SHA_URL=$(release_sha_url "$NEW")
  if [ -n "$SHA_URL" ]; then
    echo "· 校验 SHA-256…"
    curl -fsSL --max-time 30 -o "$DMG_PATH.sha256" "$SHA_URL" || true
    if [ -f "$DMG_PATH.sha256" ]; then
      EXPECT=$(grep -oE '[0-9a-fA-F]{64}' "$DMG_PATH.sha256" | head -1 || true)
      ACTUAL=$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')
      if [ -n "$EXPECT" ] && [ "$EXPECT" = "$ACTUAL" ]; then
        echo "  ✓ SHA-256 一致"
      else
        echo "  ⚠️ SHA-256 不一致（期望 $EXPECT，实际 $ACTUAL）"
        printf '  仍要继续吗？[y/N] '
        read -r a2 || a2=""
        case "$a2" in y|Y) ;; *) echo "已取消"; exit 1 ;; esac
      fi
    fi
  fi
fi

# ---------- 4. 把移植补丁搬到新 tag 上 ----------
echo
echo "· 切换到新基线 $NEW 并搬移移植补丁"
git checkout -B "$BRANCH" "$NEW" --quiet
echo "  基线: $(git log --oneline -1)"

set +e
git cherry-pick -X patience "$PORT_COMMIT" --quiet
CP_STATUS=$?
set -e

# 两种情况要分开处理：
#   a) 真的冲突   → 有未合并文件（U 状态）
#   b) 空 cherry-pick → 上游已经包含了我们的改动，没有任何文件冲突
#      这种情况 git 也返回非 0，但绝不能当成冲突回滚
UNMERGED=$(git diff --name-only --diff-filter=U)
if [ -z "$UNMERGED" ] && [ -f .git/CHERRY_PICK_HEAD ]; then
  echo "· 上游已包含同等改动，本次移植为空，跳过"
  git cherry-pick --skip --quiet 2>/dev/null || git cherry-pick --quit 2>/dev/null || true
  CP_STATUS=0
fi

if [ $CP_STATUS -ne 0 ]; then
  echo
  echo "✗ 移植补丁在新版本上产生了冲突，涉及以下文件："
  printf '%s\n' "$UNMERGED" | sed 's/^/    /'
  echo
  echo "  已自动回滚，你的分支仍停在原状态（备份分支 $BACKUP 也保留着）。"
  git cherry-pick --abort 2>/dev/null || true
  git checkout -B "$BRANCH" "$PORT_COMMIT" --quiet
  echo
  echo "  这类冲突通常意味着上游改动了我们打过补丁的同一段代码。"
  echo "  把上面的文件清单发给我，我来逐个手工合并。"
  exit 1
fi
echo "✓ 补丁已干净地搬到 $NEW"

# ---------- 5. 事后修正：部署目标 + 新增 macOS 26 API 扫描 ----------
FIXED=0
N26=$(grep -c 'MACOSX_DEPLOYMENT_TARGET = 26' "$PBX" 2>/dev/null || true)
if [ "$N26" -gt 0 ]; then
  sed -i '' -E 's/MACOSX_DEPLOYMENT_TARGET = 26[0-9.]*;/MACOSX_DEPLOYMENT_TARGET = 15.0;/g' "$PBX"
  echo "· pbxproj 里 $N26 处部署目标 26.x 已改回 15.0"
  FIXED=1
fi

# 已知的 macOS 26 专属 API：这些是 objc_msgSend 动态派发的，
# 不在导入符号表里，符号探针查不出来，只能在源码层扫。
TOKENS='ToolbarSpacer|sharedBackgroundVisibility|NSPopUpButton|borderShape|glassEffect|TaskValueModifier2'
SCAN=$(grep -rnE "\b($TOKENS)\b" Compositor --include='*.swift' 2>/dev/null || true)
if [ -n "$SCAN" ]; then
  echo
  echo "⚠️ 源码里出现 macOS 26 专属 API 嫌疑："
  printf '%s\n' "$SCAN" | sed 's/^/    /'
  echo "  → 若编译报 'has no member' 或运行时崩溃，删掉对应调用即可（回落系统默认外观）。"
  FIXED=1
fi
if [ "$FIXED" -eq 0 ]; then
  echo "· 部署目标与 API 扫描均无异常"
fi

# 让这些修正进入版本历史，下次 cherry-pick 才不会互相打架
if [ -n "$(git status --porcelain)" ]; then
  git add -A
  git commit -q -m "port: 跟随 $NEW 的事后修正（部署目标 / macOS 26 API）"
  echo "· 已提交事后修正"
fi

# ---------- 6. 编译 ----------
if [ "$DO_BUILD" -eq 0 ]; then
  echo
  echo "（--no-build 模式，补丁已搬移但未编译）"
  echo "手动编译： ./build-clt.sh && ./make-app.sh"
  exit 0
fi

echo
echo "════════════════════════════════════════════"
echo " 编译"
echo "════════════════════════════════════════════"
set +e
./build-clt.sh
BUILD_STATUS=$?
set -e

if [ $BUILD_STATUS -ne 0 ]; then
  echo
  echo "✗ 编译失败。"
  echo "  新版源码里可能又引入了需要适配的写法。常见两类："
  echo "    1) 'main actor-isolated … in a synchronous nonisolated context'"
  echo "       → 上游用了 Swift 6.2 的 -default-isolation MainActor，命令行工具链不支持，"
  echo "         需在报错处补 @MainActor（纯数据类型改 nonisolated）"
  echo "    2) 'has no member …'"
  echo "       → 又用了 macOS 26 新 API，删掉该调用即可"
  echo
  echo "  把编译报错贴给我，我来逐个修。当前状态可随时回滚："
  echo "    git checkout -B $BRANCH $BACKUP"
  exit 1
fi

# ---------- 7. 装配 ----------
echo
echo "════════════════════════════════════════════"
echo " 装配应用包"
echo "════════════════════════════════════════════"
# 先卸掉可能残留的旧卷，确保 make-app.sh 只会看到新版本的资源
for vol in /Volumes/*; do
  case "$(basename "$vol")" in
    *Compositor*|*compositor*) hdiutil detach "$vol" -quiet 2>/dev/null || true ;;
  esac
done

BIN_LOCAL=/tmp/cbuild/Compositor DMG="$DMG_PATH" ./make-app.sh

echo
echo "════════════════════════════════════════════"
echo " 更新完成"
echo "════════════════════════════════════════════"
echo "版本:     $NEW (v$NEW_VER)"
echo "应用:     $HOME/Applications/Compositor.app"
echo "备份分支: $BACKUP"
echo
echo "试试启动： open \"$HOME/Applications/Compositor.app\""
echo "若要回滚： git checkout -B $BRANCH $BACKUP && ./build-clt.sh && ./make-app.sh"
