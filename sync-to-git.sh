#!/bin/bash
# sync-to-git.sh —— 把本仓库的每次更新（代码 + 可选安装包）保存到你的 GitHub
# 用法:
#   ./sync-to-git.sh                     # 提交所有改动并推送（自动生成提交信息）
#   ./sync-to-git.sh "提交信息"           # 同上，使用指定提交信息
#   ./sync-to-git.sh "" release          # 额外打包 ~/Applications/Compositor.app 并上传为新 Release
#   ./sync-to-git.sh "msg" release 1.2.2.2  # 指定版本号
#
# 认证: Token 存在 macOS 钥匙串（security find-internet-password -s github.com）
#   由 /Users/lee.fu/.workbuddy/git-cred-github.sh 读取，本脚本不含任何密钥。

set -uo pipefail
cd "$(dirname "$0")"

REMOTE_NAME="mine"                                  # https://github.com/zhangqier94-cyber/Compositor-macos15
TOKEN="$(security find-internet-password -s github.com -a zhangqier94-cyber -w 2>/dev/null)"
OWNER_REPO="zhangqier94-cyber/Compositor-macos15"
APP_PATH="$HOME/Applications/Compositor.app"
MSG="${1:-}"
MODE="${2:-}"
VERSION="${3:-}"

# ---------- 1. 提交 ----------
if [ -n "$(git status --porcelain)" ]; then
  if [ -z "$MSG" ]; then
    MSG="chore: 更新于 $(date '+%Y-%m-%d %H:%M')"
  fi
  git add -A
  git commit -m "$MSG" || { echo "✗ 提交失败"; exit 1; }
  echo "✓ 已提交: $MSG"
else
  echo "• 没有未提交的改动"
fi

# ---------- 2. 推送（先常规，失败则绕过代理重试） ----------
push_all() {
  git push -u "$REMOTE_NAME" main macos15-port && git push "$REMOTE_NAME" --tags
}
if push_all; then
  echo "✓ 已推送到 $REMOTE_NAME"
else
  echo "! 常规推送失败，尝试绕过本地代理…"
  if git -c http.proxy= push -u "$REMOTE_NAME" main macos15-port && git -c http.proxy= push "$REMOTE_NAME" --tags; then
    echo "✓ 已推送（绕过代理）"
  else
    echo "✗ 推送失败，请检查网络或钥匙串 Token"; exit 1
  fi
fi

# ---------- 3. （可选）打包并上传 Release ----------
if [ "$MODE" != "release" ]; then exit 0; fi
[ -n "$TOKEN" ] || { echo "✗ 钥匙串中没有 GitHub Token，无法上传 Release"; exit 1; }
[ -d "$APP_PATH" ] || { echo "✗ 未找到 $APP_PATH"; exit 1; }

[ -n "$VERSION" ] || VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist" 2>/dev/null)"
TAG="macos15-v${VERSION}"
ZIP="dist/Compositor-macOS15-${VERSION}.zip"
mkdir -p dist
rm -f "$ZIP"
ditto -c -k --keepParent "$APP_PATH" "$ZIP"
SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
echo "✓ 打包完成: $ZIP ($(du -h "$ZIP" | cut -f1)) SHA256=$SHA"

api() { # api METHOD URL [JSON_FILE]
  if [ $# -ge 3 ]; then
    curl -s -X "$1" -H "Authorization: token $TOKEN" -H "Accept: application/vnd.github+json" \
      -H "Content-Type: application/json" --data @"$3" "$2"
  else
    curl -s -X "$1" -H "Authorization: token $TOKEN" -H "Accept: application/vnd.github+json" "$2"
  fi
}

# 若已有同名 release 则先删除，保证可重复运行
RID="$(api GET "https://api.github.com/repos/$OWNER_REPO/releases/tags/$TAG" | /usr/bin/python3 -c 'import json,sys;d=json.load(sys.stdin);print(d.get("id",""))')"
[ -n "$RID" ] && api DELETE "https://api.github.com/repos/$OWNER_REPO/releases/$RID" >/dev/null && echo "• 已删除旧 Release $TAG"

BODY_FILE="$(mktemp)"
cat > "$BODY_FILE" <<EOF
## Compositor macOS15 移植版 v${VERSION}

- 安装包: \`Compositor-macOS15-${VERSION}.zip\`
- SHA256: \`${SHA}\`
- 最低系统: macOS 15.0+（Intel / Apple Silicon）
- 解压后拖入「应用程序」；adhoc 签名，首次打开请右键 → 打开
EOF
RESP="$(api POST "https://api.github.com/repos/$OWNER_REPO/releases" "$BODY_FILE")"
RID="$(printf '%s' "$RESP" | /usr/bin/python3 -c 'import json,sys;d=json.load(sys.stdin);print(d.get("id",""))')"
rm -f "$BODY_FILE"
[ -n "$RID" ] || { echo "✗ 创建 Release 失败: $RESP"; exit 1; }
echo "✓ Release 已创建 (id=$RID)"

# 上传 zip 附件（直连，避开代理对大文件 multipart 的干扰）
if curl -s --noproxy '*' -X POST \
  -H "Authorization: token $TOKEN" -H "Accept: application/vnd.github+json" \
  -H "Content-Type: application/zip" \
  --data-binary @"$ZIP" \
  "https://uploads.github.com/repos/$OWNER_REPO/releases/$RID/assets?name=Compositor-macOS15-${VERSION}.zip" \
  | grep -q browser_download_url; then
  echo "✓ 安装包已上传: https://github.com/$OWNER_REPO/releases/tag/$TAG"
else
  echo "✗ 安装包上传失败"; exit 1
fi
