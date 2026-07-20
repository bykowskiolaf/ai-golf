import CoreGraphics
import Foundation

struct PoseOverlayTransform: Equatable, Sendable {
    let imageSize: CGSize
    let viewSize: CGSize

    var fittedImageRect: CGRect {
        guard imageSize.width > 0, imageSize.height > 0, viewSize.width > 0, viewSize.height > 0 else {
            return .zero
        }

        let scale = min(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        let fittedSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)

        return CGRect(
            x: (viewSize.width - fittedSize.width) / 2,
            y: (viewSize.height - fittedSize.height) / 2,
            width: fittedSize.width,
            height: fittedSize.height
        )
    }

    func viewPoint(for point: PosePoint) -> CGPoint {
        let rect = fittedImageRect
        return CGPoint(
            x: rect.minX + (point.x * rect.width),
            y: rect.minY + (point.y * rect.height)
        )
    }
}
