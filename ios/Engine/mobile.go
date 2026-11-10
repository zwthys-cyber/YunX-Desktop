// SPDX-License-Identifier: AGPL-3.0-only
// Small gomobile bridge. The engine runs in-process; no HTTP API is exposed.
package yunxengine

import (
    "encoding/json"
    "errors"
    "net"
    "net/http"
    "net/url"
    "strconv"
    "strings"
    "github.com/GopeedLab/gopeed/pkg/base"
    "github.com/GopeedLab/gopeed/pkg/rest"
    "github.com/GopeedLab/gopeed/pkg/rest/model"
)

// Implemented by Swift using iOS system proxy settings or the app's Keychain
// profile. The callback is evaluated per HTTP request and is never serialized.
type ProxyResolver interface { Resolve(rawURL string) string }

func SetGlobalDownloadLimit(limit int) { base.YunxSetDownloadLimit(max(1, min(6, limit))) }
func SetHTTPRestoring(value bool) { base.YunxSetHTTPRestoring(value) }
func SetNativeHTTPBandwidthLimit(bytesPerSecond int64) error { return base.YunxSetNativeHTTPBandwidthLimit(bytesPerSecond) }
func AvailableDownloadSlots() int { return base.YunxAvailableSlots() }
func AcquireHTTPTask(id string, adopt bool) bool {
    if id == "" || len(id) > 128 { return false }
    return base.YunxAcquireSlot("session:"+id, adopt)
}
func ReleaseHTTPTask(id string) { base.YunxReleaseSlot("session:"+id) }

func SetProxyResolver(resolver ProxyResolver) error {
    if resolver == nil { return errors.New("missing runtime proxy resolver") }
    base.SetRuntimeProxyResolver(func(request *http.Request) (*url.URL, error) {
        if request == nil || request.URL == nil { return nil, errors.New("invalid proxy request") }
        host := request.URL.Hostname()
        if strings.EqualFold(host, "localhost") { return nil, nil }
        if ip := net.ParseIP(host); ip != nil && ip.IsLoopback() { return nil, nil }
        raw := resolver.Resolve(request.URL.String())
        if len(raw) > 32768 { return nil, errors.New("invalid runtime proxy response") }
        var value struct {
            Direct bool `json:"direct"`
            Error bool `json:"error"`
            Scheme string `json:"scheme"`
            Host string `json:"host"`
            Port int `json:"port"`
            Username string `json:"username"`
            Password string `json:"password"`
        }
        if json.Unmarshal([]byte(raw), &value) != nil || value.Error { return nil, errors.New("iOS proxy settings unavailable or PAC unsupported") }
        if value.Direct { return nil, nil }
        if value.Scheme != "http" && value.Scheme != "https" && value.Scheme != "socks5" { return nil, errors.New("invalid proxy scheme") }
        if value.Host == "" || len(value.Host) > 253 || strings.ContainsAny(value.Host, "/\\@?# \r\n\t") || value.Port < 1 || value.Port > 65535 { return nil, errors.New("invalid proxy endpoint") }
        proxy := &url.URL{Scheme: value.Scheme, Host: net.JoinHostPort(value.Host, strconv.Itoa(value.Port))}
        if value.Username != "" { proxy.User = url.UserPassword(value.Username, value.Password) }
        return proxy, nil
    })
    return nil
}

func Start(config string) (int, error) {
    var cfg model.StartConfig
    if err := json.Unmarshal([]byte(config), &cfg); err != nil { return 0, errors.New("invalid engine configuration") }
    disabled := false
    cfg.ApiEnable = &disabled
    cfg.MCPEnable = false
    cfg.WebEnable = false
    cfg.ProductionMode = true
    cfg.NativeMode = true
    return rest.Start(&cfg)
}

func Invoke(method, path, query, body string) string {
    if path != "/api/v1/info" && path != "/api/v1/config" && path != "/api/v1/resolve" && !strings.HasPrefix(path, "/api/v1/tasks") {
        return `{"code":1002,"msg":"unsupported operation"}`
    }
    return rest.Dispatch(method, path, query, body)
}

func Stop() { rest.Stop(); base.YunxReleaseNativeSlots() }

// Migration must observe close failures rather than relying on log-only Stop.
func StopForStorage() error {
    closeErr := rest.StopForStorage()
    base.YunxReleaseNativeSlots()
    if closeErr != nil { return errors.New("engine files could not be closed safely") }
    return nil
}

func ServerRunning() bool {
    state, err := rest.GetAPIServerState()
    return err == nil && state != nil && state.Running
}
