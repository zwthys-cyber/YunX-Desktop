// SPDX-License-Identifier: AGPL-3.0-only
package http

import (
    "errors"
    "net"
    "net/url"
    "os"
    "strings"

    "github.com/GopeedLab/gopeed/pkg/base"
    fhttp "github.com/GopeedLab/gopeed/pkg/protocol/http"
)

// The downloader holds the task/status locks and has already stopped workers.
// Keep the old strong ETag pinned: a new source must honor its If-Range value.
func (f *Fetcher) YunxRebindCloudSource(req *base.Request, expectedSize int64) (bool, error) {
    if req == nil { return false, errors.New("missing replacement request") }
    target, err := url.Parse(req.URL)
    if err != nil || target.Hostname() == "" || target.User != nil { return false, errors.New("invalid replacement source") }
    loopback := strings.EqualFold(target.Hostname(), "localhost")
    if ip := net.ParseIP(target.Hostname()); ip != nil { loopback = ip.IsLoopback() }
    if target.Scheme != "https" && !(target.Scheme == "http" && loopback) { return false, errors.New("unsafe replacement source") }
    if err := base.ParseReqExtra[fhttp.ReqExtra](req); err != nil { return false, err }
    extra, ok := req.Extra.(*fhttp.ReqExtra)
    if !ok || extra == nil || extra.Method != "GET" || extra.Body != "" { return false, errors.New("invalid replacement request") }
    allowed := map[string]bool{"user-agent": true, "referer": true, "accept": true, "accept-language": true, "origin": true, "sec-ch-ua": true}
    for key, value := range extra.Header {
        if !allowed[strings.ToLower(key)] || strings.ContainsAny(value, "\r\n\x00") { return false, errors.New("replacement headers must use the runtime vault") }
    }
    f.connMu.Lock()
    defer f.connMu.Unlock()
    state := f.getState()
    if state != statePaused && state != stateResolved && state != stateError { return false, nil }
    if f.meta == nil || f.meta.Req == nil || f.meta.Opts == nil || f.meta.Res == nil || len(f.meta.Res.Files) != 1 ||
        !f.meta.Res.Range || !f.hasKnownSize() || expectedSize <= 0 || f.knownSize() != expectedSize ||
        !isStrongETag(f.ifRange) || !f.rangeValidatorPinned || f.checksumFailed.Load() {
        return false, nil
    }
    info, err := os.Lstat(f.meta.SingleFilepath())
    if err != nil || !info.Mode().IsRegular() || info.Size() <= 0 || info.Size() > expectedSize { return false, nil }
    var received int64
    for _, connection := range f.connections {
        if connection == nil || connection.Chunk == nil || connection.Downloaded < 0 || connection.Downloaded > expectedSize-received { return false, nil }
        chunk := connection.Chunk
        if chunk.Begin < 0 || chunk.Begin > expectedSize || chunk.Downloaded < 0 || chunk.Downloaded > expectedSize-chunk.Begin { return false, nil }
        if chunk.Downloaded > 0 && chunk.Begin+chunk.Downloaded > info.Size() { return false, nil }
        received += connection.Downloaded
    }
    if received <= 0 || received >= expectedSize { return false, nil }
    f.meta.Req.URL, f.meta.Req.RawURL = req.URL, req.URL
    f.meta.Req.Extra = extra // Replace; never merge stale headers from another source.
    if f.meta.Req.Labels == nil { f.meta.Req.Labels = map[string]string{} }
    for key, value := range req.Labels { f.meta.Req.Labels[key] = value }
    f.updateRedirectURL("")
    if f.impersonationSession != nil { f.impersonationSession.Clear() }
    return true, nil
}
