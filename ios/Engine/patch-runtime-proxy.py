# SPDX-License-Identifier: AGPL-3.0-only
# Executed only inside the guarded macOS engine build, never on the proxy server.
from pathlib import Path
import sys

root = Path(sys.argv[1])
model = root / "pkg/base/model.go"
source = model.read_text()
signature = "func (cfg *DownloaderProxyConfig) ToHandler() func(r *http.Request) (*url.URL, error) {"
if source.count(signature) != 1:
    raise SystemExit("Pinned proxy hook was not found; refusing an unverified engine patch")
source = source.replace(signature, signature + "\n\tif handler, enabled := RuntimeProxyOverride(); enabled { return handler }")
model.write_text(source)
