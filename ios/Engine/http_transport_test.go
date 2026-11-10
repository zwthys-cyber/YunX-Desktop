// SPDX-License-Identifier: AGPL-3.0-only
package httpclient

import (
    "crypto/tls"
    "crypto/x509"
    "errors"
    "fmt"
    "io"
    "log"
    "net/http"
    "net/http/httptest"
    "sync"
    "sync/atomic"
    "testing"
    "time"
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

func TestYunxHTTPVersionPreservesTLSCertificateVerification(t *testing.T) {
    server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { io.WriteString(w, r.Proto) }))
    server.EnableHTTP2 = true
    server.Config.ErrorLog = log.New(io.Discard, "", 0)
    server.StartTLS()
    defer server.Close()
    trusted := x509.NewCertPool()
    trusted.AddCert(server.Certificate())
    for _, browser := range []Browser{BrowserChrome, BrowserFirefox, BrowserSafari} {
        for _, enabled := range []bool{false, true} {
            for _, roots := range []*x509.CertPool{nil, trusted} {
                client, err := NewClient(Options{
                    Transport: TransportOptions{YunxDisableHTTP2: !enabled, TLSClientConfig: &tls.Config{RootCAs: roots}},
                    Impersonation: ImpersonationOptions{Mode: ImpersonationFixed, Browser: browser},
                    Client: ClientOptions{Timeout: 5*time.Second},
                })
                if err != nil { t.Fatal(err) }
                response, err := client.Get(server.URL)
                if roots == nil {
                    if response != nil { response.Body.Close() }
                    var unknown x509.UnknownAuthorityError
                    if !errors.As(err, &unknown) { t.Fatalf("%s enabled=%v accepted an untrusted certificate or returned a different error: %v", browser, enabled, err) }
                } else {
                    if err != nil { t.Fatalf("%s enabled=%v rejected trusted local CA: %v", browser, enabled, err) }
                    _, readErr := io.Copy(io.Discard, response.Body)
                    response.Body.Close()
                    if readErr != nil { t.Fatal(readErr) }
                }
                client.CloseIdleConnections()
            }
        }
    }
}
