# SPDX-License-Identifier: AGPL-3.0-only
# Executed only by the guarded GitHub/macOS engine build.
from pathlib import Path
import sys

root = Path(sys.argv[1])
path = root / "internal/protocol/http/fetcher.go"
source = path.read_text()
old = "make([]byte, connReadBufferSize)"
if source.count(old) != 3:
    raise SystemExit("Pinned HTTP connection buffer allocations changed")
path.write_text(source.replace(old, "make([]byte, f.yunxReadBufferSize())"))

path = root / "internal/protocol/http/helper.go"
source = path.read_text()
old = "Transport: httpclient.TransportOptions{"
if source.count(old) != 1:
    raise SystemExit("Pinned HTTP transport options changed")
path.write_text(source.replace(old, old + "\n            YunxDisableHTTP2: !base.YunxNativeHTTP2Enabled(),"))

path = root / "internal/httpclient/client.go"
source = path.read_text()
old = "type TransportOptions struct {"
if source.count(old) != 1 or source.count("ForceAttemptHTTP2:   true,") != 1:
    raise SystemExit("Pinned native HTTP/2 transport changed")
source = source.replace(old, old + "\n    YunxDisableHTTP2 bool")
source = source.replace("ForceAttemptHTTP2:   true,", "ForceAttemptHTTP2: !options.YunxDisableHTTP2,")
# An explicitly empty TLSNextProto map disables automatic HTTP/2 registration.
old = "\treturn &http.Transport{"
if source.count(old) != 1:
    raise SystemExit("Pinned native transport construction changed")
source = source.replace(old, """    var nextProto map[string]func(string, *tls.Conn) http.RoundTripper
    if options.YunxDisableHTTP2 {
        nextProto = map[string]func(string, *tls.Conn) http.RoundTripper{}
        if tlsConfig == nil { tlsConfig = &tls.Config{} }
        tlsConfig.NextProtos = []string{"http/1.1"}
    }
    return &http.Transport{
        TLSNextProto: nextProto,""")
# Apply after browser impersonation, so its TLS preset cannot re-enable h2.
old = "\treturn &defaultHeaderTransport{"
if source.count(old) != 1:
    raise SystemExit("Pinned browser transport construction changed")
source = source.replace(old, "    if options.YunxDisableHTTP2 { client.EnableForceHTTP1() }\n" + old)
path.write_text(source)
