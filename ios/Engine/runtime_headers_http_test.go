// SPDX-License-Identifier: AGPL-3.0-only
package http

import (
    "bytes"
    gohttp "net/http"
    "net/http/httptest"
    "os"
    "strings"
    "sync/atomic"
    "testing"
    "time"
    "github.com/GopeedLab/gopeed/pkg/base"
    fhttp "github.com/GopeedLab/gopeed/pkg/protocol/http"
)

func TestYunxRuntimeHeadersBrowserFallbackDoesNotAcquireJarCookies(t *testing.T) {
    base.YunxSetRuntimeHeaderResolver(func(_, _, _ string) (gohttp.Header, error) {
        return gohttp.Header{"Cookie": {"fixture-auth=required"}}, nil
    })
    defer base.YunxSetRuntimeHeaderResolver(nil)
    payload := bytes.Repeat([]byte{0x4c}, 32768)
    var requests atomic.Int32
    server := httptest.NewServer(gohttp.HandlerFunc(func(w gohttp.ResponseWriter, r *gohttp.Request) {
        cookie := r.Header.Get("Cookie")
        if !strings.Contains(cookie, "fixture-auth=required") { t.Error("runtime credential did not reach origin") }
        if strings.Contains(cookie, "unexpected-session") { t.Error("browser fallback reintroduced jar cookies") }
        if requests.Add(1) == 1 {
            w.Header().Set("Set-Cookie", "unexpected-session=not-authorized; Path=/")
            w.WriteHeader(gohttp.StatusForbidden)
            return
        }
        gohttp.ServeContent(w, r, "fixture.bin", time.Time{}, bytes.NewReader(payload))
    }))
    defer server.Close()
    f := buildFetcher()
    defer f.Close()
    f.Meta().Opts = &base.Options{Path: t.TempDir(), Name: "fixture.bin", Extra: &fhttp.OptsExtra{Connections: 1}}
    if err := f.Resolve(&base.Request{URL: server.URL, Labels: map[string]string{base.YunxHeaderContextLabel: "fixture"}}); err != nil { t.Fatal(err) }
    if err := f.Start(); err != nil { t.Fatal(err) }
    if err := f.Wait(); err != nil { t.Fatal(err) }
    actual, err := os.ReadFile(f.Meta().SingleFilepath())
    if err != nil || !bytes.Equal(actual, payload) { t.Fatalf("authenticated response mismatch: %v", err) }
    if requests.Load() < 2 { t.Fatal("browser fallback was not exercised") }
}
