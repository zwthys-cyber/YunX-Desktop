# SPDX-License-Identifier: AGPL-3.0-only
# Run only by the guarded GitHub/macOS engine build, never on this server.
from pathlib import Path
import sys

path = Path(sys.argv[1]) / "internal/protocol/http/fetcher.go"
source = path.read_text()
start = "func (f *Fetcher) stopPrefetchAndCopyData() int64 {"
end = "// cleanupPrefetchFile closes and removes the prefetch temporary file"
if source.count(start) != 1 or source.count(end) != 1:
    raise SystemExit("Pinned prefetch copy hook changed; refusing to patch")
begin = source.index(start)
finish = source.index(end, begin)
source = source[:begin] + '''func (f *Fetcher) stopPrefetchAndCopyData() int64 {
    f.stopPrefetch()
    defer f.cleanupPrefetchFile()
    prefetched := f.prefetchSize.Load()
    if prefetched == 0 { return 0 }
    if f.prefetchFile == nil || f.file == nil {
        f.prefetchErr = io.ErrUnexpectedEOF
        return 0
    }
    if _, err := f.prefetchFile.Seek(0, io.SeekStart); err != nil {
        f.prefetchErr = err
        return 0
    }
    buf := make([]byte, 32*1024)
    var copied int64
    for copied < prefetched {
        wanted := min(int64(len(buf)), prefetched-copied)
        n, readErr := f.prefetchFile.Read(buf[:wanted])
        if n > 0 {
            written, writeErr := f.file.WriteAt(buf[:n], copied)
            copied += int64(written)
            if writeErr != nil { f.prefetchErr = writeErr; return copied }
            if written != n { f.prefetchErr = io.ErrShortWrite; return copied }
        }
        if readErr != nil {
            if copied != prefetched {
                if readErr == io.EOF { readErr = io.ErrUnexpectedEOF }
                f.prefetchErr = readErr
            }
            return copied
        }
        if n == 0 { f.prefetchErr = io.ErrNoProgress; return copied }
    }
    return copied
}

''' + source[finish:]

# An unknown-length response must not become complete after a failed disk copy.
old = "if knownSize && prefetched != f.meta.Res.Size {"
if source.count(old) != 1:
    raise SystemExit("Pinned resolve fallback completion hook changed")
source = source.replace(old, "if f.prefetchErr != nil || (knownSize && prefetched != f.meta.Res.Size) {")

# Pause must rewind even when zero bytes were copied; retaining the speculative
# Range begin in that case would skip bytes on the next Start.
old = '''\t\tif prefetched > 0 {
\t\t\tf.resolveDataPos.Store(prefetched)
\t\t\tf.connMu.Lock()
\t\t\tif len(f.connections) == 1 {
\t\t\t\tconn := f.connections[0]
\t\t\t\tif conn != nil && conn.ID == 0 && conn.Chunk != nil && !conn.Completed {
\t\t\t\t\tconn.Chunk.Begin = prefetched
\t\t\t\t\tif f.knownSize() > 0 {
\t\t\t\t\t\tconn.Chunk.setEnd(f.knownSize() - 1)
\t\t\t\t\t} else {
\t\t\t\t\t\tconn.Chunk.End = nil
\t\t\t\t\t}
\t\t\t\t\tconn.Chunk.Downloaded = 0
\t\t\t\t\tconn.Downloaded = prefetched
\t\t\t\t}
\t\t\t}
\t\t\tf.connMu.Unlock()
\t\t}'''
if source.count(old) != 1:
    raise SystemExit("Pinned prefetch pause hook changed")
source = source.replace(old, "\n".join(line[1:] for line in old.splitlines()[1:-1]))
path.write_text(source)
