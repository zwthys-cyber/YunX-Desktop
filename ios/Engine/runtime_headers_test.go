// SPDX-License-Identifier: AGPL-3.0-only
package base

import (
    "io"
    "net/http"
    "net/http/httptest"
    "sync/atomic"
    "testing"
    "time"
)

func TestYunxRuntimeCredentialsStripAtCrossPortRedirect(t *testing.T) {
    YunxSetRuntimeHeaderResolver(func(_, _, _ string) (http.Header, error) {
        // Intentionally return the same credentials for every target: the Go
        // boundary independently enforces the origin restriction.
        return http.Header{"Cookie": {"fixture-cookie=private"}, "Authorization": {"Bearer fixture-token"}}, nil
    })
    defer YunxSetRuntimeHeaderResolver(nil)
    received := make(chan string, 1)
    target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        received <- r.Header.Get("Cookie") + "|" + r.Header.Get("Authorization")
        _, _ = w.Write([]byte("download"))
    }))
    defer target.Close()
    var originalAuthenticated atomic.Bool
    origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        originalAuthenticated.Store(r.Header.Get("Cookie") == "fixture-cookie=private" && r.Header.Get("Authorization") == "Bearer fixture-token")
        w.Header().Set("Set-Cookie", "server-session=do-not-forward; Path=/")
        http.Redirect(w, r, target.URL, http.StatusFound)
    }))
    defer origin.Close()
    client := &http.Client{Timeout: 3*time.Second}
    YunxGuardRuntimeHeaderRedirects("fixture", origin.URL, client)
    request, err := http.NewRequest(http.MethodGet, origin.URL, nil)
    if err != nil { t.Fatal(err) }
    if err := YunxApplyRuntimeHeaders("fixture", origin.URL, request); err != nil { t.Fatal(err) }
    response, err := client.Do(request)
    if err != nil { t.Fatal(err) }
    defer response.Body.Close()
    _, _ = io.Copy(io.Discard, response.Body)
    if !originalAuthenticated.Load() { t.Fatal("original request did not receive its credentials") }
    if got := <-received; got != "|" { t.Fatal("credentials crossed a redirect origin") }
}

func TestYunxRuntimeCredentialsSurviveSameOriginRedirect(t *testing.T) {
    YunxSetRuntimeHeaderResolver(func(_, _, _ string) (http.Header, error) {
        return http.Header{"Cookie": {"fixture-cookie=bound"}}, nil
    })
    defer YunxSetRuntimeHeaderResolver(nil)
    server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        if r.URL.Path == "/first" {
            w.Header().Set("Set-Cookie", "unrelated=not-needed; Path=/")
            http.Redirect(w, r, "/last", http.StatusTemporaryRedirect)
            return
        }
        if r.Header.Get("Cookie") != "fixture-cookie=bound" { t.Error("same-origin credential missing or jar cookie added") }
        w.WriteHeader(http.StatusOK)
    }))
    defer server.Close()
    original := server.URL + "/first"
    client := &http.Client{Timeout: 3*time.Second}
    YunxGuardRuntimeHeaderRedirects("fixture", original, client)
    request, _ := http.NewRequest(http.MethodGet, original, nil)
    if err := YunxApplyRuntimeHeaders("fixture", original, request); err != nil { t.Fatal(err) }
    response, err := client.Do(request)
    if err != nil { t.Fatal(err) }
    response.Body.Close()
}

func TestYunxRuntimeCredentialsRejectDowngradeMissingResolverAndUnsafeHeaders(t *testing.T) {
    request, _ := http.NewRequest(http.MethodGet, "https://origin.test/file", nil)
    YunxSetRuntimeHeaderResolver(nil)
    if YunxApplyRuntimeHeaders("fixture", request.URL.String(), request) == nil { t.Fatal("missing resolver fell back to an unauthenticated request") }
    defer YunxSetRuntimeHeaderResolver(nil)
    for _, headers := range []http.Header{{"Host": {"other.test"}}, {"Range": {"bytes=0-1"}}, {"Cookie": {"line\r\nbreak"}}} {
        YunxSetRuntimeHeaderResolver(func(_, _, _ string) (http.Header, error) { return headers, nil })
        if YunxApplyRuntimeHeaders("fixture", request.URL.String(), request) == nil { t.Fatal("unsafe header override accepted") }
    }
    YunxSetRuntimeHeaderResolver(func(_, _, _ string) (http.Header, error) { return http.Header{}, nil })
    downgrade, _ := http.NewRequest(http.MethodGet, "http://127.0.0.1/file", nil)
    if YunxApplyRuntimeHeaders("fixture", "https://origin.test/file", downgrade) == nil { t.Fatal("HTTPS downgrade accepted") }
}
