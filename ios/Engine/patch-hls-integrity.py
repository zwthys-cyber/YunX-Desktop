# SPDX-License-Identifier: AGPL-3.0-only
# Applied only on the guarded GitHub/macOS build.
from pathlib import Path
import sys

root = Path(sys.argv[1]) / "internal/protocol/hls"
path = root / "fetcher.go"
source = path.read_text()

def replace_once(old, new):
    global source
    if source.count(old) != 1:
        raise SystemExit("Pinned HLS integrity hook changed: " + old[:100])
    source = source.replace(old, new)

replace_once("type hlsRun struct {", "type hlsRun struct {\n    yunxSHA256 map[int64]string")
replace_once('''\t\t\tif info, err := os.Stat(segmentPath(run.tempDir, int64(i))); err == nil && info.Size() == size {
\t\t\t\trun.baseBytes += size
\t\t\t\trun.baseDone++
\t\t\t\tcontinue
\t\t\t}''', '''            if err := yunxCheckHLSSegment(run, int64(i)); err == nil {
                run.baseBytes += size
                run.baseDone++
                continue
            } else if !errors.Is(err, errYunxHLSIntegrity) { return err }
            delete(run.journal, int64(i))
            delete(run.yunxSHA256, int64(i))''')
replace_once("data, err := os.ReadFile(segmentPath(run.tempDir, int64(i)))", "data, err := yunxReadVerifiedHLSSegment(run, int64(i))")
replace_once('''\tif err := os.WriteFile(partPath, data, 0666); err != nil {
\t\treturn err
\t}''', '''    digest, err := yunxWriteHLSSegment(partPath, data)
    if err != nil { return err }''')
replace_once("run.journal[idx] = int64(len(data))", "run.journal[idx] = int64(len(data))\n    if run.yunxSHA256 == nil { run.yunxSHA256 = make(map[int64]string) }\n    run.yunxSHA256[idx] = digest")
replace_once("\tif err := out.Close(); err != nil {", "\tif err := out.Sync(); err != nil {\n        out.Close(); os.Remove(partPath); return err\n    }\n\tif err := out.Close(); err != nil {")
old = '''\tif err := os.Remove(target); err != nil && !os.IsNotExist(err) {
\t\tos.Remove(partPath)
\t\treturn err
\t}
'''
replace_once(old, "    // Darwin atomically replaces the old output; preserve it if rename fails.\n")
path.write_text(source)

path = root / "journal.go"
source = path.read_text()
replace_once("type journalFile struct {", 'type journalFile struct {\n    SHA256 map[string]string `json:"sha256,omitempty"`')
replace_once("for key, size := range file.Sizes {", "if len(file.SHA256) == 0 { return nil } // Old journals cannot prove written contents.\n    for key, size := range file.Sizes {")
replace_once("run.journal[idx] = size", '''        digest, decodeErr := hex.DecodeString(file.SHA256[key])
        if decodeErr != nil || len(digest) != 32 { continue }
        run.journal[idx] = size
        if run.yunxSHA256 == nil { run.yunxSHA256 = make(map[int64]string) }
        run.yunxSHA256[idx] = file.SHA256[key]''')
replace_once("file := journalFile{", "file := journalFile{\n        SHA256: make(map[string]string, len(run.journal)),")
replace_once("file.Sizes[strconv.FormatInt(idx, 10)] = size", "file.Sizes[strconv.FormatInt(idx, 10)] = size\n        file.SHA256[strconv.FormatInt(idx, 10)] = run.yunxSHA256[idx]")
path.write_text(source)

# Existing merge/recovery fixtures must create genuinely verified segments.
# Keep all their original assertions; size-only legacy records are covered
# separately by the new fail-closed compatibility test.
path = root / "staging_test.go"
source = path.read_text()
replace_once('os.WriteFile(segmentPath(run.tempDir, 0), []byte("AAAA"), 0666)', 'storeSegment(run, 0, []byte("AAAA"))')
replace_once('os.WriteFile(segmentPath(run.tempDir, 1), []byte("BBBB"), 0666)', 'storeSegment(run, 1, []byte("BBBB"))')
replace_once('journal:     map[int64]int64{0: 4, 1: 4},', 'journal:     make(map[int64]int64),\n        tempDir: tempDir,')
replace_once('''\tif err := saveJournal(jr); err != nil {
\t\tt.Fatal(err)
\t}
''', '')
replace_once('os.WriteFile(segmentPath(tempDir, int64(i)), []byte("DATA"), 0666)', 'storeSegment(jr, int64(i), []byte("DATA"))')
path.write_text(source)
