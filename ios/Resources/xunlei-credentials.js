// SPDX-License-Identifier: AGPL-3.0-only
// Read only the explicitly opened official account session; no cookie bridge is written.
(function () {
    try {
        var client = 'Xqp0kJBXWhwaTpB6';
        var current = localStorage.getItem('current_sub');
        var prefix = 'credentials_' + client;
        var raw = localStorage.getItem(current ? prefix + '@' + current : prefix);
        if (!raw || raw.length > 65536) return null;
        var data = JSON.parse(raw);
        for (var level = 0; level < 2 && data && !data.access_token && !data.accessToken; level++) {
            data = data.credentials || data.token || data.data;
        }
        if (!data || typeof data !== 'object' || Array.isArray(data)) return null;
        if (current && data.sub && String(data.sub) !== String(current)) return null;
        var result = {
            access_token: data.access_token || data.accessToken || '',
            refresh_token: data.refresh_token || data.refreshToken || '',
            device_id: data.device_id || data.deviceId || '',
            user_id: data.user_id || data.userId || data.sub || '',
            nickname: data.nick_name || data.nickname || data.name || data.user_name || ''
        };
        try {
            var captcha = JSON.parse(localStorage.getItem('captcha_' + client) || '{}');
            var until = Date.parse(captcha.expires_at);
            if (captcha.token && Number.isFinite(until) && until > Date.now()) {
                result.captcha_token = captcha.token;
                result.captchaExpiresAt = String(until);
            }
        } catch (_) {}
        document.cookie.split(';').some(function (item) {
            item = item.trim();
            if (item.indexOf('deviceid=') !== 0) return false;
            var value = decodeURIComponent(item.slice(9));
            result.device_id = value.indexOf('.') >= 0 && value.length > 32 ? value.split('.')[1].slice(0, 32) : value;
            return true;
        });
        return result;
    } catch (_) { return null; }
})()
