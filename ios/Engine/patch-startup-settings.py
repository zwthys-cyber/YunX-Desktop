# SPDX-License-Identifier: AGPL-3.0-only
# Executed only in the guarded GitHub/macOS build.
from pathlib import Path
import sys

path = Path(sys.argv[1]) / "pkg/download/downloader.go"
source = path.read_text()
marker = "\t// Move the legacy extra.downloadCategories list written by v2.0.0-beta\n"
if source.count(marker) != 1:
    raise SystemExit("Pinned startup configuration hook changed")
source = source.replace(marker, '''    if err := base.YunxApplyStartupDownloadPatch(d.cfg.DownloaderStoreConfig); err != nil { return err }
''' + marker)
path.write_text(source)
