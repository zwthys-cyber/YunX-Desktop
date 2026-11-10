# SPDX-License-Identifier: AGPL-3.0-only
# Applied only inside the guarded macOS/GitHub build.
from pathlib import Path
import sys

path = Path(sys.argv[1]) / "internal/protocol/http/helper.go"
source = path.read_text()
request = "\thttpReq.Header = headers\n"
client = '\t\tpanic(fmt.Sprintf("build HTTP client: %v", err))\n\t}\n\treturn client\n'
jar = "\tjar, _ := cookiejar.New(nil)\n"
if source.count(request) != 1 or source.count(client) != 1 or source.count(jar) != 1:
    raise SystemExit("Pinned native credential hooks changed")
source = source.replace(request, request + '''    if err = base.YunxApplyRuntimeHeaders(req.Labels[base.YunxHeaderContextLabel], req.URL, httpReq); err != nil { return nil, err }
''')
# The adaptive browser transport captures the jar at construction time; clearing
# only client.Jar afterwards would leave a second cookie path active on fallback.
source = source.replace(jar, '''    var jar http.CookieJar
    if f.meta.Req.Labels[base.YunxHeaderContextLabel] == "" { jar, _ = cookiejar.New(nil) }
''')
source = source.replace(client, client.replace("\treturn client\n", "    base.YunxGuardRuntimeHeaderRedirects(f.meta.Req.Labels[base.YunxHeaderContextLabel], f.meta.Req.URL, client)\n\treturn client\n"))
path.write_text(source)
