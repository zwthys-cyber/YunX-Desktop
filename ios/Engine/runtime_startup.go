// SPDX-License-Identifier: AGPL-3.0-only
package base

import (
    "encoding/json"
    "errors"
    "sync"
)

var yunxStartup struct {
    sync.RWMutex
    patch json.RawMessage
}

func YunxSetStartupDownloadPatch(raw json.RawMessage) error {
    var object map[string]json.RawMessage
    if len(raw) > 4*1024*1024 { return errors.New("native startup configuration too large") }
    if len(raw) != 0 && string(raw) != "null" {
        if err := json.Unmarshal(raw, &object); err != nil || object == nil { return errors.New("invalid native startup configuration") }
    }
    yunxStartup.Lock()
    yunxStartup.patch = append(json.RawMessage(nil), raw...)
    yunxStartup.Unlock()
    return nil
}

func yunxMergeConfigObjects(current, patch map[string]json.RawMessage) {
    for key, incoming := range patch {
        var oldObject, newObject map[string]json.RawMessage
        if json.Unmarshal(current[key], &oldObject) == nil && oldObject != nil &&
            json.Unmarshal(incoming, &newObject) == nil && newObject != nil {
            yunxMergeConfigObjects(oldObject, newObject)
            merged, _ := json.Marshal(oldObject)
            current[key] = merged
        } else { current[key] = incoming }
    }
}

// Applied after loading stored settings but before protocol initialization or
// task restoration. Explicit iOS preferences override only their own fields.
func YunxApplyStartupDownloadPatch(current *DownloaderStoreConfig) error {
    yunxStartup.RLock(); raw := yunxStartup.patch; yunxStartup.RUnlock()
    if len(raw) == 0 || string(raw) == "null" { return nil }
    var patch, stored map[string]json.RawMessage
    if err := json.Unmarshal(raw, &patch); err != nil { return errors.New("invalid native startup patch") }
    encoded, err := json.Marshal(current)
    if err != nil { return err }
    if err := json.Unmarshal(encoded, &stored); err != nil || stored == nil { return errors.New("missing native startup settings") }
    yunxMergeConfigObjects(stored, patch)
    encoded, err = json.Marshal(stored)
    if err != nil { return err }
    var merged DownloaderStoreConfig
    if err := json.Unmarshal(encoded, &merged); err != nil { return err }
    *current = merged
    return nil
}
