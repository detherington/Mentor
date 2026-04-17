import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import CoreGraphics
import AppKit

struct WebcamLayout {
    let position: WebcamPosition
    let shape: WebcamShape
    let diameter: CGFloat
    let inset: CGFloat

    var visible: Bool { position != .hidden }
}

final class FrameCompositor {
    private let context: CIContext
    private let bufferPool: CVPixelBufferPool
    private let outputSize: CGSize
    private let webcam: WebcamLayout
    private let circularMask: CIImage?

    init(outputSize: CGSize, webcam: WebcamLayout) throws {
        self.outputSize = outputSize
        self.webcam = webcam
        self.context = CIContext(options: [
            .useSoftwareRenderer: false,
            .cacheIntermediates: false
        ])

        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(outputSize.width),
            kCVPixelBufferHeightKey as String: Int(outputSize.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
        guard status == kCVReturnSuccess, let pool else {
            throw CompositorError.poolCreationFailed
        }
        self.bufferPool = pool

        self.circularMask = webcam.visible
            ? FrameCompositor.makeShapeMask(diameter: webcam.diameter, shape: webcam.shape)
            : nil
    }

    func composite(screen: CVPixelBuffer, camera: CVPixelBuffer?) -> CVPixelBuffer? {
        var outBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, bufferPool, &outBuffer) == kCVReturnSuccess,
              let outBuffer else { return nil }

        let screenCI = CIImage(cvPixelBuffer: screen)
        let scaledScreen = scaledToFill(screenCI, size: outputSize)
        var composite = scaledScreen

        if webcam.visible, let camera, let cameraImage = circularCameraImage(from: camera) {
            let origin = webcamOrigin()
            let translated = cameraImage.transformed(
                by: CGAffineTransform(translationX: origin.x, y: origin.y)
            )
            composite = translated.composited(over: composite)
        }

        let cropped = composite.cropped(to: CGRect(origin: .zero, size: outputSize))
        context.render(
            cropped,
            to: outBuffer,
            bounds: CGRect(origin: .zero, size: outputSize),
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
        )
        return outBuffer
    }

    private func webcamOrigin() -> CGPoint {
        let d = webcam.diameter
        let i = webcam.inset
        // CIImage origin is bottom-left
        switch webcam.position {
        case .bottomRight: return CGPoint(x: outputSize.width - d - i, y: i)
        case .bottomLeft:  return CGPoint(x: i,                           y: i)
        case .topRight:    return CGPoint(x: outputSize.width - d - i, y: outputSize.height - d - i)
        case .topLeft:     return CGPoint(x: i,                           y: outputSize.height - d - i)
        case .hidden:      return .zero
        }
    }

    private func scaledToFill(_ image: CIImage, size: CGSize) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }
        let sx = size.width / extent.width
        let sy = size.height / extent.height
        let s = max(sx, sy)
        return image.transformed(by: CGAffineTransform(scaleX: s, y: s))
    }

    private func circularCameraImage(from camera: CVPixelBuffer) -> CIImage? {
        guard let circularMask else { return nil }
        let raw = CIImage(cvPixelBuffer: camera)
        let extent = raw.extent
        guard extent.width > 0, extent.height > 0 else { return nil }

        // Crop the full source short side (square center-crop of the
        // widescreen source) and scale it to the circle diameter. This
        // gives a natural "head and shoulders" framing at default sizes.
        let side = min(extent.width, extent.height)
        let cropX = (extent.width - side) / 2
        let cropY = (extent.height - side) / 2
        let cropped = raw
            .cropped(to: CGRect(x: cropX, y: cropY, width: side, height: side))
            .transformed(by: CGAffineTransform(translationX: -cropX, y: -cropY))

        let scale = webcam.diameter / side
        let scaled = cropped.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let mirrored = scaled
            .transformed(by: CGAffineTransform(scaleX: -1, y: 1))
            .transformed(by: CGAffineTransform(translationX: webcam.diameter, y: 0))

        let blend = CIFilter.blendWithMask()
        blend.inputImage = mirrored
        blend.backgroundImage = CIImage(color: CIColor.clear)
            .cropped(to: CGRect(x: 0, y: 0, width: webcam.diameter, height: webcam.diameter))
        blend.maskImage = circularMask
        return blend.outputImage?.cropped(
            to: CGRect(x: 0, y: 0, width: webcam.diameter, height: webcam.diameter)
        )
    }

    private static func makeShapeMask(diameter: CGFloat, shape: WebcamShape) -> CIImage {
        let size = Int(diameter)
        let bytesPerRow = size
        let space = CGColorSpaceCreateDeviceGray()
        let ctx = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: space,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        )!
        let rect = CGRect(x: 0, y: 0, width: size, height: size)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(rect)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.addPath(shape.path(in: rect))
        ctx.fillPath()
        return CIImage(cgImage: ctx.makeImage()!)
    }
}

enum CompositorError: Error, LocalizedError {
    case poolCreationFailed

    var errorDescription: String? {
        switch self {
        case .poolCreationFailed: return "Failed to create pixel buffer pool."
        }
    }
}
