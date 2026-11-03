//
//  FileAttachment.swift
//  kebab
//
//  What a thought knows about an attached file, and the small pure rules around
//  it: limits, kinds, icons, meta lines. General on purpose. PDFs and videos get
//  richer treatment, but nothing here is special to them, and audio recordings
//  ride the same model next.
//

import Foundation
import UniformTypeIdentifiers

/// The `file` object on a `"file"` attachment, stored in `entries.attachments`.
nonisolated struct FileMetadata: Codable, Sendable, Equatable {
    /// Object path in the private `entry-files` bucket.
    let path: String
    /// The original filename. Lives only here, never in the path.
    let name: String
    let mime: String
    let size: Int64
    /// `FileKind`'s raw value. Stored as a string so a kind added later still
    /// decodes in this build, as a plain file.
    let kind: String
    /// Public `entry-images` URL of the poster or first page.
    let thumb_url: String?
    /// Seconds, for video.
    let duration: Double?
    /// For PDF.
    let page_count: Int?

    var fileKind: FileKind {
        FileKind(rawValue: kind) ?? .file
    }
}

nonisolated enum FileKind: String, Codable, Sendable {
    case pdf
    case video
    case audio
    case file

    static func of(_ type: UTType?) -> FileKind {
        guard let type else { return .file }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        return .file
    }

    static func of(filename: String) -> FileKind {
        of(UTType(filenameExtension: (filename as NSString).pathExtension))
    }
}

nonisolated enum FileLimits {
    static let maxBytes: Int64 = 52_428_800 // 50 MB, the bucket's file_size_limit.
    static let maxFiles = 4

    enum Refusal: Equatable {
        case tooMany
        case tooLarge

        var message: String {
            switch self {
            case .tooMany: return "A thought can hold up to \(FileLimits.maxFiles) files."
            case .tooLarge: return "Files can be up to 50 MB."
            }
        }
    }

    /// Whether one more file fits. Size is only known for files that won't be
    /// compressed first.
    static func refusal(existingCount: Int, size: Int64?) -> Refusal? {
        if existingCount >= maxFiles { return .tooMany }
        if let size, size > maxBytes { return .tooLarge }
        return nil
    }
}

nonisolated enum FileIcon {
    /// Imageset name for a file. PDFs and videos go by kind, everything else
    /// by extension.
    static func name(forKind kind: FileKind, filename: String) -> String {
        switch kind {
        case .pdf: return "pdf-01"
        case .video: return "video-01"
        case .audio, .file: break
        }
        switch (filename as NSString).pathExtension.lowercased() {
        case "pdf": return "pdf-01"
        case "doc", "docx", "pages", "rtf": return "doc-01"
        case "txt", "md": return "txt-01"
        case "xls", "xlsx", "numbers", "csv": return "xls-01"
        case "ppt", "pptx", "key": return "ppt-01"
        case "zip": return "zip-01"
        default: return "file-01"
        }
    }
}

nonisolated enum FileMeta {
    /// "PDF · 12 pages · 2.4 MB", "DOCX · 1.2 MB".
    static func line(name: String, size: Int64, pageCount: Int?) -> String {
        var parts: [String] = []
        let ext = (name as NSString).pathExtension.uppercased()
        if !ext.isEmpty { parts.append(ext) }
        if let pageCount, pageCount > 0 {
            parts.append(pageCount == 1 ? "1 page" : "\(pageCount) pages")
        }
        parts.append(byteCount(size))
        return parts.joined(separator: " · ")
    }

    static func byteCount(_ size: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    /// "0:42", "12:05", "1:02:09".
    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }
}
