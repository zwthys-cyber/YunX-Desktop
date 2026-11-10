// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

struct CloudBatchFile {
    let file: CloudFile
    let relativeFolders: [String]
}

/// Enumerate before creating downloads: hitting a bound never silently truncates a batch.
struct CloudFolderCollector {
    var fileLimit = 500
    var folderLimit = 100
    var pageLimit = 200
    func collect(rootID: String, list: (String, Int) async throws -> [CloudFile]) async throws -> [CloudBatchFile] {
        var pending: [(String, [String])] = [(rootID, [])]
        var seenFolders: Set<String> = [rootID]
        var seenFiles = Set<String>()
        var output: [CloudBatchFile] = []
        var cursor = 0
        while cursor < pending.count {
            try Task.checkCancellation()
            let (folder, path) = pending[cursor]
            cursor += 1
            var page = 1
            var seenInFolder = Set<String>()
            while true {
                try Task.checkCancellation()
                guard page <= pageLimit else { throw CloudError.message("文件夹分页超过批量上限，请进入子目录分批下载。") }
                let batch = try await list(folder, page)
                var fresh = 0
                for file in batch where seenInFolder.insert(file.id).inserted {
                    fresh += 1
                    if file.isDirectory {
                        if seenFolders.insert(file.id).inserted {
                            guard seenFolders.count <= folderLimit else { throw CloudError.message("目录超过批量上限，请进入子目录分批下载。") }
                            pending.append((file.id, path + [file.name]))
                        }
                    } else if seenFiles.insert(file.id).inserted {
                        guard output.count < fileLimit else { throw CloudError.message("文件超过批量上限，请进入子目录分批下载。") }
                        output.append(CloudBatchFile(file: file, relativeFolders: path))
                    }
                }
                if batch.count < 50 { break }
                guard fresh > 0 else { throw CloudError.message("平台分页重复，已停止批量操作，请刷新后重试。") }
                page += 1
            }
        }
        return output
    }
}
