// SPDX-License-Identifier: AGPL-3.0-only
package http

import (
    "bytes"
    "context"
    "encoding/json"
    "errors"
    "io"
    "net/http"
    "net/http/httptest"
    "os"
    "strings"
    "sync/atomic"
    "testing"
    "time"

    "github.com/GopeedLab/gopeed/pkg/base"
    fhttp "github.com/GopeedLab/gopeed/pkg/protocol/http"
)

type yunxPacedSource struct { http.ResponseWriter; ctx context.Context }
func (w yunxPacedSource) Write(data []byte) (int, error) {
    written := 0
    for len(data) > 0 {
        amount := min(1024, len(data))
        n, err := w.ResponseWriter.Write(data[:amount])
        written += n
        if err != nil { return written, err }
        if n != amount { return written, io.ErrShortWrite }
        w.ResponseWriter.(http.Flusher).Flush()
        data = data[amount:]
        select { case <-w.ctx.Done(): return written, w.ctx.Err(); case <-time.After(5*time.Millisecond): }
    }
    return written, nil
}

func TestYunxCloudSourceRebindKeepsPrefixValidatorAndPrivateHeaderIsolation(t *testing.T) {
    payload := make([]byte, 4*1024*1024)
    for i := range payload { payload[i] = byte(i % 251) }
    const tag = `"same-source-content"`
    source := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        if r.Header.Get("Cookie") != "old-source-secret" { w.WriteHeader(401); return }
        w.Header().Set("ETag", tag)
        http.ServeContent(yunxPacedSource{w, r.Context()}, r, "fixture.bin", time.Time{}, bytes.NewReader(payload))
    }))
    defer source.Close()
    var resumed atomic.Bool
    target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        if r.Header.Get("Cookie") != "new-source-secret" { t.Error("replacement credential missing or old credential reused"); w.WriteHeader(401); return }
        resumed.Store(r.Header.Get("If-Range") == tag && strings.HasPrefix(r.Header.Get("Range"), "bytes=") && !strings.HasPrefix(r.Header.Get("Range"), "bytes=0-"))
        w.Header().Set("ETag", tag)
        http.ServeContent(w, r, "fixture.bin", time.Time{}, bytes.NewReader(payload))
    }))
    defer target.Close()
    base.YunxSetRuntimeHeaderResolver(func(id, original, _ string) (http.Header, error) {
        if id == "old-header-id" && original == source.URL { return http.Header{"Cookie": {"old-source-secret"}}, nil }
        if id == "new-header-id" && original == target.URL { return http.Header{"Cookie": {"new-source-secret"}}, nil }
        return nil, errors.New("unexpected source binding")
    })
    defer base.YunxSetRuntimeHeaderResolver(nil)
    f := buildFetcher()
    defer f.Close()
    f.Meta().Opts = &base.Options{Path: t.TempDir(), Name: "fixture.bin", Extra: &fhttp.OptsExtra{Connections: 1}}
    if err := f.Resolve(&base.Request{URL: source.URL, Labels: map[string]string{"yunxCloudTransfer": "old-cloud-id", base.YunxHeaderContextLabel: "old-header-id"}}); err != nil { t.Fatal(err) }
    if err := f.Start(); err != nil { t.Fatal(err) }
    firstRun := make(chan error, 1)
    go func() { firstRun <- f.Wait() }()
    partial := false
    deadline := time.Now().Add(12*time.Second)
    for time.Now().Before(deadline) {
        f.connMu.Lock()
        var received int64
        for _, connection := range f.connections { if connection != nil { received += connection.Downloaded } }
        partial = f.rangeValidatorPinned && received > 16*1024 && received < int64(len(payload))
        f.connMu.Unlock()
        if partial { break }
        time.Sleep(5*time.Millisecond)
    }
    if !partial { t.Fatal("fixture never produced a validated partial range") }
    if err := f.Pause(); err != nil { t.Fatal(err) }
    select { case <-firstRun: case <-time.After(2*time.Second): t.Fatal("original worker did not stop") }
    replacement := func() *base.Request {
        return &base.Request{URL: target.URL, Extra: &fhttp.ReqExtra{Method: "GET", Header: map[string]string{}},
            Labels: map[string]string{"yunxCloudTransfer": "new-cloud-id", base.YunxHeaderContextLabel: "new-header-id"}}
    }
    if updated, err := f.YunxRebindCloudSource(replacement(), int64(len(payload)+1)); err != nil || updated { t.Fatalf("changed size was accepted: %v %v", updated, err) }
    unsafe := replacement()
    unsafe.Extra.(*fhttp.ReqExtra).Header["Cookie"] = "must-not-enter-metadata"
    if _, err := f.YunxRebindCloudSource(unsafe, int64(len(payload))); err == nil { t.Fatal("plaintext replacement credential accepted") }
    if f.Meta().Req.URL != source.URL { t.Fatal("a rejected replacement changed the old request") }
    if updated, err := f.YunxRebindCloudSource(replacement(), int64(len(payload))); err != nil || !updated { t.Fatalf("validated source was not rebound: %v %v", updated, err) }
    metadata, err := json.Marshal(f.Meta().Req)
    if err != nil { t.Fatal(err) }
    for _, secret := range []string{"old-source-secret", "new-source-secret", "must-not-enter-metadata"} {
        if bytes.Contains(metadata, []byte(secret)) { t.Fatal("source credential persisted in request metadata") }
    }
    if err := f.Start(); err != nil { t.Fatal(err) }
    result := make(chan error, 1)
    go func() { result <- f.Wait() }()
    select {
    case err := <-result: if err != nil { t.Fatal(err) }
    case <-time.After(15*time.Second): t.Fatal("rebound source did not finish")
    }
    actual, err := os.ReadFile(f.Meta().SingleFilepath())
    if err != nil || !bytes.Equal(actual, payload) || !resumed.Load() { t.Fatalf("resumed source differs or lost its validator: %v resumed=%v", err, resumed.Load()) }
}
