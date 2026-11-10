// SPDX-License-Identifier: AGPL-3.0-only
package base

import (
    "bytes"
    "context"
    "testing"
)

func TestYunxNativeHTTPBufferBudgetAndValidation(t *testing.T) {
    defer YunxSetNativeHTTPTransport(false, 64)
    if err := YunxSetNativeHTTPTransport(true, 4096); err != nil { t.Fatal(err) }
    if !YunxNativeHTTP2Enabled() { t.Fatal("HTTP/2 choice was not applied") }
    if got := YunxNativeHTTPReadBuffer(1); got != 4*1024*1024 { t.Fatalf("single worker buffer: %d", got) }
    if got := YunxNativeHTTPReadBuffer(512); got != 128*1024 { t.Fatalf("512-worker budget: %d", got) }
    for _, value := range []int{-1, 0, 15, 4097} {
        if YunxSetNativeHTTPTransport(false, value) == nil { t.Fatalf("accepted invalid buffer %d", value) }
        if !YunxNativeHTTP2Enabled() { t.Fatal("rejected setting changed active configuration") }
    }
}

func TestYunxUnlimitedHTTPReaderUsesConfiguredReadCapacity(t *testing.T) {
    if err := YunxSetNativeHTTPBandwidthLimit(0); err != nil { t.Fatal(err) }
    data := bytes.Repeat([]byte{0x47}, 1024*1024)
    reader := YunxNativeHTTPReader(context.Background(), bytes.NewReader(data), nil)
    buffer := make([]byte, len(data))
    n, err := reader.Read(buffer)
    if err != nil || n != len(data) || !bytes.Equal(buffer, data) {
        t.Fatalf("unlimited reader retained a smaller fixed read cap: n=%d err=%v", n, err)
    }
}
