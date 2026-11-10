// SPDX-License-Identifier: AGPL-3.0-only
// Small gomobile bridge. The engine runs in-process; no HTTP API is exposed.
package yunxengine

import (
    "encoding/json"
    "errors"
    "strings"
    "github.com/GopeedLab/gopeed/pkg/rest"
    "github.com/GopeedLab/gopeed/pkg/rest/model"
)

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

func Stop() { rest.Stop() }

func ServerRunning() bool {
    state, err := rest.GetAPIServerState()
    return err == nil && state != nil && state.Running
}
