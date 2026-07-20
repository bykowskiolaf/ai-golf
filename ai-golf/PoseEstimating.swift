import CoreGraphics
import Foundation
import Vision

protocol PoseEstimating: Sendable {
    func detectPose(in image: CGImage, minimumConfidence: Double) async throws -> DetectedPose?
}

struct VisionPoseEstimator: PoseEstimating {
    func detectPose(in image: CGImage, minimumConfidence: Double) async throws -> DetectedPose? {
        try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let request = VNDetectHumanBodyPoseRequest()
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            try handler.perform([request])
            try Task.checkCancellation()

            guard let observation = request.results?.first else {
                return nil
            }

            let recognizedPoints = try observation.recognizedPoints(.all)
            var points: [BodyJoint: PosePoint] = [:]

            for (visionJoint, recognizedPoint) in recognizedPoints {
                guard let joint = BodyJoint(visionJoint: visionJoint) else { continue }

                points[joint] = PosePoint(
                    joint: joint,
                    x: Double(recognizedPoint.location.x),
                    // Vision reports normalized coordinates with a bottom-left origin. The app stores top-left UI coordinates.
                    y: PoseCoordinateSystem.appY(fromVisionY: Double(recognizedPoint.location.y)),
                    confidence: Double(recognizedPoint.confidence)
                )
            }

            guard !points.isEmpty else { return nil }
            return DetectedPose(points: points, minimumConfidence: minimumConfidence)
        }.value
    }
}

private extension BodyJoint {
    nonisolated init?(visionJoint: VNHumanBodyPoseObservation.JointName) {
        switch visionJoint {
        case .nose: self = .nose
        case .leftEye: self = .leftEye
        case .rightEye: self = .rightEye
        case .leftEar: self = .leftEar
        case .rightEar: self = .rightEar
        case .neck: self = .neck
        case .root: self = .root
        case .leftShoulder: self = .leftShoulder
        case .rightShoulder: self = .rightShoulder
        case .leftElbow: self = .leftElbow
        case .rightElbow: self = .rightElbow
        case .leftWrist: self = .leftWrist
        case .rightWrist: self = .rightWrist
        case .leftHip: self = .leftHip
        case .rightHip: self = .rightHip
        case .leftKnee: self = .leftKnee
        case .rightKnee: self = .rightKnee
        case .leftAnkle: self = .leftAnkle
        case .rightAnkle: self = .rightAnkle
        default: return nil
        }
    }
}
