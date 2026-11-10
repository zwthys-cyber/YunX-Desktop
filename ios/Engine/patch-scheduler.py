# SPDX-License-Identifier: AGPL-3.0-only
# Runs only in the guarded GitHub/macOS build against the pinned revision.
from pathlib import Path
import sys

path = Path(sys.argv[1]) / "pkg/download/downloader.go"
source = path.read_text()
def replace(old, new, count=1):
    global source
    if source.count(old) != count:
        raise SystemExit("Pinned scheduler hook changed; refusing patch: " + old[:70])
    source = source.replace(old, new)

replace("\tclosed             atomic.Bool", "\tclosed             atomic.Bool\n\tyunxSchedulerStarted atomic.Bool")
replace("func (d *Downloader) remainRunningCount() int {", "func (d *Downloader) remainRunningCount() int {\n\td.yunxStartScheduler()")
replace("return d.cfg.MaxRunning - runningCount", "return max(0, min(d.cfg.MaxRunning-runningCount, base.YunxAvailableSlots()))")
replace("if remainRunningCount == 0 {", "if remainRunningCount <= 0 {", 2)
replace("math.Min(float64(d.cfg.MaxRunning), float64(continueCount))", "math.Min(float64(d.yunxSchedulerCapacity()), float64(continueCount))")
replace("\t\ttask.updateStatus(base.DownloadStatusRunning)", """\t\tif !base.YunxAcquireSlot(base.YunxNativeSlot(task.ID, task.runGeneration+1), false) {
            task.updateStatus(base.DownloadStatusWait)
            d.yunxQueueAfterQuotaRace(task)
            return true, nil
        }
        task.updateStatus(base.DownloadStatusRunning)""")
replace("\tif task.fetcher != nil {\n\t\tif err := d.captureTaskStats(task, false, true);", "\tbase.YunxReleaseSlot(base.YunxNativeSlot(task.ID, generation-1))\n\tif task.fetcher != nil {\n\t\tif err := d.captureTaskStats(task, false, true);")
replace("\ttask.updateStatus(base.DownloadStatusDone)", "\tbase.YunxReleaseSlot(base.YunxNativeSlot(task.ID, task.runGeneration))\n\ttask.updateStatus(base.DownloadStatusDone)")
replace("\ttask.updateStatus(base.DownloadStatusError)", "\tbase.YunxReleaseSlot(base.YunxNativeSlot(task.ID, task.runGeneration))\n\ttask.updateStatus(base.DownloadStatusError)")
path.write_text(source)
