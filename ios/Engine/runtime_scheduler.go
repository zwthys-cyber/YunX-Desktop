// SPDX-License-Identifier: AGPL-3.0-only
package base

import (
    "strconv"
    "strings"
    "sync"
)

var yunxSlots = struct {
    sync.Mutex
    limit int
    restoring bool
    held map[string]bool
}{held: make(map[string]bool)}

func YunxSetDownloadLimit(limit int) {
    yunxSlots.Lock(); defer yunxSlots.Unlock()
    yunxSlots.limit = limit
}
func YunxSetHTTPRestoring(value bool) {
    yunxSlots.Lock(); yunxSlots.restoring = value; yunxSlots.Unlock()
}
func YunxSchedulerEnabled() bool {
    yunxSlots.Lock(); defer yunxSlots.Unlock(); return yunxSlots.limit > 0
}
func YunxAcquireSlot(key string, adopt bool) bool {
    yunxSlots.Lock(); defer yunxSlots.Unlock()
    if yunxSlots.held[key] { return true }
    if !adopt && yunxSlots.limit > 0 && (yunxSlots.restoring || len(yunxSlots.held) >= yunxSlots.limit) { return false }
    if yunxSlots.limit > 0 || adopt { yunxSlots.held[key] = true }
    return true
}
func YunxReleaseSlot(key string) { yunxSlots.Lock(); delete(yunxSlots.held, key); yunxSlots.Unlock() }
func YunxAvailableSlots() int {
    yunxSlots.Lock(); defer yunxSlots.Unlock()
    if yunxSlots.limit <= 0 { return 1 << 20 }
    if yunxSlots.restoring { return 0 }
    return max(0, yunxSlots.limit-len(yunxSlots.held))
}
func YunxNativeCapacity() int {
    yunxSlots.Lock(); defer yunxSlots.Unlock()
    if yunxSlots.limit <= 0 { return 1 << 20 }
    if yunxSlots.restoring { return 0 }
    count := 0
    for key := range yunxSlots.held { if strings.HasPrefix(key, "session:") { count++ } }
    return max(0, yunxSlots.limit-count)
}
func YunxNativeSlot(id string, generation uint64) string { return "engine:" + id + ":" + strconv.FormatUint(generation, 10) }
func YunxReleaseNativeSlots() {
    yunxSlots.Lock(); defer yunxSlots.Unlock()
    for key := range yunxSlots.held { if strings.HasPrefix(key, "engine:") { delete(yunxSlots.held, key) } }
}
