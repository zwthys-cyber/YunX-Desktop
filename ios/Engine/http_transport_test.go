// SPDX-License-Identifier: AGPL-3.0-only
package httpclient

import (
    "crypto/tls"
    "io"
    "net/http"
    "net/http/httptest"
    "strings"
    "sync/atomic"
    "testing"
)

func TestYunxHTTPVersionReachesNativeAndBrowserTLSConnections(t *testing.T) {
    var fallbackProbes atomic.Int32
    server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        if r.URL.Path == "/fallback" && strings.HasPrefix(r.UserAgent(), "Go-http-client/") {
            fallbackProbes.Add(1)
            w.WriteHeader(http.StatusForbidden)
            return
        }
        io.WriteString(w, r.Proto)
    }))
    server.EnableHTTP2 = true
    server.StartTLS()
    defer server.Close()
    for _, mode := range []ImpersonationMode{ImpersonationNative, ImpersonationFixed, ImpersonationAuto} {
        for _, enabled := range []bool{false, true} {
            client, err := NewClient(Options{
                Transport: TransportOptions{YunxDisableHTTP2: !enabled, TLSClientConfig: &tls.Config{InsecureSkipVerify: true}},
                Impersonation: ImpersonationOptions{Mode: mode, Browser: BrowserChrome},
            })
            if err != nil { t.Fatal(err) }
            target := server.URL
            if mode == ImpersonationAuto { target += "/fallback" }
            response, err := client.Get(target)
            if err != nil { t.Fatalf("%s enabled=%v: %v", mode, enabled, err) }
            body, err := io.ReadAll(response.Body)
            response.Body.Close()
            client.CloseIdleConnections()
            if err != nil { t.Fatal(err) }
            want := "HTTP/1.1"
            if enabled { want = "HTTP/2.0" }
            if string(body) != want { t.Fatalf("%s enabled=%v: got %q, want %q", mode, enabled, body, want) }
        }
    }
    if fallbackProbes.Load() != 2 { t.Fatalf("native-to-browser fallback was not exercised: %d", fallbackProbes.Load()) }
}
