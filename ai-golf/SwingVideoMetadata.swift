import Foundation

struct SwingVideoMetadata: Equatable {
    let durationSeconds: Double
    let width: Int
    let height: Int
    let nominalFrameRate: Float
    let hasUsableVideoTrack: Bool

    var isHighFrameRateSource: Bool {
        nominalFrameRate >= 100
    }
}
