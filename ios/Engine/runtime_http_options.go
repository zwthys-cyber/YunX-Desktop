// SPDX-License-Identifier: AGPL-3.0-only
package base

import (
    "errors"
    "sync"
)

var yunxHTTPOptions = struct {
    sync.RWMutex
    http2 bool
    bufferKiB int
}{bufferKiB: 64}

func YunxSetNativeHTTPTransport(http2 bool, bufferKiB int) error {
    if bufferKiB < 16 || bufferKiB > 4096 { return errors.New("invalid native HTTP buffer size") }
    yunxHTTPOptions.Lock()
    yunxHTTPOptions.http2, yunxHTTPOptions.bufferKiB = http2, bufferKiB
    yunxHTTPOptions.Unlock()
    return nil
}
func YunxNativeHTTP2Enabled() bool {
    yunxHTTPOptions.RLock()
    defer yunxHTTPOptions.RUnlock()
    return yunxHTTPOptions.http2
}
func YunxNativeHTTPReadBuffer(connections int) int {
    yunxHTTPOptions.RLock()
    requested := yunxHTTPOptions.bufferKiB * 1024
    yunxHTTPOptions.RUnlock()
    // Never allocate gigabytes when a large buffer meets hundreds of workers.
    return min(requested, (64*1024*1024)/max(1, min(512, connections)))
}
