import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

/// Export presets (T5, Lightroom/Apple Photos "내보내기"): resize, convert format,
/// and strip metadata/GPS — all LOCAL (ImageIO), never touching the server. The
/// drag-out/download paths still ship the untouched original; this is the opt-in
/// "processed" export for sharing (smaller, or privacy-stripped).
enum ExportFormat: String, CaseIterable, Identifiable {
    case original = "원본 형식"
    case jpeg = "JPEG"
    case png = "PNG"
    var id: String { rawValue }
    var fileExtension: String? {
        switch self { case .original: return nil; case .jpeg: return "jpg"; case .png: return "png" }
    }
    var utType: UTType? {
        switch self { case .original: return nil; case .jpeg: return .jpeg; case .png: return .png }
    }
}

struct ExportOptions: Equatable {
    var format: ExportFormat = .original
    /// Longest-edge cap in px; nil = keep original size.
    var maxDimension: Int? = nil
    var jpegQuality: Double = 0.9
    /// Drop all embedded metadata (incl. GPS) on export.
    var stripMetadata: Bool = false
}

enum ImageExporter {
    /// Size presets for the export sheet (label → longest-edge cap).
    static let sizeOptions: [(label: String, value: Int?)] = [
        ("원본 크기", nil), ("4096 px", 4096), ("2048 px", 2048), ("1024 px", 1024),
    ]

    /// True when nothing needs re-encoding — a video, or a photo with no
    /// transforms — so the untouched original is exported.
    static func isPassThrough(isPhoto: Bool, _ o: ExportOptions) -> Bool {
        guard isPhoto else { return true }
        return o.format == .original && o.maxDimension == nil && !o.stripMetadata
    }

    /// Output filename for the options (the extension may change with the format).
    static func suggestedName(_ filename: String, isPhoto: Bool, _ o: ExportOptions) -> String {
        guard isPhoto, let ext = o.format.fileExtension else { return filename }
        let base = (filename as NSString).deletingPathExtension
        return "\(base).\(ext)"
    }

    /// Transforms photo bytes per options. Returns (data, filename). Pass-through
    /// (video / no transforms) returns the original unchanged. Re-encoding drops
    /// all embedded metadata — that IS the metadata/GPS strip.
    static func export(originalData: Data, filename: String, isPhoto: Bool, options: ExportOptions) -> (data: Data, filename: String)? {
        if isPassThrough(isPhoto: isPhoto, options) { return (originalData, filename) }
        guard let src = CGImageSourceCreateWithData(originalData as CFData, nil) else { return nil }

        // Thumbnail-with-transform bakes in EXIF orientation and (with a cap)
        // resizes; a huge cap ⇒ full-size. A fresh encode carries no metadata.
        let maxPixel = options.maxDimension ?? 100_000
        let thumbOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOpts as CFDictionary) else { return nil }

        // Output type: the chosen format, else the source's own type, else JPEG.
        let type: UTType = options.format.utType
            ?? CGImageSourceGetType(src).flatMap { UTType($0 as String) }
            ?? .jpeg
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else { return nil }
        var props: [CFString: Any] = [:]
        if type == .jpeg { props[kCGImageDestinationLossyCompressionQuality] = options.jpegQuality }
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }

        let ext = options.format.fileExtension
            ?? type.preferredFilenameExtension
            ?? (filename as NSString).pathExtension
        let base = (filename as NSString).deletingPathExtension
        return (out as Data, "\(base).\(ext)")
    }
}
