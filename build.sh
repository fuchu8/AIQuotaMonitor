#!/bin/bash
# 构建并打包 AI Quota Monitor 为可运行的 .app
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP_NAME="AI Quota Monitor"
APP="dist/${APP_NAME}.app"

echo "==> swift build -c ${CONFIG}"
swift build -c "${CONFIG}"

BIN=".build/${CONFIG}/AIQuotaMonitor"
[ -x "${BIN}" ] || { echo "二进制不存在：${BIN}"; exit 1; }

echo "==> 组装 ${APP}"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp "${BIN}" "${APP}/Contents/MacOS/AIQuotaMonitor"
cp "Resources/Info.plist" "${APP}/Contents/Info.plist"
# 菜单栏圆形猫图标（含 @2x / @3x）
cp Resources/StatusBarCat*.png "${APP}/Contents/Resources/"
printf 'APPL????' > "${APP}/Contents/PkgInfo"

echo "==> 本地签名（ad-hoc）"
codesign --force --sign - --timestamp=none "${APP}" 2>&1 | sed 's/^/    /'
xattr -cr "${APP}" 2>/dev/null || true

echo "==> 校验"
codesign --verify --deep --strict "${APP}" && echo "    签名校验通过"
/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "${APP}/Contents/Info.plist" | sed 's/^/    bundle id: /'

echo ""
echo "完成：$(pwd)/${APP}"
