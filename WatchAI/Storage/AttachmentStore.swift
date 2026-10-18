import Foundation
import ImageIO
import UniformTypeIdentifiers
import UIKit

enum AttachmentStore {
    static let directory: URL = FileStore.directory("attachments")

    /// 将相册图片缩放并压缩为 JPEG 后保存
    static func importImage(data: Data, maxDimension: Int, quality: Double) -> ImageAttachment? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(256, maxDimension)
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        let name = UUID().uuidString + ".jpg"
        let url = directory.appendingPathComponent(name)
        do {
            try (out as Data).write(to: url, options: .atomic)
        } catch {
            return nil
        }
        return ImageAttachment(fileName: name, width: cg.width, height: cg.height, byteSize: out.length)
    }

    static func data(for attachment: ImageAttachment) -> Data? {
        try? Data(contentsOf: attachment.fileURL)
    }

    static func dataURL(for attachment: ImageAttachment) -> String? {
        guard let d = data(for: attachment) else { return nil }
        return "data:image/jpeg;base64," + d.base64EncodedString()
    }

    static func image(for attachment: ImageAttachment) -> UIImage? {
        UIImage(contentsOfFile: attachment.fileURL.path)
    }

    static func delete(_ attachments: [ImageAttachment]) {
        for a in attachments { FileStore.remove(a.fileURL) }
    }

    static var totalSize: Int64 { FileStore.directorySize(directory) }
}

import PhotosUI
import SwiftUI

enum ImageImporter {
    @MainActor
    static func load(_ items: [PhotosPickerItem], settings: AppSettings) async -> [ImageAttachment] {
        let maxDim = settings.imageMaxDimension
        let quality = settings.imageQuality
        var out: [ImageAttachment] = []
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            let attachment = await Task.detached(priority: .userInitiated) {
                AttachmentStore.importImage(data: data, maxDimension: maxDim, quality: quality)
            }.value
            if let attachment { out.append(attachment) }
        }
        return out
    }
}
