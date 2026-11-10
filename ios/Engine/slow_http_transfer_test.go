// SPDX-License-Identifier: AGPL-3.0-only
package http

import (
    "bytes"
    "fmt"
    "net/http"
    "net/http/httptest"
    "os"
    "strconv"
    "sync/atomic"
    "testing"
    "time"

    "github.com/GopeedLab/gopeed/pkg/base"
    fhttp "github.com/GopeedLab/gopeed/pkg/protocol/http"
)

func TestYunxSlowHTTPReconnectPreservesWrittenRangePrefix(t *testing.T) {
    if err := base.YunxSetNativeHTTPSlowConnections(true, 4, 5); err != nil { t.Fatal(err) }
    defer base.YunxSetNativeHTTPSlowConnections(false, 12, 15)
    payload := make([]byte, 256*1024)
    for i := range payload { payload[i] = byte(i % 251) }
    var ranges atomic.Int32
    var firstStart, secondStart atomic.Int64
    var validator atomic.Bool
    server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        w.Header().Set("Accept-Ranges", "bytes")
        w.Header().Set("ETag", `"slow-fixture"`)
        w.Header().Set("Content-Length", strconv.Itoa(len(payload)))
        start, end := int64(0), int64(len(payload)-1)
        if raw := r.Header.Get("Range"); raw != "" {
            if _, err := fmt.Sscanf(raw, "bytes=%d-%d", &start, &end); err != nil { t.Error(err); w.WriteHeader(416); return }
            number := ranges.Add(1)
            if number == 1 { firstStart.Store(start) }
            if number > 1 {
                if number == 2 { secondStart.Store(start); validator.Store(r.Header.Get("If-Range") == `"slow-fixture"`) }
                http.ServeContent(w, r, "fixture.bin", time.Time{}, bytes.NewReader(payload))
                return
            }
            w.Header().Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", start, end, len(payload)))
            w.Header().Set("Content-Length", strconv.FormatInt(end-start+1, 10))
            w.WriteHeader(http.StatusPartialContent)
        }
        // Resolve and the first range both make progress, but stay below the
        // threshold. Prefetch can stop promptly without blocking its handoff.
        for i := start; i <= end && i < start+128; i++ {
            if _, err := w.Write(payload[i:i+1]); err != nil { return }
            w.(http.Flusher).Flush()
            select { case <-r.Context().Done(): return; case <-time.After(50*time.Millisecond): }
        }
        if start+128 <= end { _, _ = w.Write(payload[start+128:end+1]) }
    }))
    defer server.Close()
    f := buildFetcher()
    defer f.Close()
    f.Meta().Opts = &base.Options{Path: t.TempDir(), Name: "fixture.bin", Extra: &fhttp.OptsExtra{Connections: 1}}
    if err := f.Resolve(&base.Request{URL: server.URL}); err != nil { t.Fatal(err) }
    if err := f.Start(); err != nil { t.Fatal(err) }
    result := make(chan error, 1)
    go func() { result <- f.Wait() }()
    select {
    case err := <-result: if err != nil { t.Fatal(err) }
    case <-time.After(25*time.Second): t.Fatal("slow connection did not reconnect")
    }
    if ranges.Load() < 2 || secondStart.Load() <= firstStart.Load() || !validator.Load() {
        t.Fatalf("range retry lost its prefix or validator: requests=%d first=%d second=%d validator=%v", ranges.Load(), firstStart.Load(), secondStart.Load(), validator.Load())
    }
    data, err := os.ReadFile(f.Meta().SingleFilepath())
    if err != nil || !bytes.Equal(data, payload) { t.Fatalf("reconnected output differs: %v", err) }
}
