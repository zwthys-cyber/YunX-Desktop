// SPDX-License-Identifier: AGPL-3.0-only
package rest

import (
    "encoding/json"
    "errors"
    "github.com/GopeedLab/gopeed/pkg/base"
)

func RebindCloudHTTPSource(id, expectedContext string, size int64, raw string) (bool, error) {
    runtimeMu.Lock()
    defer runtimeMu.Unlock()
    if Downloader == nil || len(raw) > 256*1024 { return false, errors.New("cloud source refresh unavailable") }
    var request base.Request
    if err := json.Unmarshal([]byte(raw), &request); err != nil { return false, err }
    return Downloader.YunxRebindCloudSource(id, expectedContext, size, &request)
}
