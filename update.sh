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
  echo "✗ 当前在分支 ${CUR_BRANCH}，期望 ${BRANCH}。"
  echo "  先执行： git checkout $BRANCH"
  exit 1
fi
if [ -n "$(git status --porcelain)" ]; then
  echo "✗ 工作区有未提交改动，更新会覆盖它们。请先提交或 stash："
  git status --short | sed 's/^/    /'
  exit 1
fi
# 移植基线 = 从分支顶端往回走，第一个打了 zh-beta 标签的提交
#
# ⚠️ 不要用 `$BRANCH~1` 当基线。最初就是那么写的，等到往分支上补第二个
# 提交（修 make-app.sh）之后，`~1` 就变成我们自己那个提交了，基线凭空错位。
# 回走查标签对"分支上有几个提交"完全不敏感，是稳的。
find_base_tag() {
  for c in $(git rev-list "$BRANCH"); do
    t=$(git tag --points-at "$c" | grep -E '^zh-beta-v' | head -1)
    if [ -n "$t" ]; then printf '%s' "$t"; return 0; fi
  done
  return 1
}

PORT_TIP=$(git rev-parse "$BRANCH")
BASE_TAG=$(find_base_tag) || {
  echo "✗ 无法确定移植基线（在 $BRANCH 的历史里找不到任何 zh-beta 标签）"
  exit 1
}
BASE_COMMIT=$(git rev-parse "$BASE_TAG^{commit}")
N_PORT_COMMITS=$(git rev-list --count "$BASE_COMMIT..$PORT_TIP")

echo "· 当前分支:   $BRANCH ($(git rev-parse --short "$PORT_TIP"), 含 $N_PORT_COMMITS 个移植提交)"
echo "· 移植基线:   $(git rev-parse --short "$BASE_COMMIT")  $BASE_TAG"

# ---------- 1. 拉取最新 tag ----------
echo "· 拉取上游 tag…"
git fetch origin --tags --depth=1 --quiet
NEW=$(newest_local_tag)
if [ -z "$NEW" ]; then echo "✗ 没找到任何 zh-beta 标签"; exit 1; fi
echo "· 最新汉化版: $NEW"

# 顺带提示汉化落后原版多少（不阻塞流程）
ORIG_TAG=$(latest_release_tag "$ORIG")
if [ -n "$ORIG_TAG" ]; then
  echo "· 原版上游:   $ORIG_TAG （仅英文，仅供参考汉化进度）"
fi

NEW_COMMIT=$(git rev-parse "$NEW^{commit}")
if [ "$BASE_COMMIT" = "$NEW_COMMIT" ]; then
  echo
  echo "✓ 已是最新（移植基线就是 ${NEW}），无需更新。"
  # 顺手核对一下已装应用是否与当前基线的版本号一致
  if [ -f "$HOME/Applications/Compositor.app/Contents/Info.plist" ]; then
    CUR_V=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
              "$HOME/Applications/Compositor.app/Contents/Info.plist" 2>/dev/null || echo "?")
    echo "  已安装应用版本: $CUR_V"
    echo "  基线对应版本:   $(printf '%s' "$BASE_TAG" | sed -E 's/^zh-beta-v//')"
  fi
  exit 0
fi

NEW_VER=$(printf '%s' "$NEW" | sed -E 's/^zh-beta-v//')
echo "· 可更新到:   $NEW  (v$NEW_VER)"

if [ "$CHECK_ONLY" -eq 1 ]; then
  echo
  echo "（--check 模式，未做任何改动）"
  echo "新版本相对当前基线的提交："
  git log --oneline "$BASE_COMMIT..$NEW_COMMIT" 2>/dev/null | sed 's/^/    /' || echo "    （浅克隆，无法列出）"
  echo
  echo "继续更新请执行： ./update.sh"
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
        echo "  ⚠️ SHA-256 不一致（期望 ${EXPECT}，实际 ${ACTUAL}）"
        printf '  仍要继续吗？[y/N] '
        read -r a2 || a2=""
        case "$a2" in y|Y) ;; *) echo "已取消"; exit 1 ;; esac
      fi
    fi
  fi
fi

# ---------- 4. 把移植提交搬到新基线 ----------
# 用 rebase --onto 而不是 cherry-pick 单个提交：
# 分支上可能已经积累了多个移植提交（例如后来又修了 make-app.sh），
# 只挑最后一个会把前面的改动全丢掉。--onto 会把 BASE_TAG..BRANCH 整个范围重放。
# --empty=drop：若上游已包含同等改动导致某提交变空，直接丢弃而不是停下来。
echo
echo "· 把 $N_PORT_COMMITS 个移植提交搬到新基线 $NEW"
set +e
git rebase --onto "$NEW" "$BASE_TAG" --empty=drop 2>&1 | sed 's/^/    /'
RB_STATUS=${PIPESTATUS[0]}
set -e

if [ -d .git/rebase-merge ] || [ -d .git/rebase-apply ]; then
  UNMERGED=$(git diff --name-only --diff-filter=U)
  echo
  echo "✗ 移植提交在新版本上产生冲突，涉及以下文件："
  printf '%s\n' "$UNMERGED" | sed 's/^/    /'
  git rebase --abort 2>/dev/null || true
  echo
  echo "  已自动回滚。分支仍停在 $BRANCH ($(git rev-parse --short "$PORT_TIP"))，"
  echo "  备份分支 $BACKUP 也保留着，什么都没丢。"
  echo
  echo "  这类冲突通常意味着上游改动了我们打过补丁的同一段代码。"
  echo "  把上面的文件清单发给我，我来逐个手工合并。"
  exit 1
fi

if [ "$RB_STATUS" -ne 0 ]; then
  echo "✗ 搬移失败（git rebase 退出码 ${RB_STATUS}），未产生冲突但未能完成。"
  echo "  当前状态请用 git status 查看，必要时回滚： git checkout -B $BRANCH $BACKUP"
  exit 1
fi

NOW_PORT_COMMITS=$(git rev-list --count "$NEW_COMMIT..$BRANCH")
echo "✓ 搬移完成，分支上现有 $NOW_PORT_COMMITS 个移植提交"
if [ "$NOW_PORT_COMMITS" -eq 0 ]; then
  echo "  ⚠️ 移植提交全被判为空提交丢掉了 —— 说明上游可能自己就做完了这些兼容改动。"
  echo "     先别急，下面的事后修正与编译会验证这一点。"
fi

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
#
# 名单里刻意不放 NSPopUpButton —— 它本身是 macOS 15 就有的老类型
# （实测当前源码里有 12 处正常使用），只有它的 .borderShape 属性是新加的，
# 把类型名放进来会造成大量误报，等于把告警废掉。
TOKENS='ToolbarSpacer|sharedBackgroundVisibility|borderShape|glassEffect|TaskValueModifier2'

# 关键：必须先剥掉行内注释再判断。
# 我们自己写的移植说明注释里就带着 "ToolbarSpacer 是 macOS 26 新增 API"、
# "原代码为 button.borderShape = .capsule" 这类字样，
# 直接 grep 会把 5 处说明文字当成真调用，全是误报。
# 局限：字符串字面量里的 // 会被误当注释起点，对这种场景够用。
scan_code_hits() {
  grep -rnE "\b($TOKENS)\b" Compositor --include='*.swift' 2>/dev/null \
  | while IFS= read -r hit; do
      code_only=$(printf '%s' "$hit" | sed 's://.*::')
      if printf '%s' "$code_only" | grep -qE "\b($TOKENS)\b"; then
        printf '%s\n' "$hit"
      fi
    done
}

RAW_N=$(grep -rnE "\b($TOKENS)\b" Compositor --include='*.swift' 2>/dev/null | wc -l | tr -d ' ')
SCAN=$(scan_code_hits)
CODE_N=$(printf '%s' "$SCAN" | grep -c . || true)
[ -n "$SCAN" ] || CODE_N=0

if [ "$CODE_N" -gt 0 ]; then
  echo
  echo "⚠️ 源码里出现 macOS 26 专属 API 的疑似真调用："
  printf '%s\n' "$SCAN" | sed 's/^/    /'
  echo "  → 这类 API 不在导入符号表里，符号探针查不出，只能靠这里拦。"
  echo "  → 若编译报 'has no member' 或运行时崩溃，删掉对应调用即可（回落系统默认外观）。"
  FIXED=1
elif [ "$RAW_N" -gt 0 ]; then
  echo "· API 扫描：命中 $RAW_N 处，但都只是注释里提到，不是真调用（已过滤）"
fi
if [ "$FIXED" -eq 0 ]; then
  echo "· 部署目标与 API 扫描均无异常"
fi

# 让这些修正进入版本历史，下次 rebase 才不会互相打架
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
