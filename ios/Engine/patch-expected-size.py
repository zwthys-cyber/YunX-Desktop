# SPDX-License-Identifier: AGPL-3.0-only
# Applied only inside the guarded GitHub/macOS build.
from pathlib import Path
import sys

path = Path(sys.argv[1]) / "internal/protocol/http/fetcher.go"
source = path.read_text()
marker = "func (f *Fetcher) verifyChecksum() error {\n"
if source.count(marker) != 1:
    raise SystemExit("Pinned final file verification hook changed")
source = source.replace(marker, marker + '''    if f.meta != nil && f.meta.Req != nil {
        if kind := f.meta.Req.Labels["yunxExpectedMedia"]; kind != "" {
            if kind != "zip" || f.meta.Opts == nil || f.meta.Res == nil || len(f.meta.Res.Files) != 1 || f.meta.Res.Files[0] == nil { return errors.New("invalid expected file format") }
            file, err := os.Open(f.meta.SingleFilepath())
            if err != nil { return err }
            var prefix [4]byte
            _, readErr := io.ReadFull(file, prefix[:])
            file.Close()
            if readErr != nil || (prefix != [4]byte{0x50, 0x4b, 0x03, 0x04} && prefix != [4]byte{0x50, 0x4b, 0x05, 0x06}) {
                f.checksumFailed.Store(true)
                return errors.New("downloaded response is not a ZIP file")
            }
        }
        if raw := f.meta.Req.Labels["yunxExpectedSize"]; raw != "" {
            expected, err := strconv.ParseInt(raw, 10, 64)
            if err != nil || expected <= 0 || f.meta.Opts == nil || f.meta.Res == nil || len(f.meta.Res.Files) == 0 || f.meta.Res.Files[0] == nil {
                return errors.New("invalid expected file size")
            }
            info, err := os.Stat(f.meta.SingleFilepath())
            if err != nil { return err }
            if info.Size() != expected {
                f.checksumFailed.Store(true)
                return errors.New("downloaded file size differs from platform metadata")
            }
        }
    }
''')
path.write_text(source)
