// SPDX-License-Identifier: AGPL-3.0-only
// Adapted from desktop DouyinParser.kt.
(function () {
  try {
    if (window.__yunxDetailHookInstalled) return;
    window.__yunxDetailHookInstalled = true;
    var rawOpen = XMLHttpRequest.prototype.open;
    var rawSend = XMLHttpRequest.prototype.send;
    XMLHttpRequest.prototype.open = function (method, url) {
      try { this.__yunxUrl = String(url || ''); } catch (e) { this.__yunxUrl = ''; }
      return rawOpen.apply(this, arguments);
    };
    XMLHttpRequest.prototype.send = function () {
      var xhr = this;
      try {
        xhr.addEventListener('load', function () {
          try {
            var url = xhr.__yunxUrl || '';
            if (url.indexOf('aweme/v1/web/aweme/detail') < 0) return;
            if (xhr.status !== 200) return;
            // ★ 不能只读 responseText：页面若把 responseType 设成 'json'，读 responseText 会抛
            //   InvalidStateError（被 try 吞掉 → 钩子永远拿不到值，表现就是「一直不就绪」）。
            var text = '';
            try { text = xhr.responseText || ''; } catch (e) { text = ''; }
            if (!text) {
              try {
                var r = xhr.response;
                if (r) text = (typeof r === 'string') ? r : JSON.stringify(r);
              } catch (e) { text = ''; }
            }
            if (text) window.__yunxAwemeDetail = text;
          } catch (e) {}
        });
      } catch (e) {}
      return rawSend.apply(this, arguments);
    };
  } catch (e) {}
})()
