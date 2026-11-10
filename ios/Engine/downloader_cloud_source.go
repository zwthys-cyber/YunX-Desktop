// SPDX-License-Identifier: AGPL-3.0-only
package download

import (
    "errors"

    fetchhttp "github.com/GopeedLab/gopeed/internal/protocol/http"
    "github.com/GopeedLab/gopeed/pkg/base"
)

func (d *Downloader) YunxRebindCloudSource(id, expectedContext string, size int64, req *base.Request) (bool, error) {
    if req == nil || req.Labels["yunxCloudTransfer"] == "" || req.Labels["yunxCloudTransfer"] == expectedContext {
        return false, errors.New("replacement cloud context required")
    }
    task := d.GetTask(id)
    if task == nil { return false, ErrTaskNotFound }
    task.lock.Lock()
    defer task.lock.Unlock()
    task.statusLock.Lock()
    if (task.Status != base.DownloadStatusPause && task.Status != base.DownloadStatusError) ||
        task.Meta == nil || task.Meta.Req == nil || expectedContext == "" ||
        task.Meta.Req.Labels["yunxCloudTransfer"] != expectedContext {
        task.statusLock.Unlock()
        return false, errors.New("cloud task changed or is no longer stopped")
    }
    if task.fetcher == nil {
        if err := d.restoreFetcher(task); err != nil { task.statusLock.Unlock(); return false, err }
    }
    fetcher, ok := task.fetcher.(*fetchhttp.Fetcher)
    if !ok { task.statusLock.Unlock(); return false, nil }
    task.statusLock.Unlock()
    // Error tasks cannot be paused through the ordinary REST filter. Close
    // their physical readers before touching the source or checking its file.
    if err := fetcher.Pause(); err != nil { return false, err }
    task.statusLock.Lock()
    if (task.Status != base.DownloadStatusPause && task.Status != base.DownloadStatusError) ||
        task.Meta.Req.Labels["yunxCloudTransfer"] != expectedContext {
        task.statusLock.Unlock()
        return false, errors.New("cloud task changed while stopping")
    }
    updated, err := fetcher.YunxRebindCloudSource(req, size)
    if updated { task.Meta = fetcher.Meta() }
    task.statusLock.Unlock()
    if err != nil || !updated { return updated, err }
    // saveTask takes statusLock to snapshot the updated task itself.
    if err := d.saveTask(task); err != nil { return false, err }
    return true, nil
}
