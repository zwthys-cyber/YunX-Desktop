// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum MediaFileValidation {
    static func filename(_ proposed: String, file: URL, kind: String?, mime: String?) throws -> String {
        guard let kind else { return proposed }
        if kind == "image" {
            guard let source = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  CGImageSourceGetCount(source) > 0, let raw = CGImageSourceGetType(source),
                  let type = UTType(raw as String), type.conforms(to: .image) else {
                throw CloudError.message("返回内容不是可识别的图片，已拒绝保存。")
            }
            let ext = type.preferredFilenameExtension?.lowercased()
            guard let ext, ["jpg", "jpeg", "png", "webp", "gif", "heic", "heif", "avif", "tif", "tiff", "bmp"].contains(ext) else { return proposed }
            let existing = (proposed as NSString).pathExtension.lowercased()
            if existing == ext || (["jpg", "jpeg"].contains(ext) && ["jpg", "jpeg"].contains(existing)) { return proposed }
            return FileNamePolicy.name((proposed as NSString).deletingPathExtension + "." + ext)
        }
        if kind == "video" {
            let content = mime?.lowercased() ?? ""
            guard !content.hasPrefix("text/"), !content.contains("json") else { throw CloudError.message("视频直链返回了错误页面，已拒绝保存。") }
            let reader = try FileHandle(forReadingFrom: file)
            defer { try? reader.close() }
            let prefix = try reader.read(upToCount: 1024) ?? Data()
            let text = String(decoding: prefix, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !prefix.isEmpty, !text.hasPrefix("<!doctype"), !text.hasPrefix("<html"), !text.hasPrefix("{"), !text.hasPrefix("["), !text.hasPrefix("#extm3u") else {
                throw CloudError.message("返回内容不是文件视频流，请重新解析作品。")
            }
        }
        return proposed
    }
}
