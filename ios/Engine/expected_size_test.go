// SPDX-License-Identifier: AGPL-3.0-only
package http

import (
    "archive/zip"
    "bytes"
    "net/http"
    "net/http/httptest"
    "os"
    "strconv"
    "testing"
    "time"
    "github.com/GopeedLab/gopeed/pkg/base"
    fhttp "github.com/GopeedLab/gopeed/pkg/protocol/http"
)

func TestYunxExpectedMediaUsesHostValidationBeforeCompleting(t *testing.T) {
    payload := []byte("host-validated-media-fixture")
    server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        http.ServeContent(w, r, "fixture.bin", time.Time{}, bytes.NewReader(payload))
    }))
    defer server.Close()
    defer base.YunxSetMediaVerifier(nil)
    for _, kind := range []string{"image", "video"} {
        for _, verdict := range []int{0, 1, 2} {
            calls := 0
            base.YunxSetMediaVerifier(func(path, actualKind string) int {
                calls++
                data, err := os.ReadFile(path)
                if err != nil || !bytes.Equal(data, payload) || actualKind != kind { return 2 }
                return verdict
            })
            f := buildFetcher()
            f.Meta().Opts = &base.Options{Path: t.TempDir(), Name: "fixture.bin", Extra: &fhttp.OptsExtra{Connections: 1}}
            if err := f.Resolve(&base.Request{URL: server.URL, Labels: map[string]string{"yunxExpectedMedia": kind}}); err != nil { f.Close(); t.Fatal(err) }
            result := f.Start()
            if result == nil { result = f.Wait() }
            f.Close()
            if calls == 0 { t.Fatal("completed-file host verifier was not called") }
            if (result == nil) != (verdict == 1) { t.Fatalf("kind %s verdict %d: unexpected completion result %v", kind, verdict, result) }
            if f.checksumFailed.Load() != (verdict == 2) { t.Fatal("unavailable checker must preserve downloaded chunks; invalid media must reset them") }
        }
    }
    base.YunxSetMediaVerifier(nil)
    if base.YunxVerifyMedia("unread", "image") != 0 { t.Fatal("missing verifier must fail closed and remain retryable") }
}

func TestYunxExpectedSizeRejectsWrongBodyWithoutOptionalChecksum(t *testing.T) {
    payload := bytes.Repeat([]byte{0x57}, 32768)
    server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        http.ServeContent(w, r, "fixture.bin", time.Time{}, bytes.NewReader(payload))
    }))
    defer server.Close()
    for _, expected := range []int{len(payload), len(payload)+1} {
        f := buildFetcher()
        f.Meta().Opts = &base.Options{Path: t.TempDir(), Name: "fixture.bin", Extra: &fhttp.OptsExtra{Connections: 1}}
        request := &base.Request{URL: server.URL, Labels: map[string]string{"yunxExpectedSize": strconv.Itoa(expected)}}
        if err := f.Resolve(request); err != nil { f.Close(); t.Fatal(err) }
        startErr := f.Start()
        result := startErr
        if startErr == nil { result = f.Wait() }
        f.Close()
        if expected == len(payload) && result != nil { t.Fatal(result) }
        if expected != len(payload) && result == nil { t.Fatal("incorrect platform size became a completed download") }
    }
}

func TestYunxExpectedMediaRejectsHTMLAndTransfersARealZIP(t *testing.T) {
    var archive bytes.Buffer
    writer := zip.NewWriter(&archive)
    entry, err := writer.Create("fixture.txt")
    if err != nil { t.Fatal(err) }
    if _, err := entry.Write([]byte("fixture")); err != nil { t.Fatal(err) }
    if err := writer.Close(); err != nil { t.Fatal(err) }
    for _, valid := range []bool{false, true} {
        name := "html"
        if valid { name = "zip" }
        t.Run(name, func(t *testing.T) {
            data := []byte("<html>sign in required</html>")
            if valid { data = archive.Bytes() }
            server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
                http.ServeContent(w, r, "fixture.zip", time.Time{}, bytes.NewReader(data))
            }))
            defer server.Close()
            f := buildFetcher()
            defer f.Close()
            f.Meta().Opts = &base.Options{Path: t.TempDir(), Name: "fixture.zip", Extra: &fhttp.OptsExtra{Connections: 1}}
            if err := f.Resolve(&base.Request{URL: server.URL, Labels: map[string]string{"yunxExpectedMedia": "zip"}}); err != nil { t.Fatal(err) }
            result := f.Start()
            if result == nil { result = f.Wait() }
            if valid && result != nil { t.Fatal(result) }
            if !valid && result == nil { t.Fatal("HTML error page became a completed ZIP") }
        })
    }
}
