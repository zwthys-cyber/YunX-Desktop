#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-only
# 用户授权在本地 Mac 或 GitHub Actions 的 macOS runner 构建。
set -euo pipefail
if [ "$(uname -s)" != Darwin ]; then
  echo "需要 macOS 和完整 Xcode；不在当前代理服务器构建。" >&2
  exit 1
fi
if [ -n "${CI:-}" ] && [ "${GITHUB_ACTIONS:-}" != true ]; then
  echo "仅允许本地 Mac 或已授权的 GitHub Actions 构建。" >&2
  exit 1
fi
cd -- "$(dirname -- "$0")"
command -v xcodegen >/dev/null || { echo "请先安装 XcodeGen。" >&2; exit 1; }
xcrun --find xcodebuild >/dev/null
xcodegen generate
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/yunx-build.XXXXXXXX")"
trap 'rm -rf -- "$build_dir"' EXIT
xcodebuild -project YunX.xcodeproj -scheme YunX -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath "$build_dir/DerivedData" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
app="$build_dir/DerivedData/Build/Products/Release-iphoneos/YunX.app"
test -d "$app" || { echo "找不到设备版 YunX.app" >&2; exit 1; }
/usr/bin/codesign --force --sign - --timestamp=none \
  --entitlements TrollStore.entitlements --generate-entitlement-der "$app"
/usr/bin/codesign --verify --strict "$app"
xcrun lipo "$app/YunX" -verify_arch arm64
/usr/libexec/PlistBuddy -c "Print :MinimumOSVersion" "$app/Info.plist"
mkdir -p "$build_dir/package/Payload"
ditto "$app" "$build_dir/package/Payload/YunX.app"
mkdir -p build
ipa="$PWD/build/YunX-iOS17-TrollStore-dev.ipa"
rm -f -- "$ipa"
(cd "$build_dir/package" && /usr/bin/zip -qry "$ipa" Payload)
/usr/bin/unzip -tq "$ipa"
shasum -a 256 "$ipa" > "$ipa.sha256"
echo "开发版 IPA：$ipa"
echo "编译和打包通过不代表已完成真机安装或全部功能移植。"
