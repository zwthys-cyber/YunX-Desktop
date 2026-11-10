// SPDX-License-Identifier: AGPL-3.0-only
// Read already-loaded DOM/resource timing data; no requests, credential reads or hooks.
(function () {
  'use strict';
  const resources = [], seen = new Set();
  let omitted = 0;
  const types = {
    image: /\.(?:jpe?g|png|webp|gif|heic|heif|avif|svg|bmp|ico)$/i,
    video: /\.(?:mp4|m4v|mov|webm|mkv|m3u8|ts|m4s)$/i,
    audio: /\.(?:mp3|m4a|aac|flac|wav|ogg|opus)$/i,
    document: /\.(?:pdf|epub|txt|csv|docx?|xlsx?|pptx?)$/i,
    archive: /\.(?:zip|7z|rar|gz|tar|bz2|xz|torrent)$/i,
    program: /\.(?:ipa|apk|exe|msi|dmg|pkg|deb)$/i,
    font: /\.(?:woff2?|ttf|otf)$/i
  };
  function add(raw, hint) {
    if (typeof raw !== 'string' || !raw || raw.length > 16384) return;
    let url;
    try { url = new URL(raw, document.baseURI); } catch (_) { return; }
    if (url.protocol !== 'https:' || url.username || url.password || seen.has(url.href)) return;
    let kind = '';
    for (const entry of Object.entries(types)) if (entry[1].test(url.pathname)) { kind = entry[0]; break; }
    if (!kind && ['image', 'video', 'audio'].includes(hint)) kind = hint;
    if (!kind) return;
    seen.add(url.href);
    if (resources.length >= 200) { omitted++; return; }
    resources.push({url: url.href, kind: kind});
  }
  for (const image of Array.from(document.images || []).slice(0, 2000)) add(image.currentSrc || image.src, 'image');
  for (const element of Array.from(document.querySelectorAll('video,audio,video source,audio source')).slice(0, 2000)) {
    const type = (element.tagName || '').toLowerCase();
    add(element.currentSrc || element.src, type === 'audio' || element.parentElement && element.parentElement.tagName === 'AUDIO' ? 'audio' : 'video');
  }
  for (const anchor of Array.from(document.querySelectorAll('a[href]')).slice(0, 2000)) add(anchor.href, '');
  try { for (const entry of performance.getEntriesByType('resource').slice(-2000)) add(entry.name, entry.initiatorType === 'img' ? 'image' : ''); } catch (_) {}
  return {page: location.href, resources: resources, omitted: omitted};
})()
