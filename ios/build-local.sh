#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-only
# 只供用户在自己的 Mac 上主动运行；不接入 GitHub Actions。
set -euo pipefail
if [ "$(uname -s)" != Darwin ] || [ -n "${CI:-}" ] || [ -n "${GITHUB_ACTIONS:-}" ]; then
  echo "仅允许在本地 Mac 交互环境构建，不支持服务器或 CI。" >&2
  exit 1
fi
cd -- "$(dirname -- "$0")"
command -v xcodegen >/dev/null || { echo "请先在 Mac 安装 XcodeGen。" >&2; exit 1; }
xcrun --find xcodebuild >/dev/null
xcodegen generate
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/yunx-local.XXXXXXXX")"
trap 'rm -rf -- "$build_dir"' EXIT
xcodebuild -project YunX.xcodeproj -scheme YunX -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath "$build_dir/DerivedData" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
app="$build_dir/DerivedData/Build/Products/Release-iphoneos/YunX.app"
test -d "$app" || { echo "找不到设备版 YunX.app" >&2; exit 1; }
mkdir -p "$build_dir/package/Payload"
ditto "$app" "$build_dir/package/Payload/YunX.app"
mkdir -p build
ipa="$PWD/build/YunX-iOS17-unsigned.ipa"
# 删除旧产物，防止 zip 更新模式残留上次构建的文件。
rm -f -- "$ipa"
(cd "$build_dir/package" && /usr/bin/zip -qry "$ipa" Payload)
echo "未签名 IPA：$ipa"
echo "此为移植中的开发版本。能否由 TrollStore 安装及运行，须在设备本地验证。"
