// SPDX-License-Identifier: AGPL-3.0-only
package base

import (
    "fmt"
    "sync"
    "testing"
)

func TestYunxSharedSlotsAreAtomicAndGenerationSafe(t *testing.T) {
    YunxSetDownloadLimit(3)
    defer YunxSetDownloadLimit(0)
    acquired := make(chan string, 32)
    var workers sync.WaitGroup
    for i := 0; i < 32; i++ {
        workers.Add(1)
        go func(i int) {
            defer workers.Done()
            key := fmt.Sprintf("session:fixture-%d", i)
            if YunxAcquireSlot(key, false) { acquired <- key }
        }(i)
    }
    workers.Wait(); close(acquired)
    var keys []string
    for key := range acquired { keys = append(keys, key) }
    defer func() { for _, key := range keys { YunxReleaseSlot(key) }; YunxReleaseNativeSlots() }()
    if len(keys) != 3 || YunxAvailableSlots() != 0 { t.Fatal("shared quota was exceeded") }
    if !YunxAcquireSlot(keys[0], false) { t.Fatal("duplicate reservation was not idempotent") }
    for _, key := range keys { YunxReleaseSlot(key) }
    old := YunxNativeSlot("fixture", 1)
    current := YunxNativeSlot("fixture", 3)
    if !YunxAcquireSlot(old, false) || !YunxAcquireSlot(current, false) { t.Fatal("generation reservation failed") }
    YunxReleaseSlot(old); YunxReleaseSlot(old)
    if YunxAvailableSlots() != 2 { t.Fatal("late pause released the newer generation") }
}

func TestYunxRestoreBarrierAdoptsExistingTransfersWithoutStartingNewOnes(t *testing.T) {
    YunxSetDownloadLimit(1); YunxSetHTTPRestoring(true)
    defer func() { YunxReleaseSlot("session:restored"); YunxSetHTTPRestoring(false); YunxSetDownloadLimit(0) }()
    if YunxAcquireSlot(YunxNativeSlot("fixture", 1), false) { t.Fatal("native task started during background restoration") }
    if !YunxAcquireSlot("session:restored", true) { t.Fatal("existing transfer could not be adopted") }
    YunxSetHTTPRestoring(false)
    if YunxNativeCapacity() != 0 || YunxAvailableSlots() != 0 { t.Fatal("restored transfer was not counted") }
    YunxReleaseSlot("session:restored")
    if YunxNativeCapacity() != 1 || YunxAvailableSlots() != 1 { t.Fatal("released transfer still consumes quota") }
}
