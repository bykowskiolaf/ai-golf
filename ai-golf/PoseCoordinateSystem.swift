import Foundation

enum PoseCoordinateSystem {
    nonisolated static func appY(fromVisionY visionY: Double) -> Double {
        1 - visionY
    }
}
