// SPDX-License-Identifier: AGPL-3.0-only
package hls

import (
    "bytes"
    "context"
    "errors"
    "io"
    "net/http"
    "net/http/httptest"
    "testing"
    "time"
    "github.com/GopeedLab/gopeed/pkg/base"
)

func TestYunxHLSAndHTTPFilesShareBudgetWithoutTimingOutRateWaits(t *testing.T) {
    data := bytes.Repeat([]byte{0x53}, 32*1024)
    key := bytes.Repeat([]byte{0x17}, 16)
    server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        if r.URL.Path == "/key" { w.Write(key) } else { w.Write(data) }
    }))
    defer server.Close()
    if err := base.YunxSetNativeHTTPBandwidthLimit(32*1024); err != nil { t.Fatal(err) }
    defer base.YunxSetNativeHTTPBandwidthLimit(0)
    cfg := testConfig(); cfg.TimeoutSeconds = 1; cfg.MaxRetries = 0
    f := newTestFetcher(t, cfg)
    f.client = server.Client()
    ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
    defer cancel()
    run := &hlsRun{ctx: ctx, client: server.Client(), keyCache: make(map[string][]byte)}
    done := make(chan error, 4)
    start := time.Now()
    go func() {
        actual, err := f.tryGetSegment(run, &Segment{URI: server.URL+"/segment"})
        if err == nil && !bytes.Equal(actual, data) { err = errors.New("HLS segment differs") }
        done <- err
    }()
    go func() {
        actual, _, err := f.fetchText(ctx, http.MethodGet, server.URL+"/playlist")
        if err == nil && actual != string(data) { err = errors.New("HLS playlist differs") }
        done <- err
    }()
    go func() {
        actual, err := f.fetchKey(run, &Key{URI: server.URL+"/key"})
        if err == nil && !bytes.Equal(actual, key) { err = errors.New("HLS key differs") }
        done <- err
    }()
    go func() {
        _, err := io.Copy(io.Discard, base.YunxNativeHTTPReader(ctx, bytes.NewReader(data), nil))
        done <- err
    }()
    for i := 0; i < 4; i++ { if err := <-done; err != nil { t.Fatal(err) } }
    if elapsed := time.Since(start); elapsed < 2500*time.Millisecond { t.Fatalf("96 KiB bypassed shared 32 KiB/s budget: %v", elapsed) }
}

func TestYunxHLSPauseCancelsSharedBudgetWait(t *testing.T) {
    server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.Write(make([]byte, 64*1024)) }))
    defer server.Close()
    if err := base.YunxSetNativeHTTPBandwidthLimit(1024); err != nil { t.Fatal(err) }
    defer base.YunxSetNativeHTTPBandwidthLimit(0)
    f := newTestFetcher(t, testConfig())
    ctx, cancel := context.WithCancel(context.Background())
    defer cancel()
    done := make(chan error, 1)
    go func() { _, err := f.tryGetSegment(&hlsRun{ctx: ctx, client: server.Client()}, &Segment{URI: server.URL}); done <- err }()
    time.Sleep(50*time.Millisecond)
    cancel()
    select {
    case err := <-done: if !errors.Is(err, context.Canceled) { t.Fatalf("pause did not cancel rate wait: %v", err) }
    case <-time.After(time.Second): t.Fatal("HLS retained a retired bandwidth reservation")
    }
}
