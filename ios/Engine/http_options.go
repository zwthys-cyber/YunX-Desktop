// SPDX-License-Identifier: AGPL-3.0-only
package http

import (
    "github.com/GopeedLab/gopeed/pkg/base"
    fhttp "github.com/GopeedLab/gopeed/pkg/protocol/http"
)

func (f *Fetcher) yunxReadBufferSize() int {
    connections := 1
    if f.meta != nil && f.meta.Opts != nil {
        if extra, ok := f.meta.Opts.Extra.(*fhttp.OptsExtra); ok && extra != nil { connections = extra.Connections }
    }
    return base.YunxNativeHTTPReadBuffer(connections)
}
