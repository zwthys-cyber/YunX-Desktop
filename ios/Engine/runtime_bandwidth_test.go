// SPDX-License-Identifier: AGPL-3.0-only
package base

import (
    "bytes"
    "context"
    "errors"
    "io"
    "testing"
    "time"
)

func TestYunxNativeHTTPReadersShareOneBudget(t *testing.T) {
    if err := YunxSetNativeHTTPBandwidthLimit(256*1024); err != nil { t.Fatal(err) }
    defer YunxSetNativeHTTPBandwidthLimit(0)
    ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
    defer cancel()
    done := make(chan error, 8)
    start := time.Now()
    for i := 0; i < 8; i++ {
        go func() {
            reader := YunxNativeHTTPReader(ctx, bytes.NewReader(make([]byte, 64*1024)), nil)
            _, err := io.Copy(io.Discard, reader)
            done <- err
        }()
    }
    for i := 0; i < 8; i++ { if err := <-done; err != nil { t.Error(err) } }
    if elapsed := time.Since(start); elapsed < 1500*time.Millisecond {
        t.Fatalf("512 KiB crossed a shared 256 KiB/s budget in %v", elapsed)
    }
}

func TestYunxNativeHTTPBudgetReconfigurationWakesWaiters(t *testing.T) {
    if err := YunxSetNativeHTTPBandwidthLimit(1024); err != nil { t.Fatal(err) }
    defer YunxSetNativeHTTPBandwidthLimit(0)
    done := make(chan error, 1)
    go func() { done <- YunxWaitNativeHTTPBytes(context.Background(), 1024*1024) }()
    time.Sleep(20*time.Millisecond)
    if err := YunxSetNativeHTTPBandwidthLimit(0); err != nil { t.Fatal(err) }
    select {
    case err := <-done: if err != nil { t.Fatal(err) }
    case <-time.After(time.Second): t.Fatal("disabled budget retained an old reservation")
    }
}

func TestYunxNativeHTTPPrefetchStopCancelsRateWait(t *testing.T) {
    if err := YunxSetNativeHTTPBandwidthLimit(1024); err != nil { t.Fatal(err) }
    defer YunxSetNativeHTTPBandwidthLimit(0)
    stop := make(chan struct{})
    reader := YunxNativeHTTPReader(context.Background(), bytes.NewReader(make([]byte, 32*1024)), stop)
    done := make(chan error, 1)
    go func() { _, err := reader.Read(make([]byte, 16*1024)); done <- err }()
    time.Sleep(20*time.Millisecond)
    close(stop)
    select {
    case err := <-done: if !errors.Is(err, context.Canceled) { t.Fatalf("stop returned %v", err) }
    case <-time.After(time.Second): t.Fatal("prefetch stop waited for low-rate tokens")
    }
}

func TestYunxNativeHTTPBudgetRejectsInvalidLimits(t *testing.T) {
    for _, limit := range []int64{-1, 1, 1023, (1<<30)+1} {
        if YunxSetNativeHTTPBandwidthLimit(limit) == nil { t.Fatalf("accepted %d", limit) }
    }
}
