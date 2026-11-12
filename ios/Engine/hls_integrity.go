// SPDX-License-Identifier: AGPL-3.0-only
package hls

import (
    "bytes"
    "crypto/sha256"
    "encoding/hex"
    "errors"
    "io"
    "os"
)

var errYunxHLSIntegrity = errors.New("HLS cached segment integrity differs; retry the download")

func yunxWriteHLSSegment(path string, data []byte) (string, error) {
    if info, err := os.Lstat(path); err == nil {
        if !info.Mode().IsRegular() { return "", errYunxHLSIntegrity }
        if err := os.Remove(path); err != nil { return "", err }
    } else if !os.IsNotExist(err) { return "", err }
    // Exclusive creation prevents following a substituted .part symlink.
    file, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
    if err != nil { return "", err }
    digest := sha256.New()
    _, writeErr := io.Copy(io.MultiWriter(file, digest), bytes.NewReader(data))
    if writeErr == nil { writeErr = file.Sync() }
    closeErr := file.Close()
    if writeErr == nil { writeErr = closeErr }
    if writeErr != nil { os.Remove(path); return "", writeErr }
    return hex.EncodeToString(digest.Sum(nil)), nil
}

func yunxOpenHLSSegment(path string, size int64) (*os.File, error) {
    before, err := os.Lstat(path)
    if os.IsNotExist(err) { return nil, errYunxHLSIntegrity }
    if err != nil { return nil, err }
    if !before.Mode().IsRegular() || size <= 0 || before.Size() != size { return nil, errYunxHLSIntegrity }
    file, err := os.Open(path)
    if err != nil { return nil, err }
    actual, err := file.Stat()
    if err != nil { file.Close(); return nil, err }
    if !os.SameFile(before, actual) || !actual.Mode().IsRegular() || actual.Size() != size {
        file.Close(); return nil, errYunxHLSIntegrity
    }
    return file, nil
}

func yunxHLSDigest(run *hlsRun, idx int64) ([]byte, int64, error) {
    run.journalMu.Lock()
    raw, size := run.yunxSHA256[idx], run.journal[idx]
    run.journalMu.Unlock()
    digest, err := hex.DecodeString(raw)
    if err != nil || len(digest) != sha256.Size || size <= 0 { return nil, 0, errYunxHLSIntegrity }
    return digest, size, nil
}

func yunxCheckHLSSegment(run *hlsRun, idx int64) error {
    expected, size, err := yunxHLSDigest(run, idx)
    if err != nil { return err }
    file, err := yunxOpenHLSSegment(segmentPath(run.tempDir, idx), size)
    if err != nil { return err }
    defer file.Close()
    digest := sha256.New()
    n, err := io.CopyBuffer(digest, file, make([]byte, 64*1024))
    if err != nil { return err }
    if n != size || !bytes.Equal(digest.Sum(nil), expected) { return errYunxHLSIntegrity }
    return nil
}

func yunxReadVerifiedHLSSegment(run *hlsRun, idx int64) ([]byte, error) {
    expected, size, err := yunxHLSDigest(run, idx)
    if err != nil { return nil, err }
    if size == int64(^uint64(0)>>1) { return nil, errYunxHLSIntegrity }
    file, err := yunxOpenHLSSegment(segmentPath(run.tempDir, idx), size)
    if err != nil { return nil, err }
    defer file.Close()
    data, err := io.ReadAll(io.LimitReader(file, size+1))
    if err != nil { return nil, err }
    digest := sha256.Sum256(data)
    if int64(len(data)) != size || !bytes.Equal(digest[:], expected) { return nil, errYunxHLSIntegrity }
    return data, nil
}
