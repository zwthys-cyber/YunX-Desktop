// SPDX-License-Identifier: AGPL-3.0-only
// Reads the already-loaded platform page; does not synthesize API signatures.
(function () {
  try {
    var match = location.pathname.match(/\/(?:explore|discovery\/item)\/([a-f0-9]{24})/i);
    if (!match) return {error: 'not-work-page'};
    var id = match[1];
    var root = window.__INITIAL_STATE__;
    if (!root) return {error: 'missing-state'};
    var map = root.note && root.note.noteDetailMap;
    var note = map && map[id] && map[id].note;
    var mapped = !!note;
    if (!note && root.noteData && root.noteData.data) note = root.noteData.data.noteData;
    if (!note) return {error: 'missing-note'};
    var actualID = String(note.noteId || note.note_id || note.id || (mapped ? id : ''));
    if (actualID !== id) return {error: 'different-note'};
    var streams = note.video && note.video.media && note.video.media.stream;
    var video = '';
    var order = ['h265', 'h264', 'av1', 'h266'];
    if (streams) {
      for (var i = 0; i < order.length && !video; i++) {
        var choices = streams[order[i]] || [];
        for (var j = 0; j < choices.length && !video; j++) video = choices[j].masterUrl || choices[j].master_url || '';
      }
    }
    if ((note.type === 'video' || streams) && !video) return {error: 'video-missing'};
    var images = [];
    if (!video) {
      var list = note.imageList || [];
      if (!list.length || list.length > 1000) return {error: 'images-missing'};
      for (var k = 0; k < list.length; k++) {
        var url = list[k].urlDefault || list[k].url || '';
        if (!url) return {error: 'image-missing'};
        images.push(String(url));
      }
    }
    var user = note.user || {};
    return {workID: actualID, title: note.title || note.desc || '', author: user.nickname || user.nickName || '',
      video: String(video), images: images, motions: [], src: 'xhs'};
  } catch (e) { return {error: 'page-data-unavailable'}; }
})()
