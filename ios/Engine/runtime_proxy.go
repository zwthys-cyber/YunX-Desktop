// SPDX-License-Identifier: AGPL-3.0-only
// Copied into upstream pkg/base by the iOS build script. Runtime credentials are
// deliberately absent from DownloaderStoreConfig and persisted task metadata.
package base

import (
    "net/http"
    "net/url"
    "sync"
)

var yunxProxy struct {
    sync.RWMutex
    resolve func(*http.Request) (*url.URL, error)
}

func SetRuntimeProxyResolver(resolve func(*http.Request) (*url.URL, error)) {
    yunxProxy.Lock()
    yunxProxy.resolve = resolve
    yunxProxy.Unlock()
}

func RuntimeProxyOverride() (func(*http.Request) (*url.URL, error), bool) {
    yunxProxy.RLock()
    enabled := yunxProxy.resolve != nil
    yunxProxy.RUnlock()
    if !enabled { return nil, false }
    return func(request *http.Request) (*url.URL, error) {
        yunxProxy.RLock()
        resolve := yunxProxy.resolve
        yunxProxy.RUnlock()
        if resolve == nil { return nil, nil }
        return resolve(request)
    }, true
}
