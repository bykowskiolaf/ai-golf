import Foundation

enum BodyJoint: String, CaseIterable, Sendable {
    case nose
    case leftEye
    case rightEye
    case leftEar
    case rightEar
    case neck
    case root
    case leftShoulder
    case rightShoulder
    case leftElbow
    case rightElbow
    case leftWrist
    case rightWrist
    case leftHip
    case rightHip
    case leftKnee
    case rightKnee
    case leftAnkle
    case rightAnkle

    var displayName: String {
        switch self {
        case .nose: "Nose"
        case .leftEye: "Left Eye"
        case .rightEye: "Right Eye"
        case .leftEar: "Left Ear"
        case .rightEar: "Right Ear"
        case .neck: "Neck"
        case .root: "Root"
        case .leftShoulder: "Left Shoulder"
        case .rightShoulder: "Right Shoulder"
        case .leftElbow: "Left Elbow"
        case .rightElbow: "Right Elbow"
        case .leftWrist: "Left Wrist"
        case .rightWrist: "Right Wrist"
        case .leftHip: "Left Hip"
        case .rightHip: "Right Hip"
        case .leftKnee: "Left Knee"
        case .rightKnee: "Right Knee"
        case .leftAnkle: "Left Ankle"
        case .rightAnkle: "Right Ankle"
        }
    }
}
