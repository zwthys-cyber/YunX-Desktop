// SPDX-License-Identifier: AGPL-3.0-only
package base

import (
    "encoding/base64"
    "encoding/json"
    "io"
    "net/http"
    "net/http/httptest"
    "net/url"
    "strings"
    "testing"
    "time"
)

func TestYunxRuntimeProxyDoesNotPersistCredentials(t *testing.T) {
    defer SetRuntimeProxyResolver(nil)
    user, password := "fixture-proxy-user", "fixture:@/password"
    received := make(chan string, 4)
    proxy := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        received <- r.Header.Get("Proxy-Authorization")
        if r.URL.Host != "origin.invalid" { t.Errorf("unexpected origin: %s", r.URL.Host) }
        _, _ = io.WriteString(w, "proxy-fixture")
    }))
    defer proxy.Close()
    endpoint, err := url.Parse(proxy.URL)
    if err != nil { t.Fatal(err) }
    endpoint.User = url.UserPassword(user, password)
    SetRuntimeProxyResolver(func(*http.Request) (*url.URL, error) { return endpoint, nil })
    config := &DownloaderProxyConfig{Enable: false}
    transport := &http.Transport{Proxy: config.ToHandler()}
    defer transport.CloseIdleConnections()
    client := &http.Client{Transport: transport, Timeout: 5 * time.Second}
    response, err := client.Get("http://origin.invalid/payload")
    if err != nil { t.Fatal(err) }
    defer response.Body.Close()
    body, err := io.ReadAll(response.Body)
    if err != nil || string(body) != "proxy-fixture" { t.Fatalf("unexpected proxy body: %v", err) }
    expected := "Basic " + base64.StdEncoding.EncodeToString([]byte(user+":"+password))
    select { case actual := <-received: if actual != expected { t.Fatal("proxy authentication was not applied") }; case <-time.After(time.Second): t.Fatal("no proxy request") }
    encoded, err := json.Marshal(&DownloaderStoreConfig{Proxy: config})
    if err != nil { t.Fatal(err) }
    if strings.Contains(string(encoded), user) || strings.Contains(string(encoded), password) { t.Fatal("runtime credentials leaked into persistent configuration") }
    SetRuntimeProxyResolver(func(*http.Request) (*url.URL, error) { return nil, nil })
    resolved, err := transport.Proxy(&http.Request{URL: &url.URL{Scheme: "https", Host: "origin.invalid"}})
    if err != nil || resolved != nil { t.Fatal("runtime direct mode did not replace the previous proxy") }
}
