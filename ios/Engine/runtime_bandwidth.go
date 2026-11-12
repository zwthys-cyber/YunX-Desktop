// SPDX-License-Identifier: AGPL-3.0-only
package base

import (
    "context"
    "errors"
    "io"
    "sync"
    "golang.org/x/time/rate"
)

var yunxBandwidth struct {
    sync.RWMutex
    value int64
    limiter *rate.Limiter
    epoch context.Context
    cancel context.CancelFunc
}

func YunxNativeHTTPBandwidthLimited() bool {
    yunxBandwidth.RLock()
    defer yunxBandwidth.RUnlock()
    return yunxBandwidth.limiter != nil
}

// Shared by native HTTP files and HLS origin readers. Production's local HTTP
// relay stays unwrapped so the same HLS bytes are not charged a second time.
func YunxSetNativeHTTPBandwidthLimit(bytesPerSecond int64) error {
    if bytesPerSecond != 0 && (bytesPerSecond < 1024 || bytesPerSecond > 1<<30) {
        return errors.New("invalid native HTTP bandwidth limit")
    }
    yunxBandwidth.Lock()
    if yunxBandwidth.value == bytesPerSecond { yunxBandwidth.Unlock(); return nil }
    oldCancel := yunxBandwidth.cancel
    yunxBandwidth.value = bytesPerSecond
    yunxBandwidth.limiter, yunxBandwidth.epoch, yunxBandwidth.cancel = nil, nil, nil
    if bytesPerSecond > 0 {
        burst := int(max(1024, min(64*1024, bytesPerSecond/10)))
        yunxBandwidth.limiter = rate.NewLimiter(rate.Limit(bytesPerSecond), burst)
        yunxBandwidth.epoch, yunxBandwidth.cancel = context.WithCancel(context.Background())
    }
    yunxBandwidth.Unlock()
    if oldCancel != nil { oldCancel() }
    return nil
}

func YunxWaitNativeHTTPBytes(ctx context.Context, count int) error {
    for count > 0 {
        if err := ctx.Err(); err != nil { return err }
        yunxBandwidth.RLock()
        limiter, epoch := yunxBandwidth.limiter, yunxBandwidth.epoch
        yunxBandwidth.RUnlock()
        if limiter == nil { return nil }
        amount := min(count, limiter.Burst())
        waiting, cancel := context.WithCancel(ctx)
        stop := context.AfterFunc(epoch, cancel)
        err := limiter.WaitN(waiting, amount)
        stop(); cancel()
        // A setting change retires reservations on the old bucket and retries
        // this amount on the new configuration. Pausing cancels immediately.
        if epoch.Err() != nil && ctx.Err() == nil { continue }
        if err != nil { return err }
        count -= amount
    }
    return nil
}

type yunxBandwidthReader struct {
    ctx context.Context
    reader io.Reader
    finish context.CancelFunc
}

// The network-only timeout reader belongs inside this reader: intentional
// rate waits must not be diagnosed as a stalled network connection.
func YunxNativeHTTPReader(ctx context.Context, reader io.Reader, stop <-chan struct{}) io.Reader {
    finish := func() {}
    if stop != nil {
        child, cancel := context.WithCancel(ctx)
        ctx, finish = child, cancel
        go func() { select { case <-stop: cancel(); case <-child.Done(): } }()
    }
    return &yunxBandwidthReader{ctx: ctx, reader: reader, finish: finish}
}

func (r *yunxBandwidthReader) Read(buffer []byte) (int, error) {
    if err := r.ctx.Err(); err != nil { r.finish(); return 0, err }
    yunxBandwidth.RLock()
    limited := yunxBandwidth.limiter != nil
    yunxBandwidth.RUnlock()
    if limited && len(buffer) > 16*1024 { buffer = buffer[:16*1024] }
    n, err := r.reader.Read(buffer)
    if n > 0 {
        if waitErr := YunxWaitNativeHTTPBytes(r.ctx, n); waitErr != nil { r.finish(); return 0, waitErr }
        if ctxErr := r.ctx.Err(); ctxErr != nil { r.finish(); return 0, ctxErr }
    }
    if err != nil { r.finish() }
    return n, err
}
