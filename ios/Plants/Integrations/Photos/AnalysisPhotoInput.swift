import Foundation
import UIKit
import ImageIO
import UniformTypeIdentifiers

public enum PhotoInputError: Error, Sendable, Equatable {
    case unreadableOrCorruptImage
    case compressionFailed
}

public struct PreparedAnalysisPhoto: Sendable, Equatable {
    public let cloudNormalizedJPEG: Data
    public let aiVisionJPEG: Data
    public let aiWidthPx: Int
    public let aiHeightPx: Int
    public let originalByteCount: Int
    public let strippedExifAndGps: Bool

    public init(
        cloudNormalizedJPEG: Data,
        aiVisionJPEG: Data,
        aiWidthPx: Int,
        aiHeightPx: Int,
        originalByteCount: Int,
        strippedExifAndGps: Bool = true
    ) {
        self.cloudNormalizedJPEG = cloudNormalizedJPEG
        self.aiVisionJPEG = aiVisionJPEG
        self.aiWidthPx = aiWidthPx
        self.aiHeightPx = aiHeightPx
        self.originalByteCount = originalByteCount
        self.strippedExifAndGps = strippedExifAndGps
    }
}

public struct AnalysisPhotoInput: Sendable {
    public static let maxCloudBytes = 10 * 1024 * 1024 // 10 MB
    public static let maxAiDimensionPx: CGFloat = 1568.0

    public init() {}

    /// Prepares any readable image (including > 10 MB sources) into a metadata-stripped
    /// cloud JPEG (<= 10 MB) and an AI Vision JPEG (longest edge <= 1568px).
    /// Fails only when the input bytes cannot be decoded as a valid image.
    public func preparePhoto(from rawData: Data) throws -> PreparedAnalysisPhoto {
        guard !rawData.isEmpty, let image = UIImage(data: rawData),
              image.size.width > 0, image.size.height > 0 else {
            throw PhotoInputError.unreadableOrCorruptImage
        }

        // 1. Produce AI Vision JPEG (<= 1568px max edge) with EXIF/GPS stripped
        let (aiImage, aiWidth, aiHeight) = Self.downscale(image: image, maxEdge: Self.maxAiDimensionPx)
        guard let aiData = Self.encodeMetadataStrippedJPEG(image: aiImage, quality: 0.82) else {
            throw PhotoInputError.compressionFailed
        }

        // 2. Produce Cloud Normalized JPEG <= 10 MB with EXIF/GPS stripped
        let (cloudImage, _, _) = Self.downscale(image: image, maxEdge: 3072.0)
        var quality: CGFloat = 0.88
        var cloudData = Self.encodeMetadataStrippedJPEG(image: cloudImage, quality: quality)

        while let current = cloudData, current.count > Self.maxCloudBytes, quality > 0.25 {
            quality -= 0.15
            cloudData = Self.encodeMetadataStrippedJPEG(image: cloudImage, quality: quality)
        }

        let finalCloudData = (cloudData != nil && cloudData!.count <= Self.maxCloudBytes)
            ? cloudData!
            : aiData

        guard finalCloudData.count <= Self.maxCloudBytes else {
            throw PhotoInputError.compressionFailed
        }

        return PreparedAnalysisPhoto(
            cloudNormalizedJPEG: finalCloudData,
            aiVisionJPEG: aiData,
            aiWidthPx: aiWidth,
            aiHeightPx: aiHeight,
            originalByteCount: rawData.count,
            strippedExifAndGps: !Self.containsGpsOrExifMetadata(finalCloudData)
        )
    }

    private static func downscale(image: UIImage, maxEdge: CGFloat) -> (UIImage, Int, Int) {
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        let longest = max(pixelWidth, pixelHeight)

        let scaleFactor = longest > maxEdge ? (maxEdge / longest) : 1.0
        let targetWidth = max(1, Int((pixelWidth * scaleFactor).rounded()))
        let targetHeight = max(1, Int((pixelHeight * scaleFactor).rounded()))
        let targetSize = CGSize(width: CGFloat(targetWidth), height: CGFloat(targetHeight))

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        let rendered = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        return (rendered, targetWidth, targetHeight)
    }

    private static func encodeMetadataStrippedJPEG(image: UIImage, quality: CGFloat) -> Data? {
        guard let cgImage = image.cgImage else {
            return image.jpegData(compressionQuality: quality)
        }
        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            mutableData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return image.jpegData(compressionQuality: quality)
        }

        // The renderer has already removed the input metadata. Null dictionaries can produce an empty frame.
        let options = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        CGImageDestinationAddImage(destination, cgImage, options)
        guard CGImageDestinationFinalize(destination),
              let source = CGImageSourceCreateWithData(mutableData, nil),
              (CGImageSourceGetType(source) as String?) == UTType.jpeg.identifier,
              CGImageSourceGetCount(source) == 1,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else {
            return nil
        }
        return mutableData as Data
    }

    public static func containsGpsOrExifMetadata(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return false
        }
        if let gps = props[kCGImagePropertyGPSDictionary] as? [String: Any], !gps.isEmpty {
            return true
        }
        return false
    }
}
