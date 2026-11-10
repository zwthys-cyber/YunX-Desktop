// SPDX-License-Identifier: AGPL-3.0-only
package rest

// Keep upstream's shutdown order while reporting errors to the migration UI.
// Event subscribers must be detached before pausing and closing the downloader.
func StopForStorage() error {
    runtimeMu.Lock()
    defer runtimeMu.Unlock()
    failure := apiServer.stopLocked()
    if APIService != nil { APIService.SubscribeTaskEvents(0, nil) }
    if Downloader != nil {
        if err := Downloader.Close(); err != nil { failure = err }
    }
    APIService = nil
    apiServer = &apiServerManager{}
    return failure
}
