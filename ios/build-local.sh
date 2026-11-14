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
swift Fixtures/GenerateAppIcon.swift Artwork/AppIconSource.png Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png
xcodegen generate
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/yunx-build.XXXXXXXX")"
trap 'rm -rf -- "$build_dir"' EXIT
xcodebuild -project YunX.xcodeproj -scheme YunX -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath "$build_dir/DerivedData" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
app="$build_dir/DerivedData/Build/Products/Release-iphoneos/YunX.app"
test -d "$app" || { echo "找不到设备版 YunX.app" >&2; exit 1; }
share_extension="$app/PlugIns/YunXShare.appex"
test -d "$share_extension" || { echo "找不到分享扩展，拒绝打包不完整的应用。" >&2; exit 1; }
package_style="${YUNX_PACKAGE_STYLE:-resign}"
case "$package_style" in resign|trollstore|both) ;; *) echo "未知打包方式：$package_style" >&2; exit 1 ;; esac
mkdir -p build

package_ipa() {
  local package_root="$1" package_name="$2"
  local package_ipa_path="$PWD/build/$package_name.ipa"
  rm -f -- "$package_ipa_path"
  (cd "$package_root" && /usr/bin/zip -qry "$package_ipa_path" Payload)
  /usr/bin/unzip -tq "$package_ipa_path"
  (cd build && shasum -a 256 "$package_name.ipa" > "$package_name.ipa.sha256")
  cat "$package_ipa_path.sha256"
}

if [ "$package_style" = resign ] || [ "$package_style" = both ]; then
  for variant in Resign Resign-Share; do
    variant_root="$build_dir/$variant"
    mkdir -p "$variant_root/Payload"
    ditto "$app" "$variant_root/Payload/YunX.app"
    variant_app="$variant_root/Payload/YunX.app"
    if [ "$variant" = Resign ]; then
      rm -rf -- "$variant_app/PlugIns"
      /usr/libexec/PlistBuddy -c 'Set :YunXInstallationStyle resign' "$variant_app/Info.plist"
      /usr/libexec/PlistBuddy -c 'Set :YunXShareExtensionEnabled false' "$variant_app/Info.plist"
    else
      /usr/libexec/PlistBuddy -c 'Set :YunXInstallationStyle resign-share' "$variant_app/Info.plist"
      /usr/bin/codesign --force --sign - --timestamp=none --entitlements Resign.entitlements --generate-entitlement-der "$variant_app/PlugIns/YunXShare.appex"
      /usr/bin/codesign --verify --strict "$variant_app/PlugIns/YunXShare.appex"
      xcrun lipo "$variant_app/PlugIns/YunXShare.appex/YunXShare" -verify_arch arm64
    fi
    # Neutral placeholder signatures carry no fixed application identifier,
    # Keychain group or App Group. The user's signing service must supply the
    # real profile and sign every retained executable before installation.
    /usr/bin/codesign --force --sign - --timestamp=none --entitlements Resign.entitlements --generate-entitlement-der "$variant_app"
    /usr/bin/codesign --verify --strict --deep "$variant_app"
    xcrun lipo "$variant_app/YunX" -verify_arch arm64
    /usr/bin/codesign -d --entitlements :- "$variant_app" > "$build_dir/$variant-entitlements.plist" 2>/dev/null
    if [ -s "$build_dir/$variant-entitlements.plist" ]; then
      /usr/bin/plutil -lint "$build_dir/$variant-entitlements.plist"
      for entitlement in application-identifier keychain-access-groups com.apple.security.application-groups; do
        if /usr/libexec/PlistBuddy -c "Print :$entitlement" "$build_dir/$variant-entitlements.plist" >/dev/null 2>&1; then
          echo "普通重签包包含固定权限，拒绝打包：$entitlement" >&2; exit 1
        fi
      done
    fi
    package_ipa "$variant_root" "YunX-iOS-$variant"
  done
fi

if [ "$package_style" = trollstore ] || [ "$package_style" = both ]; then
/usr/libexec/PlistBuddy -c 'Set :YunXInstallationStyle trollstore' "$app/Info.plist"
/usr/bin/codesign --force --sign - --timestamp=none \
  --entitlements ShareExtension/TrollStore.entitlements --generate-entitlement-der "$share_extension"
/usr/bin/codesign --verify --strict "$share_extension"
xcrun lipo "$share_extension/YunXShare" -verify_arch arm64
/usr/bin/codesign --force --sign - --timestamp=none \
  --entitlements TrollStore.entitlements --generate-entitlement-der "$app"
/usr/bin/codesign --verify --strict "$app"
xcrun lipo "$app/YunX" -verify_arch arm64
/usr/libexec/PlistBuddy -c "Print :MinimumOSVersion" "$app/Info.plist"
mkdir -p "$build_dir/package/Payload"
ditto "$app" "$build_dir/package/Payload/YunX.app"
package_ipa "$build_dir/package" YunX-iOS17-TrollStore-dev
fi
echo "开发包已输出到 build；普通重签包必须交给签名软件或服务签名后安装。"
echo "编译和打包通过不代表已完成真机安装或全部功能移植。"
