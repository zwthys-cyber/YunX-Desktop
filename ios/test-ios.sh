#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-only
set -euo pipefail
if [ "$(uname -s)" != Darwin ]; then
  echo "仅在本地 Mac 或 GitHub macOS runner 运行 iOS 测试。" >&2
  exit 1
fi
cd -- "$(dirname -- "$0")"
mkdir -p build
test_stage="${1:-all}"
case "$test_stage" in build|run|all) ;; *) echo "Usage: test-ios.sh [build|run|all]" >&2; exit 2 ;; esac
build_tests() {
# Generate interoperability vectors using the desktop's Java crypto implementation.
command -v java >/dev/null || { echo "需要 JDK 17+ 生成备份兼容测试向量。" >&2; exit 1; }
java Fixtures/BackupFixture.java > Tests/backup-vectors.json
java Fixtures/ILanzouFixture.java > Tests/ilanzou-vectors.json
java Fixtures/C139Fixture.java > Tests/c139-vectors.json
java Fixtures/Pan115Fixture.java > Tests/pan115-vectors.json
java Fixtures/LanzouFixture.java > Tests/lanzou-vectors.json
swift Fixtures/GenerateAppIcon.swift Artwork/AppIconSource.png Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png
xcodegen generate
simulator_info="$(python3 - <<'PY'
import json, subprocess
devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "--json"]))["devices"]
runtimes = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "runtimes", "--json"]))["runtimes"]
for runtime, group in devices.items():
    if "iOS" not in runtime:
        continue
    for device in group:
        if device.get("isAvailable") and device["name"].startswith("iPhone"):
            bundle = next(item["bundlePath"] for item in runtimes if item["identifier"] == runtime)
            print(device["udid"])
            print(bundle + "/Contents/Resources/RuntimeRoot/System/Cryptexes/OS/usr/lib/swift")
            raise SystemExit(0)
raise SystemExit("No available iPhone runtime")
PY
)"
simulator_id="${simulator_info%%$'\n'*}"
simulator_swift="${simulator_info#*$'\n'}"
test -n "$simulator_id" || { echo "找不到可用的 iPhone 模拟器。" >&2; exit 1; }
printf '%s\n' "$simulator_id" > build/simulator-id.txt
xcrun simctl bootstatus "$simulator_id" -b
# Apple's Xcode 16.4/iOS 18.5 simulator workaround; device deployment stays iOS 17.
# https://developer.apple.com/forums/thread/785964
printf 'Simulator Swift runtime fallback: %s\n' "$simulator_swift"
# A dylib can live only in dyld's shared cache, so do not gate this on -f.
python3 - "$simulator_swift" <<'PY'
import sys
import xml.etree.ElementTree as ET
path = "YunX.xcodeproj/xcshareddata/xcschemes/YunX.xcscheme"
tree = ET.parse(path)
for name in ("LaunchAction", "TestAction"):
    action = tree.getroot().find(name)
    if action is None:
        raise SystemExit("Generated Xcode scheme is missing " + name)
    if name == "TestAction":
        action.set("shouldUseLaunchSchemeArgsEnv", "NO")
    variables = action.find("EnvironmentVariables")
    if variables is None:
        variables = ET.SubElement(action, "EnvironmentVariables")
    ET.SubElement(variables, "EnvironmentVariable", key="DYLD_FALLBACK_LIBRARY_PATH", value=sys.argv[1], isEnabled="YES")
tree.write(path, encoding="UTF-8", xml_declaration=True)
PY
xcodebuild -project YunX.xcodeproj -scheme YunX -configuration Debug \
  -destination "platform=iOS Simulator,id=$simulator_id" \
  -derivedDataPath "$PWD/build/SimulatorDerivedData" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build-for-testing
# Security.framework needs a signed simulator host with an application identity.
# This is a temporary simulator signature, independent of any Apple account.
simulator_app="$PWD/build/SimulatorDerivedData/Build/Products/Debug-iphonesimulator/YunX.app"
python3 - <<'PY'
import plistlib
from pathlib import Path
value = plistlib.loads(Path("TrollStore.entitlements").read_bytes())
value["get-task-allow"] = True
value["com.apple.developer.team-identifier"] = "YUNXLOCAL"
Path("build/Simulator.entitlements").write_bytes(plistlib.dumps(value))
PY
while IFS= read -r -d '' library; do
  /usr/bin/codesign --force --sign - --timestamp=none "$library"
done < <(find "$simulator_app" -type f -name '*.dylib' -print0)
for test_bundle in "$simulator_app"/PlugIns/*.xctest; do
  if [ -d "$test_bundle" ]; then /usr/bin/codesign --force --sign - --timestamp=none "$test_bundle"; fi
done
/usr/bin/codesign --force --sign - --timestamp=none --generate-entitlement-der --entitlements ShareExtension/TrollStore.entitlements "$simulator_app/PlugIns/YunXShare.appex"
/usr/bin/codesign --force --sign - --timestamp=none --generate-entitlement-der --entitlements build/Simulator.entitlements "$simulator_app"
/usr/bin/codesign --verify --strict "$simulator_app"
}
run_tests() {
simulator_id="$(cat build/simulator-id.txt)"
xcodebuild -project YunX.xcodeproj -scheme YunX -configuration Debug \
  -destination "platform=iOS Simulator,id=$simulator_id" \
  -derivedDataPath "$PWD/build/SimulatorDerivedData" \
  -resultBundlePath "$PWD/build/TestResults.xcresult" \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 60 -maximum-test-execution-time-allowance 120 \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO test-without-building
# Decode an actual iOS-encrypted synthetic fixture with the independent desktop JCE code.
app_data="$(xcrun simctl get_app_container "$simulator_id" io.github.zwthys.yunx data)"
backup_fixture="$app_data/Documents/BackupInterop/ios-export-v2.yunx"
java Fixtures/BackupFixture.java verify "$backup_fixture"
rm -f -- "$backup_fixture"
}
if [ "$test_stage" != run ]; then build_tests; fi
if [ "$test_stage" != build ]; then run_tests; fi
