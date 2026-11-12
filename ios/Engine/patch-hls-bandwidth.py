# SPDX-License-Identifier: AGPL-3.0-only
# Applied only on the guarded GitHub/macOS build.
from pathlib import Path
import sys

path = Path(sys.argv[1]) / "internal/protocol/hls/fetcher.go"
source = path.read_text()
hooks = [
    ('reader := &stallReader{rc: resp.Body, timeout: f.timeout()}',
     'reader := base.YunxNativeHTTPReader(run.ctx, &stallReader{rc: resp.Body, timeout: f.timeout()}, nil)'),
    ('io.ReadAll(io.LimitReader(resp.Body, 1<<20))',
     'io.ReadAll(io.LimitReader(base.YunxNativeHTTPReader(run.ctx, &stallReader{rc: resp.Body, timeout: f.timeout()}, nil), 1<<20))'),
    ('io.ReadAll(io.LimitReader(&stallReader{rc: resp.Body, timeout: f.timeout()}, maxPlaylistSize))',
     'io.ReadAll(io.LimitReader(base.YunxNativeHTTPReader(ctx, &stallReader{rc: resp.Body, timeout: f.timeout()}, nil), maxPlaylistSize))'),
]
for old, new in hooks:
    if source.count(old) != 1:
        raise SystemExit("Pinned HLS bandwidth hook changed: " + old[:100])
    source = source.replace(old, new)
path.write_text(source)
