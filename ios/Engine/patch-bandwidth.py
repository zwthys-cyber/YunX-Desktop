# SPDX-License-Identifier: AGPL-3.0-only
# Applied only inside the guarded macOS/GitHub engine build.
from pathlib import Path
import sys

path = Path(sys.argv[1]) / "internal/protocol/http/fetcher.go"
source = path.read_text()
original = '''func (f *Fetcher) responseReader(resp *http.Response, cancel context.CancelFunc) io.Reader {
\tif f.ctl != nil && f.ctl.ManagedProduction != nil && resp.Request != nil && f.ctl.ManagedProduction(resp.Request.URL.String()) {
\t\treturn resp.Body
\t}
\treturn NewTimeoutReader(resp.Body, readTimeout, cancel)
}'''
replacement = '''func (f *Fetcher) responseReader(resp *http.Response, cancel context.CancelFunc) io.Reader {
    return f.responseReaderWithBudget(resp, cancel, nil, nil)
}

func (f *Fetcher) responseReaderWithBudget(resp *http.Response, cancel context.CancelFunc, budgetContext context.Context, stop <-chan struct{}) io.Reader {
    if f.ctl != nil && f.ctl.ManagedProduction != nil && resp.Request != nil && f.ctl.ManagedProduction(resp.Request.URL.String()) {
        return resp.Body
    }
    if budgetContext == nil {
        budgetContext = context.Background()
        if resp.Request != nil { budgetContext = resp.Request.Context() }
    }
    return base.YunxNativeHTTPReader(budgetContext, NewTimeoutReader(resp.Body, readTimeout, cancel), stop)
}'''
if source.count(original) != 1 or source.count("reader := f.responseReader(resp, cancel)") != 2 or source.count("reader := f.responseReader(resp, reqCancel)") != 1:
    raise SystemExit("Pinned native HTTP bandwidth hook changed")
source = source.replace(original, replacement)
# The first call belongs to asyncPrefetch, whose stop signal can precede any
# request-context cancellation. Other readers use their physical connection.
source = source.replace("reader := f.responseReader(resp, cancel)", "reader := f.responseReaderWithBudget(resp, cancel, nil, f.prefetchStopCh)", 1)
source = source.replace("reader := f.responseReader(resp, cancel)", "reader := f.responseReaderWithBudget(resp, cancel, conn.ctx, nil)", 1)
source = source.replace("reader := f.responseReader(resp, reqCancel)", "reader := f.responseReaderWithBudget(resp, reqCancel, conn.ctx, nil)", 1)
path.write_text(source)
