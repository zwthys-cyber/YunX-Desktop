// SPDX-License-Identifier: AGPL-3.0-only
package hls

import (
    "bytes"
    "context"
    "encoding/json"
    "errors"
    "os"
    "path/filepath"
    "testing"
)

func yunxIntegrityRun(root string) *hlsRun {
    return &hlsRun{ctx: context.Background(), segs: []*Segment{{URI: "https://fixture.invalid/segment.ts"}},
        tempDir: filepath.Join(root, "owned-stage"), outputPath: filepath.Join(root, "output.ts"),
        stagingID: "owned-id", planHash: "same-plan", journal: make(map[int64]int64)}
}

func TestYunxHLSIntegrityChecksSameLengthCorruptionOnRestoreAndMerge(t *testing.T) {
    root := t.TempDir()
    f := newTestFetcher(t, testConfig())
    run := yunxIntegrityRun(root)
    if err := f.prepareRun(run); err != nil { t.Fatal(err) }
    data := []byte("a-real-completed-segment")
    if err := storeSegment(run, 0, data); err != nil { t.Fatal(err) }
    restored := yunxIntegrityRun(root)
    if err := f.prepareRun(restored); err != nil { t.Fatal(err) }
    if restored.baseDone != 1 || len(restored.pending) != 0 { t.Fatal("verified segment was not restored") }
    changed := append([]byte(nil), data...); changed[4] ^= 1
    if err := os.WriteFile(segmentPath(run.tempDir, 0), changed, 0600); err != nil { t.Fatal(err) }
    sentinel := []byte("previous complete output")
    if err := os.WriteFile(run.outputPath, sentinel, 0600); err != nil { t.Fatal(err) }
    if err := f.merge(run); !errors.Is(err, errYunxHLSIntegrity) { t.Fatalf("changed piece became a completed output: %v", err) }
    actual, err := os.ReadFile(run.outputPath)
    if err != nil || !bytes.Equal(actual, sentinel) { t.Fatal("failed merge changed previous output") }
    restored = yunxIntegrityRun(root)
    if err := f.prepareRun(restored); err != nil { t.Fatal(err) }
    if restored.baseDone != 0 || len(restored.pending) != 1 { t.Fatal("same-size damaged segment was reused") }
    if err := storeSegment(restored, 0, data); err != nil { t.Fatal(err) }
    if err := f.merge(restored); err != nil { t.Fatal(err) }
    actual, err = os.ReadFile(restored.outputPath)
    if err != nil || !bytes.Equal(actual, data) { t.Fatal("repaired segment did not produce correct output") }
}

func TestYunxHLSIntegrityDoesNotTrustLegacySizesOrFollowSegmentSymlinks(t *testing.T) {
    root := t.TempDir()
    f := newTestFetcher(t, testConfig())
    run := yunxIntegrityRun(root)
    if err := f.prepareRun(run); err != nil { t.Fatal(err) }
    data := []byte("legacy-complete-length")
    if err := os.WriteFile(segmentPath(run.tempDir, 0), data, 0600); err != nil { t.Fatal(err) }
    old := journalFile{StagingID: run.stagingID, PlanHash: run.planHash, SegmentCount: 1, Sizes: map[string]int64{"0": int64(len(data))}}
    encoded, err := json.Marshal(old)
    if err != nil { t.Fatal(err) }
    if err := os.WriteFile(run.journalPath, encoded, 0600); err != nil { t.Fatal(err) }
    restored := yunxIntegrityRun(root)
    if err := f.prepareRun(restored); err != nil { t.Fatal(err) }
    if len(restored.pending) != 1 || restored.baseDone != 0 { t.Fatal("legacy byte count was treated as a verified digest") }
    if err := storeSegment(restored, 0, data); err != nil { t.Fatal(err) }
    outside := filepath.Join(root, "outside")
    if err := os.WriteFile(outside, data, 0600); err != nil { t.Fatal(err) }
    if err := os.Remove(segmentPath(run.tempDir, 0)); err != nil { t.Fatal(err) }
    if err := os.Symlink(outside, segmentPath(run.tempDir, 0)); err != nil { t.Fatal(err) }
    if err := yunxCheckHLSSegment(restored, 0); !errors.Is(err, errYunxHLSIntegrity) { t.Fatal("staged symlink was accepted") }
    actual, err := os.ReadFile(outside)
    if err != nil || !bytes.Equal(actual, data) { t.Fatal("verification changed linked file") }
}
