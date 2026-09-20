#!/usr/bin/env bash
#
# upload-gitee.sh — 把安装包上传到 Gitee Release（在国内本机运行）
#
# 为什么需要它：
#   GitHub Actions 海外 runner 往国内 Gitee 传大文件会被跨境链路掐死（实测 11MB 跑满 240s 零进展），
#   而 Gitee 官方 CLI（@gitee/gitee-cli）目前不支持传附件。所以在本机（国内）用 curl 直连 Gitee
#   attach_files 接口上传，建连仅 0.2s，是最可靠的方式。
#
# 用法：
#   ./scripts/upload-gitee.sh <tag> <file> [--force]
#
# 示例：
#   ./scripts/upload-gitee.sh 1.7.4-36 build/xzmj-mac-arm-1.7.4.zip
#   ./scripts/upload-gitee.sh 1.7.4-36 build/xzmj-mac-arm-1.7.4.zip --force   # 同名覆盖
#
# 前置：
#   1. Gitee 私人令牌（projects 权限）存于 ~/.config/gitee-token，权限 600，内容仅令牌本身
#   2. 该 tag 的 Release 元数据已由 GitHub Actions(sync-release-to-gitee) 自动建好
#
# 说明：令牌只从本地文件读取，不硬编码、不回显、不进仓库。
#       Gitee 是国内站点，curl 一律 --noproxy '*' 走直连，避免被本机代理绕远。

set -euo pipefail

OWNER="kuck007"
REPO="xzmj"
TOKEN_FILE="$HOME/.config/gitee-token"
API="https://gitee.com/api/v5/repos/${OWNER}/${REPO}"
CURL="curl --noproxy *"

TAG="${1:-}"
FILE="${2:-}"
FORCE="${3:-}"

if [[ -z "$TAG" || -z "$FILE" ]]; then
  echo "用法: $0 <tag> <file> [--force]"
  echo "示例: $0 1.7.4-36 build/xzmj-mac-arm-1.7.4.zip"
  exit 1
fi
if [[ ! -f "$FILE" ]]; then
  echo "❌ 文件不存在: $FILE"
  exit 1
fi
if [[ ! -f "$TOKEN_FILE" ]]; then
  echo "❌ 找不到令牌文件: $TOKEN_FILE"
  echo "   请在 Gitee「设置→私人令牌」生成 projects 权限令牌，写入该文件并 chmod 600"
  exit 1
fi

TOKEN="$(tr -d '[:space:]' < "$TOKEN_FILE")"
if [[ -z "$TOKEN" ]]; then
  echo "❌ 令牌文件为空: $TOKEN_FILE"
  exit 1
fi
NAME="$(basename "$FILE")"
SIZE="$(stat -f%z "$FILE")"

# 1) 按 tag 查 release 的数字 id
RELEASE_ID="$(curl --noproxy '*' -s --max-time 30 \
  "${API}/releases?per_page=100&access_token=${TOKEN}" \
  | python3 -c "
import sys, json
tag = sys.argv[1]
try:
    rows = json.load(sys.stdin)
except Exception:
    rows = []
print(next((str(r['id']) for r in rows if r.get('tag_name') == tag), ''))
" "$TAG")"

if [[ -z "$RELEASE_ID" ]]; then
  echo "❌ Gitee 上找不到 tag=${TAG} 的 Release"
  echo "   可能 GitHub Actions 还没同步建好元数据，稍等 1-2 分钟后重试"
  exit 1
fi
echo "• Release: ${TAG} (id=${RELEASE_ID})"

# 2) 查同名附件（幂等：默认跳过，--force 先删后传）
EXISTING_ID="$(curl --noproxy '*' -s --max-time 30 \
  "${API}/releases/${RELEASE_ID}/attach_files?per_page=100&access_token=${TOKEN}" \
  | python3 -c "
import sys, json
name = sys.argv[1]
try:
    rows = json.load(sys.stdin)
except Exception:
    rows = []
print(next((str(a['id']) for a in rows if a.get('name') == name), ''))
" "$NAME")"

if [[ -n "$EXISTING_ID" ]]; then
  if [[ "$FORCE" == "--force" ]]; then
    echo "• 发现同名附件 id=${EXISTING_ID}，--force 覆盖：先删除旧附件"
    curl --noproxy '*' -s --max-time 30 -X DELETE \
      "${API}/releases/${RELEASE_ID}/attach_files/${EXISTING_ID}?access_token=${TOKEN}" \
      -o /dev/null -w "  删除状态: %{http_code}\n"
  else
    echo "ℹ️  附件「${NAME}」已存在，跳过。如需覆盖请加 --force"
    exit 0
  fi
fi

# 3) multipart 上传（access_token 作为表单字段，不在 URL 里）
echo "• 上传中: ${NAME} (${SIZE} 字节) ..."
RESP="$(curl --noproxy '*' -s --max-time 600 -X POST \
  "${API}/releases/${RELEASE_ID}/attach_files" \
  -F "access_token=${TOKEN}" \
  -F "file=@${FILE}")"

echo "$RESP" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print('❌ 上传响应无法解析（可能是网络/认证错误）')
    sys.exit(1)
url = d.get('browser_download_url')
if url:
    print('✅ 上传成功:', url)
else:
    print('❌ 上传失败:', json.dumps(d, ensure_ascii=False)[:300])
    sys.exit(1)
"

echo "• 友好下载地址: https://gitee.com/${OWNER}/${REPO}/releases/download/${TAG}/${NAME}"
