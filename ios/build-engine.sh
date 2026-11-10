#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-only
set -euo pipefail
if [ "$(uname -s)" != Darwin ]; then
  echo "仅在用户的 Mac 或 GitHub macOS runner 构建 iOS 引擎。" >&2
  exit 1
fi
cd -- "$(dirname -- "$0")"
engine_root="$PWD"
source Engine/upstream.env
engine_temp="$(mktemp -d "${TMPDIR:-/tmp}/yunx-engine.XXXXXXXX")"
trap 'rm -rf -- "$engine_temp"' EXIT
engine_retry() {
  local engine_retry_attempt=1 engine_retry_status
  while true; do
    if [ "$1" = gomobile ] && [ "${2:-}" = bind ]; then
      rm -rf -- "$engine_root/Frameworks/Yunxengine.xcframework"
    fi
    if "$@" 2>&1 | tee "$engine_temp/network-attempt.log"; then
      return 0
    else
      engine_retry_status=$?
    fi
    if [ "$engine_retry_attempt" -ge 3 ] || ! grep -Eqi 'operation timed out|i/o timeout|TLS handshake timeout|connection reset by peer|temporary failure|unexpected EOF|502 Bad Gateway|503 Service Unavailable|504 Gateway Timeout' "$engine_temp/network-attempt.log"; then
      return "$engine_retry_status"
    fi
    printf 'Retrying transient Go/network failure; next attempt %d/3\n' "$((engine_retry_attempt + 1))"
    sleep "$((engine_retry_attempt * 5))"
    engine_retry_attempt=$((engine_retry_attempt + 1))
  done
}
mkdir -p Frameworks build
# Fetch the exact source revision without compiling anything on the proxy server.
git init "$engine_temp/gopeed"
git -C "$engine_temp/gopeed" remote add origin https://github.com/GopeedLab/gopeed.git
engine_retry git -C "$engine_temp/gopeed" fetch --depth=1 origin "$GOPEED_REV"
git -C "$engine_temp/gopeed" checkout --detach FETCH_HEAD
mkdir -p "$engine_temp/gopeed/bind/yunxengine"
cp Engine/mobile.go "$engine_temp/gopeed/bind/yunxengine/main.go"
cp Engine/runtime_proxy.go "$engine_temp/gopeed/pkg/base/yunx_runtime_proxy.go"
cp Engine/runtime_proxy_test.go "$engine_temp/gopeed/pkg/base/yunx_runtime_proxy_test.go"
cp Engine/runtime_scheduler.go "$engine_temp/gopeed/pkg/base/yunx_runtime_scheduler.go"
cp Engine/runtime_scheduler_test.go "$engine_temp/gopeed/pkg/base/yunx_runtime_scheduler_test.go"
cp Engine/downloader_scheduler.go "$engine_temp/gopeed/pkg/download/yunx_scheduler.go"
cp Engine/rest_storage.go "$engine_temp/gopeed/pkg/rest/yunx_storage.go"
python3 Engine/patch-runtime-proxy.py "$engine_temp/gopeed"
python3 Engine/patch-scheduler.py "$engine_temp/gopeed"
cd "$engine_temp/gopeed"
export PATH="$(go env GOPATH)/bin:$PATH"
engine_retry go install "golang.org/x/mobile/cmd/gomobile@$MOBILE_REV"
engine_retry go get -tool "golang.org/x/mobile/cmd/gobind@$MOBILE_REV"
# The pinned mobile tool changes the module graph; finalize all checksums before tests/vendor.
engine_retry go mod tidy
go test -mod=mod -tags nosqlite -timeout 1m ./pkg/base -run '^TestYunx' -count=1
# These upstream end-to-end tests use local httptest servers, not live platforms.
go test -mod=mod -tags nosqlite -timeout 3m ./internal/protocol/hls -run '^TestFetcherE2E_' -count=1
engine_retry gomobile init
case "$(uname -m)" in
  arm64) engine_targets="ios/arm64,iossimulator/arm64" ;;
  x86_64) engine_targets="ios/arm64,iossimulator/amd64" ;;
  *) echo "不支持此 Mac 架构" >&2; exit 1 ;;
esac
engine_retry gomobile bind -target="$engine_targets" -iosversion=17.0 -tags=nosqlite \
  -ldflags='-w -s' -o "$engine_root/Frameworks/Yunxengine.xcframework" ./bind/yunxengine
# Preserve exact modified corresponding source and dependency locks with build artifacts.
{
  cat "$engine_root/Engine/upstream.env"
  go version
  xcodebuild -version
  uname -m
} > "$engine_root/build/engine-source-revisions.txt"
engine_retry go mod vendor
tar -czf "$engine_root/build/YunX-Gopeed-corresponding-source.tar.gz" \
  --exclude=.git --exclude='ui/flutter/build' .
