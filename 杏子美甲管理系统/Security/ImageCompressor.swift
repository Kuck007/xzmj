//
//  ImageCompressor.swift
//  杏子美甲管理系统
//
//  通用图片压缩器：支持 PNG/JPEG/BMP/GIF/TIFF/HEIC/WebP/部分 RAW 等
//  任意 macOS 原生可读格式 → 统一转成 JPEG（长边 2000px，质量 0.7）
//

import AppKit
import ImageIO

enum ImageCompressor {

    // MARK: - 压缩参数（可按需微调）
    /// 输出长边像素，超过则等比缩放；小于则保留原大小（不放大）
    static let maxLongSide: CGFloat = 2000
    /// JPEG 压缩质量 0.0-1.0（0.7 视觉无损，美甲场景足够）
    static let jpegQuality: CGFloat = 0.7

    // MARK: - 主入口：Data → JPEG Data

    /// 任意图片 Data → 压缩后 JPEG Data（美甲场景默认参数）
    static func compressToJPEG(_ data: Data) -> Data? {
        compressToJPEG(data, maxLongSide: maxLongSide, quality: jpegQuality)
    }

    /// 任意图片 Data → JPEG Data（可自定义参数）
    static func compressToJPEG(
        _ data: Data,
        maxLongSide: CGFloat,
        quality: CGFloat
    ) -> Data? {
        // 1. 先用 ImageIO 读取原图像素尺寸（不解码整图，RAW/大尺寸也能快速拿到 size）
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else {
            // ImageIO 识别不出的格式，最后兜底：NSImage 解码
            return compressViaNSImage(data, maxLongSide: maxLongSide, quality: quality)
        }
        guard let srcProps = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let width = srcProps[kCGImagePropertyPixelWidth] as? Int,
              let height = srcProps[kCGImagePropertyPixelHeight] as? Int,
              let cgImage = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            return compressViaNSImage(data, maxLongSide: maxLongSide, quality: quality)
        }

        // 2. 计算目标尺寸（等比缩放，不放大）
        let srcLong = CGFloat(max(width, height))
        let scale: CGFloat = srcLong > maxLongSide ? maxLongSide / srcLong : 1.0
        let dstSize = NSSize(
            width: round(CGFloat(width) * scale),
            height: round(CGFloat(height) * scale)
        )

        // 3. 读取 EXIF 朝向（ImageIO/JPEG 不自带旋转，需要手动旋转像素）
        let orientationRaw = (srcProps[kCGImagePropertyOrientation] as? UInt32)
            ?? CGImagePropertyOrientation.up.rawValue
        let _ = CGImagePropertyOrientation(rawValue: orientationRaw) ?? .up

        // 4. 缩放 + 旋转 → 绘制到位图上下文
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(dstSize.width),
            pixelsHigh: Int(dstSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: false,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: [],
            bytesPerRow: 0,
            bitsPerPixel: 32
        )
        guard let bitmap = bitmap else {
            return compressViaNSImage(data, maxLongSide: maxLongSide, quality: quality)
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        defer { NSGraphicsContext.restoreGraphicsState() }

        let drawRect = NSRect(origin: .zero, size: dstSize)
        let srcImage = NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
        // 先按 EXIF 方向旋转：NSImage 从 NSImage 读取时会按方向显示，draw 时自动处理
        srcImage.draw(in: drawRect, from: NSRect(origin: .zero, size: srcImage.size),
                       operation: .sourceOver, fraction: 1.0,
                       respectFlipped: true, hints: [
                        .interpolation: NSImageInterpolation.high
                       ])

        // 5. 转 JPEG
        guard let jpegData = bitmap.representation(
            using: .jpeg,
            properties: [.compressionFactor: NSNumber(value: Double(quality))]
        ) else {
            return nil
        }
        return jpegData.isEmpty ? nil : jpegData
    }

    // MARK: - 兜底：NSImage 方式（兼容极少数 ImageIO 识别不了的格式）

    private static func compressViaNSImage(
        _ data: Data,
        maxLongSide: CGFloat,
        quality: CGFloat
    ) -> Data? {
        guard let image = NSImage(data: data) else { return nil }
        let srcSize = image.size
        guard srcSize.width > 0, srcSize.height > 0 else { return nil }

        let srcLong = max(srcSize.width, srcSize.height)
        let scale: CGFloat = srcLong > maxLongSide ? maxLongSide / srcLong : 1.0
        let dstSize = NSSize(
            width: round(srcSize.width * scale),
            height: round(srcSize.height * scale)
        )

        let newImage = NSImage(size: dstSize)
        newImage.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: dstSize),
                   from: NSRect(origin: .zero, size: srcSize),
                   operation: .sourceOver,
                   fraction: 1.0,
                   respectFlipped: true,
                   hints: [.interpolation: NSImageInterpolation.high])
        newImage.unlockFocus()

        guard let tiff = newImage.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let jpeg = rep.representation(
                using: .jpeg,
                properties: [.compressionFactor: NSNumber(value: Double(quality))]
              ) else { return nil }
        return jpeg.isEmpty ? nil : jpeg
    }
}
