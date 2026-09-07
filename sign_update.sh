#!/bin/bash
# Sparkle 更新包签名脚本
# 用法: ./sign_update.sh <zip文件路径>
# 输出: Ed25519 签名 (base64)，填入 appcast.xml 的 sparkle:edSignature

PRIVATE_KEY="$(dirname "$0")/sparkle_ed25519_private.pem"
ZIP_FILE="$1"

if [ -z "$ZIP_FILE" ]; then
    echo "用法: $0 <zip文件路径>"
    exit 1
fi

if [ ! -f "$ZIP_FILE" ]; then
    echo "错误: 文件不存在: $ZIP_FILE"
    exit 1
fi

if [ ! -f "$PRIVATE_KEY" ]; then
    echo "错误: 私钥文件不存在: $PRIVATE_KEY"
    exit 1
fi

# 用 OpenSSL 对 zip 文件进行 Ed25519 签名（raw 模式，Ed25519 内部自行哈希）
openssl pkeyutl -sign -inkey "$PRIVATE_KEY" -rawin -in "$ZIP_FILE" | base64
