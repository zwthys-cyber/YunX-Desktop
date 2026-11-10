// SPDX-License-Identifier: AGPL-3.0-only
package base

import (
    "encoding/json"
    "testing"
)

func TestYunxStartupPatchMergesSavedPreferencesBeforeProtocolSetup(t *testing.T) {
    var current DownloaderStoreConfig
    if err := json.Unmarshal([]byte(`{"maxRunning":5,"autoStartTasks":true,"protocolConfig":{"bt":{"disableDht":false,"customTrackers":[],"preservedFixtureOption":23}}}`), &current); err != nil { t.Fatal(err) }
    if err := YunxSetStartupDownloadPatch(json.RawMessage(`{"maxRunning":1,"autoStartTasks":false,"protocolConfig":{"bt":{"disableDht":true,"customTrackers":["http://127.0.0.1:9/announce"]}}}`)); err != nil { t.Fatal(err) }
    defer YunxSetStartupDownloadPatch(nil)
    if err := YunxApplyStartupDownloadPatch(&current); err != nil { t.Fatal(err) }
    encoded, err := json.Marshal(current)
    if err != nil { t.Fatal(err) }
    var result map[string]any
    if err := json.Unmarshal(encoded, &result); err != nil { t.Fatal(err) }
    if result["maxRunning"] != float64(1) || result["autoStartTasks"] != false { t.Fatal("saved concurrency or paused-start preference ignored") }
    bt := result["protocolConfig"].(map[string]any)["bt"].(map[string]any)
    if bt["disableDht"] != true || bt["preservedFixtureOption"] != float64(23) { t.Fatal("nested protocol settings replaced instead of merged") }
}

func TestYunxStartupPatchRejectsNonObjectAndCanBeCleared(t *testing.T) {
    for _, raw := range []string{`[]`, `true`, `"invalid"`} {
        if YunxSetStartupDownloadPatch(json.RawMessage(raw)) == nil { t.Fatal("non-object startup patch accepted") }
    }
    if err := YunxSetStartupDownloadPatch(nil); err != nil { t.Fatal(err) }
    var current DownloaderStoreConfig
    if err := json.Unmarshal([]byte(`{"maxRunning":2}`), &current); err != nil { t.Fatal(err) }
    if err := YunxApplyStartupDownloadPatch(&current); err != nil { t.Fatal(err) }
    encoded, _ := json.Marshal(current)
    var result map[string]any
    _ = json.Unmarshal(encoded, &result)
    if result["maxRunning"] != float64(2) { t.Fatal("cleared override affected ordinary engine callers") }
}
