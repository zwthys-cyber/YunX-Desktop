# SPDX-License-Identifier: AGPL-3.0-only
# Applied only on the guarded GitHub/macOS build.
from pathlib import Path
import sys

root = Path(sys.argv[1]) / "internal/protocol/http"
path = root / "fetcher.go"
source = path.read_text()

def replace_once(old, new):
    global source
    if source.count(old) != 1:
        raise SystemExit("Pinned piece integrity hook changed: " + old[:100])
    source = source.replace(old, new)

replace_once("type Fetcher struct {", "type Fetcher struct {\n    yunxPieces yunxPieceLedger")
replace_once("f.file.WriteAt(buf[:n], copied)", "f.yunxWriteAt(buf[:n], copied, -1)")
replace_once("_, writeErr := f.file.WriteAt(data, writeOffset)", "_, writeErr := f.yunxWriteAt(data, writeOffset, conn.ID)")
replace_once("_, writeErr := f.file.WriteAt(buf[:n], writeOffset)", "_, writeErr := f.yunxWriteAt(buf[:n], writeOffset, conn.ID)")
replace_once("f.prepareFullRedownload()", "f.prepareFullRedownload()\n            f.yunxResetPieces()")
replace_once("// Open or create target file first (needed for prefetch copy)", "if f.yunxUsesPieces() && (state == statePaused || state == stateError) { f.yunxPieces.restored = true }\n    if err := f.yunxValidateRestoredPieces(); err != nil { return err }\n\n    // Open or create target file first (needed for prefetch copy)")
replace_once("func (f *Fetcher) verifyChecksum() error {\n", "func (f *Fetcher) verifyChecksum() error {\n    if err := f.yunxVerifyPieces(true); err != nil {\n        if errors.Is(err, errYunxPieceMismatch) { f.checksumFailed.Store(true) }\n        return err\n    }\n")
path.write_text(source)

path = root / "fetcher_manager.go"
source = path.read_text()
replace_once("type fetcherData struct {", "type fetcherData struct {\n    YunxPieces *yunxPieceSnapshot `json:\",omitempty\"`")
# Progress is captured first: write hashing precedes progress publication. A
# later digest snapshot can include extra committed bytes, never fewer bytes.
replace_once("return &fetcherData{", "var pieces *yunxPieceSnapshot\n    if _f.yunxUsesPieces() {\n        pieces, err = _f.yunxPieces.snapshot()\n        if err != nil { return nil, err }\n    }\n    return &fetcherData{\n        YunxPieces: pieces,")
replace_once("return fetcher\n", "fetcher.yunxRestorePieces(fd.YunxPieces)\n        return fetcher\n")
path.write_text(source)
