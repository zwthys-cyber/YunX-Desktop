// SPDX-License-Identifier: AGPL-3.0-only
package http

import (
    "bytes"
    "os"
    "path/filepath"
    "testing"
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
