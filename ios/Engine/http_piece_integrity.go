// SPDX-License-Identifier: AGPL-3.0-only
package http

import (
    "bytes"
    "crypto/sha256"
    "errors"
    "hash"
    "io"
    "os"
    "sort"
    "sync"
)

const yunxPieceLimit = 262144
const yunxPieceBytes = 1024 * 1024

var errYunxPieceMismatch = errors.New("downloaded piece integrity differs; retry to download again")

type yunxPieceRecord struct {
    Offset int64
    Length int64
    SHA256 []byte
}

// This immutable snapshot is serialized with the same connection checkpoint.
// Pending hashes are copied as digests without interrupting the live SHA state.
type yunxPieceSnapshot struct {
    Version int
    Records []yunxPieceRecord
}

type yunxPieceWriter struct {
    offset int64
    length int64
    digest hash.Hash
}

type yunxPieceLedger struct {
    sync.Mutex
    records []yunxPieceRecord
    writers map[int]*yunxPieceWriter
    failure error
    restored bool
}

func (f *Fetcher) yunxUsesPieces() bool {
    return f.meta != nil && f.meta.Req != nil && f.meta.Req.Labels["yunxPieceIntegrity"] == "1"
}

func (l *yunxPieceLedger) appendRecord(record yunxPieceRecord) error {
    if len(l.records) >= yunxPieceLimit {
        l.failure = errors.New("piece integrity checkpoint limit reached")
        return l.failure
    }
    l.records = append(l.records, record)
    return nil
}

func (l *yunxPieceLedger) record(stream int, offset int64, data []byte) error {
    l.Lock()
    defer l.Unlock()
    if l.failure != nil { return l.failure }
    if offset < 0 || offset > int64(^uint64(0)>>1)-int64(len(data)) { return errYunxPieceMismatch }
    if l.writers == nil { l.writers = make(map[int]*yunxPieceWriter) }
    writer := l.writers[stream]
    if writer != nil && writer.offset+writer.length != offset {
        if writer.length > 0 {
            if err := l.appendRecord(yunxPieceRecord{writer.offset, writer.length, writer.digest.Sum(nil)}); err != nil { return err }
        }
        delete(l.writers, stream)
        writer = nil
    }
    for len(data) > 0 {
        if writer == nil {
            if len(l.writers) >= 1024 { l.failure = errors.New("too many piece integrity writers"); return l.failure }
            writer = &yunxPieceWriter{offset: offset, digest: sha256.New()}
            l.writers[stream] = writer
        }
        n := min(len(data), yunxPieceBytes-int(writer.length))
        writer.digest.Write(data[:n])
        writer.length += int64(n)
        offset += int64(n)
        data = data[n:]
        if writer.length == yunxPieceBytes {
            if err := l.appendRecord(yunxPieceRecord{writer.offset, writer.length, writer.digest.Sum(nil)}); err != nil { return err }
            delete(l.writers, stream)
            writer = nil
        }
    }
    return nil
}

// Called while the existing target-file lock is held. Only bytes confirmed by
// WriteAt enter the ledger; hashing never reads the target during download.
func (f *Fetcher) yunxWriteAt(data []byte, offset int64, stream int) (int, error) {
    if f.file == nil { return 0, io.ErrClosedPipe }
    n, err := f.file.WriteAt(data, offset)
    if f.yunxUsesPieces() && n > 0 {
        if hashErr := f.yunxPieces.record(stream, offset, data[:n]); hashErr != nil { return n, hashErr }
    }
    if err == nil && n != len(data) { err = io.ErrShortWrite }
    return n, err
}

func (l *yunxPieceLedger) snapshot() (*yunxPieceSnapshot, error) {
    l.Lock()
    defer l.Unlock()
    if l.failure != nil { return nil, l.failure }
    records := append([]yunxPieceRecord(nil), l.records...)
    for _, writer := range l.writers {
        if writer.length > 0 { records = append(records, yunxPieceRecord{writer.offset, writer.length, writer.digest.Sum(nil)}) }
    }
    return &yunxPieceSnapshot{Version: 1, Records: records}, nil
}

func (f *Fetcher) yunxRestorePieces(snapshot *yunxPieceSnapshot) {
    f.yunxPieces.restored = f.yunxUsesPieces()
    if !f.yunxPieces.restored { return }
    if snapshot == nil || snapshot.Version != 1 || len(snapshot.Records) > yunxPieceLimit+1024 {
        f.yunxPieces.failure = errYunxPieceMismatch
        return
    }
    // JSON owns these arrays. They become immutable records of this fetcher.
    f.yunxPieces.records = snapshot.Records
}

type yunxPieceInterval struct { begin, end int64 }

func yunxPieceCoverage(records []yunxPieceRecord) ([]yunxPieceInterval, error) {
    intervals := make([]yunxPieceInterval, 0, len(records))
    for _, record := range records {
        if record.Offset < 0 || record.Length <= 0 || record.Length > yunxPieceBytes ||
            record.Offset > int64(^uint64(0)>>1)-record.Length || len(record.SHA256) != sha256.Size { return nil, errYunxPieceMismatch }
        intervals = append(intervals, yunxPieceInterval{record.Offset, record.Offset+record.Length})
    }
    sort.Slice(intervals, func(i, j int) bool { return intervals[i].begin < intervals[j].begin })
    merged := intervals[:0]
    for _, interval := range intervals {
        if len(merged) == 0 || interval.begin > merged[len(merged)-1].end { merged = append(merged, interval) } else {
            merged[len(merged)-1].end = max(merged[len(merged)-1].end, interval.end)
        }
    }
    return merged, nil
}

func yunxPiecesCover(intervals []yunxPieceInterval, begin, end int64) bool {
    if begin < 0 || end < begin { return false }
    if begin == end { return true }
    for _, interval := range intervals {
        if interval.begin > begin { return false }
        if interval.end >= end { return true }
    }
    return false
}

func (f *Fetcher) yunxVerifyPieces(final bool) error {
    if !f.yunxUsesPieces() { return nil }
    snapshot, err := f.yunxPieces.snapshot()
    if err != nil { return err }
    coverage, err := yunxPieceCoverage(snapshot.Records)
    if err != nil { return err }
    // Before any resumed network request, prove every recorded current chunk
    // and the total persisted byte count are backed by hashed disk contents.
    if !final {
        f.connMu.Lock()
        var downloaded int64
        valid := true
        for _, conn := range f.connections {
            if conn == nil || conn.Chunk == nil || conn.Downloaded < 0 || conn.Chunk.Downloaded < 0 ||
                conn.Chunk.Begin < 0 || conn.Chunk.Begin > int64(^uint64(0)>>1)-conn.Chunk.Downloaded ||
                downloaded > int64(^uint64(0)>>1)-conn.Downloaded { valid = false; break }
            downloaded += conn.Downloaded
            if !yunxPiecesCover(coverage, conn.Chunk.Begin, conn.Chunk.Begin+conn.Chunk.Downloaded) { valid = false; break }
        }
        f.connMu.Unlock()
        var covered int64
        for _, interval := range coverage {
            if covered > int64(^uint64(0)>>1)-(interval.end-interval.begin) { valid = false; break }
            covered += interval.end-interval.begin
        }
        if !valid || covered < downloaded { return errYunxPieceMismatch }
        if len(snapshot.Records) == 0 { return nil }
    }
    file, err := os.Open(f.meta.SingleFilepath())
    if err != nil { return err }
    defer file.Close()
    info, err := file.Stat()
    if err != nil { return err }
    if !info.Mode().IsRegular() { return errYunxPieceMismatch }
    if final && !yunxPiecesCover(coverage, 0, info.Size()) { return errYunxPieceMismatch }
    buffer := make([]byte, yunxPieceBytes)
    for _, record := range snapshot.Records {
        if record.Offset+record.Length > info.Size() { return errYunxPieceMismatch }
        n, err := file.ReadAt(buffer[:int(record.Length)], record.Offset)
        if err != nil { return err }
        if int64(n) != record.Length { return errYunxPieceMismatch }
        digest := sha256.Sum256(buffer[:n])
        if !bytes.Equal(digest[:], record.SHA256) { return errYunxPieceMismatch }
    }
    return nil
}

func (f *Fetcher) yunxValidateRestoredPieces() error {
    if !f.yunxPieces.restored { return nil }
    if err := f.yunxVerifyPieces(false); err != nil {
        if errors.Is(err, errYunxPieceMismatch) { f.checksumFailed.Store(true); f.setState(stateError) }
        return err
    }
    f.yunxPieces.restored = false
    return nil
}

func (f *Fetcher) yunxResetPieces() {
    f.yunxPieces.Lock()
    f.yunxPieces.records = nil
    f.yunxPieces.writers = nil
    f.yunxPieces.failure = nil
    f.yunxPieces.restored = false
    f.yunxPieces.Unlock()
}
