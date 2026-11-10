// SPDX-License-Identifier: AGPL-3.0-only
package base

import (
    "errors"
    "net"
    "net/http"
    "net/url"
    "strings"
    "sync"
)

const YunxHeaderContextLabel = "yunxHeaderContext"

var yunxHeaders struct {
    sync.RWMutex
    resolve func(string, string, string) (http.Header, error)
}

func YunxSetRuntimeHeaderResolver(resolve func(string, string, string) (http.Header, error)) {
    yunxHeaders.Lock(); yunxHeaders.resolve = resolve; yunxHeaders.Unlock()
}

func yunxCredentialURL(value *url.URL) bool {
    if value == nil || value.Hostname() == "" || value.User != nil { return false }
    if value.Scheme == "https" { return true }
    if value.Scheme != "http" { return false }
    host := value.Hostname()
    if strings.EqualFold(host, "localhost") { return true }
    ip := net.ParseIP(host)
    return ip != nil && ip.IsLoopback()
}

func yunxSameOrigin(a, b *url.URL) bool {
    port := func(value *url.URL) string {
        if value.Port() != "" { return value.Port() }
        if value.Scheme == "https" { return "443" }
        return "80"
    }
    return a.Scheme == b.Scheme && strings.EqualFold(a.Hostname(), b.Hostname()) && port(a) == port(b)
}

// Only the live http.Request gets credential values. The persisted Request
// retains its context ID and original URL, never a copy of Keychain headers.
func YunxApplyRuntimeHeaders(id, originalURL string, request *http.Request) error {
    if id == "" { return nil }
    original, err := url.Parse(originalURL)
    if err != nil || !yunxCredentialURL(original) || request == nil || !yunxCredentialURL(request.URL) ||
        (original.Scheme == "https" && request.URL.Scheme != "https") || len(id) > 128 ||
        (request.Method != http.MethodGet && request.Method != http.MethodHead) {
        return errors.New("invalid runtime credential request")
    }
    yunxHeaders.RLock(); resolve := yunxHeaders.resolve; yunxHeaders.RUnlock()
    if resolve == nil { return errors.New("runtime credentials unavailable") }
    values, err := resolve(id, originalURL, request.URL.String())
    if err != nil { return errors.New("runtime credentials unavailable") }
    allowed := map[string]bool{"Authorization": true, "Cookie": true, "Referer": true, "User-Agent": true,
        "Accept": true, "Accept-Language": true, "Origin": true, "Sec-Ch-Ua": true}
    sanitized := http.Header{}
    seen := map[string]bool{}
    total := 0
    for raw, list := range values {
        key := http.CanonicalHeaderKey(raw)
        if !allowed[key] || len(list) != 1 || seen[key] { return errors.New("invalid runtime credential headers") }
        seen[key] = true
        value := list[0]
        total += len(key) + len(value)
        if total > 64*1024 || strings.ContainsFunc(value, func(r rune) bool { return r < 32 || r == 127 }) {
            return errors.New("invalid runtime credential headers")
        }
        if !yunxSameOrigin(original, request.URL) && (key == "Cookie" || key == "Authorization") { continue }
        sanitized.Set(key, value)
    }
    if request.Header == nil { request.Header = http.Header{} }
    for _, key := range []string{"Cookie", "Authorization", "Proxy-Authorization", "Host"} { request.Header.Del(key) }
    request.Host = ""
    for key, list := range sanitized { request.Header[key] = list }
    return nil
}

func YunxGuardRuntimeHeaderRedirects(id, originalURL string, client *http.Client) {
    if id == "" { return }
    // A server cookie jar must not restore credentials stripped at a redirect.
    client.Jar = nil
    previous := client.CheckRedirect
    client.CheckRedirect = func(request *http.Request, via []*http.Request) error {
        if len(via) >= 10 { return errors.New("too many native download redirects") }
        if previous != nil { if err := previous(request, via); err != nil { return err } }
        return YunxApplyRuntimeHeaders(id, originalURL, request)
    }
}
