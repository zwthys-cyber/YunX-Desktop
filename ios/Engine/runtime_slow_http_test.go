// SPDX-License-Identifier: AGPL-3.0-only
package base

import (
    "context"
    "errors"
    "io"
    "testing"
    "time"
)

type yunxBlockedResponse struct { context.Context }
func (r yunxBlockedResponse) Read([]byte) (int, error) { <-r.Done(); return 0, r.Err() }

func TestYunxSlowHTTPInterruptsAStalledRequest(t *testing.T) {
    if err := YunxSetNativeHTTPSlowConnections(true, 4, 5); err != nil { t.Fatal(err) }
    defer YunxSetNativeHTTPSlowConnections(false, 12, 15)
    ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
    defer cancel()
    reader := YunxSlowNativeHTTPReader(ctx, yunxBlockedResponse{ctx}, cancel, nil)
    start := time.Now()
    _, err := reader.Read(make([]byte, 1024))
    if !YunxIsSlowHTTPConnection(err) || time.Since(start) > 10*time.Second { t.Fatalf("slow request was not interrupted: %v", err) }
}

func TestYunxSlowHTTPDoesNotPreemptAnActiveRateBudget(t *testing.T) {
    if err := YunxSetNativeHTTPSlowConnections(true, 4, 5); err != nil { t.Fatal(err) }
    defer YunxSetNativeHTTPSlowConnections(false, 12, 15)
    if err := YunxSetNativeHTTPBandwidthLimit(1024); err != nil { t.Fatal(err) }
    defer YunxSetNativeHTTPBandwidthLimit(0)
    ctx, cancel := context.WithTimeout(context.Background(), 6500*time.Millisecond)
    defer cancel()
    reader := YunxSlowNativeHTTPReader(ctx, yunxBlockedResponse{ctx}, cancel, nil)
    _, err := reader.Read(make([]byte, 1024))
    if !errors.Is(err, context.DeadlineExceeded) { t.Fatalf("rate-limited response was preempted: %v", err) }
}

func TestYunxSlowHTTPPrefetchHandoffDoesNotCancelItsKeptResponse(t *testing.T) {
    if err := YunxSetNativeHTTPSlowConnections(true, 4, 5); err != nil { t.Fatal(err) }
    defer YunxSetNativeHTTPSlowConnections(false, 12, 15)
    ctx, cancel := context.WithTimeout(context.Background(), 6500*time.Millisecond)
    defer cancel()
    stop := make(chan struct{})
    reader := YunxSlowNativeHTTPReader(ctx, yunxBlockedResponse{ctx}, cancel, stop)
    close(stop)
    _, err := reader.Read(make([]byte, 1024))
    if !errors.Is(err, context.DeadlineExceeded) { t.Fatalf("retired prefetch monitor cancelled the response: %v", err) }
}

var _ io.Reader = yunxBlockedResponse{}
