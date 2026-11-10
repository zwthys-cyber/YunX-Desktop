// SPDX-License-Identifier: AGPL-3.0-only
package http

import (
    "bytes"
    "net/http"
    "net/http/httptest"
    "strconv"
    "testing"
    "time"
    "github.com/GopeedLab/gopeed/pkg/base"
    fhttp "github.com/GopeedLab/gopeed/pkg/protocol/http"
)

func TestYunxExpectedSizeRejectsWrongBodyWithoutOptionalChecksum(t *testing.T) {
    payload := bytes.Repeat([]byte{0x57}, 32768)
    server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        http.ServeContent(w, r, "fixture.bin", time.Time{}, bytes.NewReader(payload))
    }))
    defer server.Close()
    for _, expected := range []int{len(payload), len(payload)+1} {
        f := buildFetcher()
        f.Meta().Opts = &base.Options{Path: t.TempDir(), Name: "fixture.bin", Extra: &fhttp.OptsExtra{Connections: 1}}
        request := &base.Request{URL: server.URL, Labels: map[string]string{"yunxExpectedSize": strconv.Itoa(expected)}}
        if err := f.Resolve(request); err != nil { f.Close(); t.Fatal(err) }
        startErr := f.Start()
        result := startErr
        if startErr == nil { result = f.Wait() }
        f.Close()
        if expected == len(payload) && result != nil { t.Fatal(result) }
        if expected != len(payload) && result == nil { t.Fatal("incorrect platform size became a completed download") }
    }
}
