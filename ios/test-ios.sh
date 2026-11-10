#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-only
set -euo pipefail
if [ "$(uname -s)" != Darwin ]; then
  echo "仅在本地 Mac 或 GitHub macOS runner 运行 iOS 测试。" >&2
  exit 1
fi
cd -- "$(dirname -- "$0")"
# Generate interoperability vectors using the desktop's Java crypto implementation.
command -v java >/dev/null || { echo "需要 JDK 17+ 生成备份兼容测试向量。" >&2; exit 1; }
java Fixtures/BackupFixture.java > Tests/backup-vectors.json
java Fixtures/ILanzouFixture.java > Tests/ilanzou-vectors.json
java Fixtures/C139Fixture.java > Tests/c139-vectors.json
xcodegen generate
mkdir -p build
simulator_id="$(xcrun simctl list devices available --json | python3 -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
ids = [device["udid"] for runtime, group in devices.items() if "iOS" in runtime
       for device in group if device.get("isAvailable") and device["name"].startswith("iPhone")]
print(ids[0] if ids else "")
')"
test -n "$simulator_id" || { echo "找不到可用的 iPhone 模拟器。" >&2; exit 1; }
test_dir="$(mktemp -d -t yunx-tests)"
trap 'rm -rf -- "$test_dir"' EXIT
xcrun simctl bootstatus "$simulator_id" -b
xcodebuild -project YunX.xcodeproj -scheme YunX -configuration Debug \
  -destination "platform=iOS Simulator,id=$simulator_id" \
  -derivedDataPath "$test_dir/DerivedData" \
  -resultBundlePath "$PWD/build/TestResults.xcresult" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO test
# Decode an actual iOS-encrypted synthetic fixture with the independent desktop JCE code.
app_data="$(xcrun simctl get_app_container "$simulator_id" io.github.zwthys.yunx data)"
backup_fixture="$app_data/Documents/BackupInterop/ios-export-v2.yunx"
java Fixtures/BackupFixture.java verify "$backup_fixture"
rm -f -- "$backup_fixture"
