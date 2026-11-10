// SPDX-License-Identifier: AGPL-3.0-only
package http

import (
    "bytes"
    "context"
    "os"
    "path/filepath"
    "testing"
    "github.com/GopeedLab/gopeed/internal/fetcher"
    "github.com/GopeedLab/gopeed/pkg/base"
)

func TestYunxPrefetchCountsOnlyBytesActuallyCopied(t *testing.T) {
    for _, mode := range []string{"complete", "truncated", "closed-source", "closed-target", "missing-target"} {
        t.Run(mode, func(t *testing.T) {
            root := t.TempDir()
            content := bytes.Repeat([]byte{0x47}, 70000)
            sourcePath := filepath.Join(root, "prefetch")
            stored := content
            if mode == "truncated" { stored = content[:1234] }
            if err := os.WriteFile(sourcePath, stored, 0600); err != nil { t.Fatal(err) }
            source, err := os.Open(sourcePath)
            if err != nil { t.Fatal(err) }
            defer source.Close()
            targetPath := filepath.Join(root, "target")
            target, err := os.Create(targetPath)
            if err != nil { t.Fatal(err) }
            defer target.Close()
            f := &Fetcher{prefetchFile: source, prefetchFilePath: sourcePath, file: target, prefetchStopCh: make(chan struct{})}
            f.prefetchSize.Store(int64(len(content)))
            if mode == "closed-source" { source.Close() }
            if mode == "closed-target" { target.Close() }
            if mode == "missing-target" { f.file = nil }
            copied := f.stopPrefetchAndCopyData()
            want := int64(0)
            if mode == "complete" { want = int64(len(content)) }
            if mode == "truncated" { want = int64(len(stored)) }
            if copied != want { t.Fatalf("claimed %d copied bytes, actually expected %d", copied, want) }
            if mode == "complete" {
                result, err := os.ReadFile(targetPath)
                if err != nil || !bytes.Equal(result, content) { t.Fatalf("copied file mismatch: %v", err) }
                if f.prefetchErr != nil { t.Fatal(f.prefetchErr) }
            } else if f.prefetchErr == nil { t.Fatal("copy failure was discarded") }
            if f.prefetchSize.Load() != 0 { t.Fatal("discarded prefix still reusable") }
        })
    }
}

func TestYunxPrefetchUnknownSizeCannotCompleteAfterCopyFailure(t *testing.T) {
    root := t.TempDir()
    sourcePath := filepath.Join(root, "prefetch")
    payload := []byte("not committed to the target")
    if err := os.WriteFile(sourcePath, payload, 0600); err != nil { t.Fatal(err) }
    source, err := os.Open(sourcePath)
    if err != nil { t.Fatal(err) }
    defer source.Close()
    target, err := os.Create(filepath.Join(root, "target"))
    if err != nil { t.Fatal(err) }
    target.Close()
    exited := make(chan struct{}); close(exited)
    f := &Fetcher{meta: &fetcher.FetcherMeta{Res: &base.Resource{}}, prefetchFile: source,
        prefetchFilePath: sourcePath, file: target, prefetchStopCh: make(chan struct{}), prefetchExitCh: exited}
    f.prefetchSize.Store(int64(len(payload))); f.resolveFallback.Store(true)
    conn := &connection{ID: 0, ctx: context.Background()}
    if f.completeFromResolveFallback(conn) || conn.Completed { t.Fatal("failed target copy became a completed download") }
    if f.prefetchErr == nil { t.Fatal("disk copy error was lost") }
}
