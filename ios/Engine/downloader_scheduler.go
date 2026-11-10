// SPDX-License-Identifier: AGPL-3.0-only
package download

import (
    "time"
    "github.com/GopeedLab/gopeed/pkg/base"
)

func (d *Downloader) yunxSchedulerCapacity() int {
    return min(d.cfg.MaxRunning, base.YunxNativeCapacity())
}
func (d *Downloader) yunxStartScheduler() {
    if !base.YunxSchedulerEnabled() || !d.yunxSchedulerStarted.CompareAndSwap(false, true) { return }
    go func() {
        ticker := time.NewTicker(time.Second)
        defer ticker.Stop()
        for range ticker.C {
            if d.closed.Load() { return }
            if base.YunxAvailableSlots() > 0 { d.notifyRunning() }
        }
    }()
}
func (d *Downloader) yunxQueueAfterQuotaRace(task *Task) {
    go func() {
        d.lock.Lock(); defer d.lock.Unlock()
        if d.closed.Load() || d.taskStatus(task) != base.DownloadStatusWait { return }
        for _, waiting := range d.waitTasks { if waiting.ID == task.ID { return } }
        d.waitTasks = append(d.waitTasks, task)
        if err := d.storage.Put(bucketTask, task.ID, task.clone()); err != nil {
            d.Logger.Error().Err(err).Msg("persist queued iOS task failed")
        }
    }()
}
