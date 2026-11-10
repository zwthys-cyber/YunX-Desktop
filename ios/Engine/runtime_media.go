// SPDX-License-Identifier: AGPL-3.0-only
package base

import "sync"

// The host validates local media containers without serializing callbacks.
// 0 means unavailable/retryable, 1 valid, 2 definitively invalid.
var yunxMedia struct {
    sync.RWMutex
    verify func(string, string) int
}

func YunxSetMediaVerifier(verify func(string, string) int) {
    yunxMedia.Lock()
    yunxMedia.verify = verify
    yunxMedia.Unlock()
}

func YunxVerifyMedia(path, kind string) int {
    if kind != "image" && kind != "video" { return 2 }
    yunxMedia.RLock()
    verify := yunxMedia.verify
    yunxMedia.RUnlock()
    if verify == nil { return 0 }
    result := verify(path, kind)
    if result != 1 && result != 2 { return 0 }
    return result
}
