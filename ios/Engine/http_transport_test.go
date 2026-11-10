// SPDX-License-Identifier: AGPL-3.0-only
package httpclient

import (
    "crypto/tls"
    "fmt"
    "io"
    "net/http"
    "net/http/httptest"
    "sync"
    "sync/atomic"
    "testing"
)

func TestYunxHTTPVersionReachesNativeAndBrowserTLSConnections(t *testing.T) {
    var fallbackProbes atomic.Int32
    var fallbackMu sync.Mutex
    fallbackSeen := map[string]bool{}
    server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        if r.URL.Path == "/fallback" {
            fallbackMu.Lock()
            seen := fallbackSeen[r.URL.RawQuery]
            fallbackSeen[r.URL.RawQuery] = true
            fallbackMu.Unlock()
            if !seen {
                fallbackProbes.Add(1)
                w.WriteHeader(http.StatusForbidden)
                return
            }
        }
        io.WriteString(w, r.Proto)
    }))
    server.EnableHTTP2 = true
    server.StartTLS()
    defer server.Close()
    for _, mode := range []ImpersonationMode{ImpersonationNative, ImpersonationFixed, ImpersonationAuto} {
      for _, browser := range []Browser{BrowserChrome, BrowserFirefox, BrowserSafari} {
        for _, enabled := range []bool{false, true} {
            client, err := NewClient(Options{
                Transport: TransportOptions{YunxDisableHTTP2: !enabled, TLSClientConfig: &tls.Config{InsecureSkipVerify: true}},
                Impersonation: ImpersonationOptions{Mode: mode, Browser: browser},
            })
            if err != nil { t.Fatal(err) }
            target := server.URL
            if mode == ImpersonationAuto { target += fmt.Sprintf("/fallback?case=%s-%v", browser, enabled) }
            request, err := http.NewRequest(http.MethodGet, target, nil)
            if err != nil { t.Fatal(err) }
            switch browser {
            case BrowserChrome: request.Header.Set("User-Agent", "Mozilla/5.0 Chrome/120.0")
            case BrowserFirefox: request.Header.Set("User-Agent", "Mozilla/5.0 Firefox/120.0")
            case BrowserSafari: request.Header.Set("User-Agent", "Mozilla/5.0 Safari/16.0")
            }
            response, err := client.Do(request)
            if err != nil { t.Fatalf("%s/%s enabled=%v: %v", mode, browser, enabled, err) }
            body, err := io.ReadAll(response.Body)
            response.Body.Close()
            client.CloseIdleConnections()
            if err != nil { t.Fatal(err) }
            want := "HTTP/1.1"
            if enabled { want = "HTTP/2.0" }
            if string(body) != want { t.Fatalf("%s/%s enabled=%v: got %q, want %q", mode, browser, enabled, body, want) }
        }
      }
    }
    if fallbackProbes.Load() != 6 { t.Fatalf("native-to-browser fallback was not exercised: %d", fallbackProbes.Load()) }
}
