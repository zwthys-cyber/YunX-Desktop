// SPDX-License-Identifier: AGPL-3.0-only
package http

import (
    "bytes"
    "encoding/json"
    "errors"
    "net/http"
    "net/http/httptest"
    "os"
    "path/filepath"
    "testing"
    "time"

    "github.com/GopeedLab/gopeed/internal/fetcher"
    "github.com/GopeedLab/gopeed/pkg/base"
    fhttp "github.com/GopeedLab/gopeed/pkg/protocol/http"
)

func yunxPieceFixture(t *testing.T) (*Fetcher, string) {
    t.Helper()
    root := t.TempDir()
    file := filepath.Join(root, "fixture.bin")
    f := &Fetcher{meta: &fetcher.FetcherMeta{
        Req: &base.Request{URL: "https://fixture.invalid/file", Labels: map[string]string{"yunxPieceIntegrity": "1"}},
        Opts: &base.Options{Path: root, Name: "fixture.bin"},
        Res: &base.Resource{Files: []*base.FileInfo{{Name: "fixture.bin"}}},
    }}
    return f, file
}

func TestYunxPiecesHashWritesWithoutReadingAndSnapshotsAreImmutable(t *testing.T) {
    f, path := yunxPieceFixture(t)
    file, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY, 0600)
    if err != nil { t.Fatal(err) }
    defer file.Close()
    f.file = file
    first := bytes.Repeat([]byte{0x73}, yunxPieceBytes+17)
    if n, err := f.yunxWriteAt(first, 0, 0); err != nil || n != len(first) { t.Fatalf("write-only file must support incremental hashing: %d %v", n, err) }
    snapshot, err := f.yunxPieces.snapshot()
    if err != nil { t.Fatal(err) }
    before, _ := json.Marshal(snapshot)
    rest := bytes.Repeat([]byte{0x56}, 100)
    if _, err := f.yunxWriteAt(rest, int64(len(first)), 0); err != nil { t.Fatal(err) }
    after, _ := json.Marshal(snapshot)
    if !bytes.Equal(before, after) { t.Fatal("serialized checkpoint changed after Store returned") }
    if len(snapshot.Records) != 2 || snapshot.Records[0].Length != yunxPieceBytes || snapshot.Records[1].Length != 17 { t.Fatal("incremental block boundaries are incorrect") }
    clear(first); clear(rest)
    if err := f.yunxVerifyPieces(true); err != nil { t.Fatal(err) }
}

func TestYunxPiecesRejectTamperingAndUnhashedHoles(t *testing.T) {
    for _, mode := range []string{"changed-byte", "unhashed-hole", "truncated", "unhashed-progress", "missing-checkpoint", "bad-checkpoint"} {
        t.Run(mode, func(t *testing.T) {
            f, path := yunxPieceFixture(t)
            payload := bytes.Repeat([]byte{0x41}, 4096)
            if err := os.WriteFile(path, payload, 0600); err != nil { t.Fatal(err) }
            hashed := len(payload)
            if mode == "unhashed-hole" { hashed = 100 }
            if err := f.yunxPieces.record(0, 0, payload[:hashed]); err != nil { t.Fatal(err) }
            snapshot, err := f.yunxPieces.snapshot()
            if err != nil { t.Fatal(err) }
            switch mode {
            case "changed-byte": payload[15] ^= 1; if err := os.WriteFile(path, payload, 0600); err != nil { t.Fatal(err) }
            case "truncated": if err := os.Truncate(path, 1000); err != nil { t.Fatal(err) }
            case "missing-checkpoint": snapshot = nil
            case "bad-checkpoint": snapshot.Records[0].SHA256 = []byte{1}
            }
            f.yunxResetPieces()
            f.yunxRestorePieces(snapshot)
            if mode == "unhashed-progress" { f.connections = []*connection{{Downloaded: 4097, Chunk: &chunk{Begin: 4096, Downloaded: 1}}} }
            err = f.yunxVerifyPieces(mode != "unhashed-progress")
            if !errors.Is(err, errYunxPieceMismatch) { t.Fatalf("%s was not rejected as corrupt: %v", mode, err) }
        })
    }
}

func TestYunxPiecesFailedWritesAreNotRecordedAndOldTasksKeepCompatibility(t *testing.T) {
    f, path := yunxPieceFixture(t)
    if err := os.WriteFile(path, []byte("original"), 0600); err != nil { t.Fatal(err) }
    file, err := os.Open(path)
    if err != nil { t.Fatal(err) }
    defer file.Close()
    f.file = file
    if _, err := f.yunxWriteAt([]byte("replacement"), 0, 0); err == nil { t.Fatal("write to read-only descriptor succeeded") }
    snapshot, err := f.yunxPieces.snapshot()
    if err != nil || len(snapshot.Records) != 0 { t.Fatal("uncommitted bytes entered the checkpoint") }
    delete(f.meta.Req.Labels, "yunxPieceIntegrity")
    f.yunxRestorePieces(nil)
    if err := f.yunxVerifyPieces(true); err != nil { t.Fatal("old tasks must not be interpreted as new verified checkpoints") }
}

func TestYunxPiecesRealRangeTransferAndStoredCheckpoint(t *testing.T) {
    payload := make([]byte, 3*yunxPieceBytes+171)
    for i := range payload { payload[i] = byte(i%251) }
    server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        w.Header().Set("ETag", `"piece-fixture"`)
        http.ServeContent(w, r, "fixture.bin", time.Time{}, bytes.NewReader(payload))
    }))
    defer server.Close()
    f := buildFetcher()
    defer f.Close()
    f.Meta().Opts = &base.Options{Path: t.TempDir(), Name: "fixture.bin", Extra: &fhttp.OptsExtra{Connections: 4}}
    if err := f.Resolve(&base.Request{URL: server.URL, Labels: map[string]string{"yunxPieceIntegrity": "1"}}); err != nil { t.Fatal(err) }
    if err := f.Start(); err != nil { t.Fatal(err) }
    if err := f.Wait(); err != nil { t.Fatal(err) }
    actual, err := os.ReadFile(f.Meta().SingleFilepath())
    if err != nil || !bytes.Equal(payload, actual) { t.Fatalf("actual Range body differs: %v", err) }
    fm := &FetcherManager{}
    checkpoint, err := fm.Store(f)
    if err != nil { t.Fatal(err) }
    encoded, err := json.Marshal(checkpoint)
    if err != nil { t.Fatal(err) }
    stored, restore := fm.Restore()
    if err := json.Unmarshal(encoded, stored); err != nil { t.Fatal(err) }
    resumed := restore(f.Meta(), stored).(*Fetcher)
    if err := resumed.yunxValidateRestoredPieces(); err != nil { t.Fatal(err) }
    target, err := os.OpenFile(f.Meta().SingleFilepath(), os.O_WRONLY, 0)
    if err != nil { t.Fatal(err) }
    _, writeErr := target.WriteAt([]byte{payload[7]^1}, 7)
    target.Close()
    if writeErr != nil { t.Fatal(writeErr) }
    resumed = restore(f.Meta(), stored).(*Fetcher)
    if err := resumed.yunxValidateRestoredPieces(); !errors.Is(err, errYunxPieceMismatch) { t.Fatalf("tampered disk checkpoint was reused: %v", err) }
    if !resumed.checksumFailed.Load() { t.Fatal("explicit retry would reuse corrupted pieces") }
}

func TestYunxPiecesPausedCheckpointCoversARealPartialTransfer(t *testing.T) {
    payload := bytes.Repeat([]byte{0x37}, 2*yunxPieceBytes)
    server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        w.Header().Set("ETag", `"partial-piece-fixture"`)
        http.ServeContent(yunxPacedSource{w, r.Context()}, r, "fixture.bin", time.Time{}, bytes.NewReader(payload))
    }))
    defer server.Close()
    f := buildFetcher()
    defer f.Close()
    f.Meta().Opts = &base.Options{Path: t.TempDir(), Name: "fixture.bin", Extra: &fhttp.OptsExtra{Connections: 2}}
    if err := f.Resolve(&base.Request{URL: server.URL, Labels: map[string]string{"yunxPieceIntegrity": "1"}}); err != nil { t.Fatal(err) }
    if err := f.Start(); err != nil { t.Fatal(err) }
    partial := false
    deadline := time.Now().Add(10*time.Second)
    for time.Now().Before(deadline) {
        f.connMu.Lock()
        var downloaded int64
        for _, conn := range f.connections { if conn != nil { downloaded += conn.Downloaded } }
        partial = downloaded > 16*1024 && downloaded < int64(len(payload))
        f.connMu.Unlock()
        if partial { break }
        time.Sleep(5*time.Millisecond)
    }
    if !partial { t.Fatal("no actual partial transfer to checkpoint") }
    if err := f.Pause(); err != nil { t.Fatal(err) }
    fm := &FetcherManager{}
    checkpoint, err := fm.Store(f)
    if err != nil { t.Fatal(err) }
    encoded, err := json.Marshal(checkpoint)
    if err != nil { t.Fatal(err) }
    stored, restore := fm.Restore()
    if err := json.Unmarshal(encoded, stored); err != nil { t.Fatal(err) }
    resumed := restore(f.Meta(), stored).(*Fetcher)
    if err := resumed.yunxValidateRestoredPieces(); err != nil { t.Fatalf("valid persisted partial body rejected: %v", err) }
    // Deleting digests must not let a byte count become resumable evidence.
    stored.(*fetcherData).YunxPieces.Records = nil
    resumed = restore(f.Meta(), stored).(*Fetcher)
    if err := resumed.yunxValidateRestoredPieces(); !errors.Is(err, errYunxPieceMismatch) { t.Fatalf("unhashed partial progress was reused: %v", err) }
}
