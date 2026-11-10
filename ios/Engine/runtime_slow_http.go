// SPDX-License-Identifier: AGPL-3.0-only
package base

import (
    "context"
    "errors"
    "io"
    "sync"
    "sync/atomic"
    "time"
)

var yunxSlowHTTP = struct {
    sync.RWMutex
    enabled bool
    minimumKiB int
    seconds int
}{minimumKiB: 12, seconds: 15}

var errYunxSlowHTTP = errors.New("native HTTP connection stayed below the configured minimum speed")
func YunxIsSlowHTTPConnection(err error) bool { return errors.Is(err, errYunxSlowHTTP) }

func YunxSetNativeHTTPSlowConnections(enabled bool, minimumKiB, seconds int) error {
    if minimumKiB < 4 || minimumKiB > 10240 || seconds < 5 || seconds > 600 { return errors.New("invalid slow HTTP connection policy") }
    yunxSlowHTTP.Lock()
    yunxSlowHTTP.enabled, yunxSlowHTTP.minimumKiB, yunxSlowHTTP.seconds = enabled, minimumKiB, seconds
    yunxSlowHTTP.Unlock()
    return nil
}
type yunxSlowHTTPReader struct {
    next io.Reader
    bytes atomic.Int64
    slow atomic.Bool
    done chan struct{}
    finish sync.Once
}
func (r *yunxSlowHTTPReader) Read(buffer []byte) (int, error) {
    n, err := r.next.Read(buffer)
    r.bytes.Add(int64(n))
    if r.slow.Load() { err = errYunxSlowHTTP }
    if err != nil { r.finish.Do(func() { close(r.done) }) }
    return n, err
}

// The caller must first check Range and If-Range support. Cancelling only the
// response request allows the existing range worker to retry its written prefix.
func YunxSlowNativeHTTPReader(ctx context.Context, next io.Reader, cancel context.CancelFunc, stop <-chan struct{}) io.Reader {
    yunxSlowHTTP.RLock()
    enabled, minimum, seconds := yunxSlowHTTP.enabled, yunxSlowHTTP.minimumKiB, yunxSlowHTTP.seconds
    yunxSlowHTTP.RUnlock()
    if !enabled || cancel == nil { return next }
    reader := &yunxSlowHTTPReader{next: next, done: make(chan struct{})}
    go func() {
        start, baseline := time.Now(), int64(0)
        ticker := time.NewTicker(time.Second)
        defer ticker.Stop()
        for {
            select {
            case <-ctx.Done(): return
            case <-stop: return // Stop the old prefetch monitor before a response handoff.
            case <-reader.done: return
            case now := <-ticker.C:
                total := reader.bytes.Load()
                if YunxNativeHTTPBandwidthLimited() {
                    start, baseline = now, total
                    continue
                }
                elapsed := now.Sub(start)
                if elapsed < time.Duration(seconds)*time.Second { continue }
                if float64(total-baseline)/elapsed.Seconds() < float64(minimum*1024) {
                    reader.slow.Store(true)
                    cancel()
                    return
                }
                start, baseline = now, total
            }
        }
    }()
    return reader
}
