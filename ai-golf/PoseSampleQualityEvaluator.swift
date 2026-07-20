import Foundation

enum PoseSampleQualityEvaluator {
    static func evaluate(pose: DetectedPose?) -> PoseSampleQuality {
        guard let pose else {
            return PoseSampleQuality(
                category: .noPose,
                acceptedJointCount: 0,
                missingJoints: BodyJoint.allCases,
                hasSufficientTorso: false,
                hasSufficientBothArms: false,
                hasSufficientBothLegs: false
            )
        }

        let accepted = Set(pose.acceptedPoints.map(\.joint))
        let missing = BodyJoint.allCases.filter { !accepted.contains($0) }
        let hasTorso = accepted.contains(.root)
            && accepted.contains(.neck)
            && accepted.contains(.leftShoulder)
            && accepted.contains(.rightShoulder)
            && accepted.contains(.leftHip)
            && accepted.contains(.rightHip)
        let hasLeftArm = [.leftShoulder, .leftElbow, .leftWrist].allSatisfy { accepted.contains($0) }
        let hasRightArm = [.rightShoulder, .rightElbow, .rightWrist].allSatisfy { accepted.contains($0) }
        let hasLeftLeg = [.leftHip, .leftKnee, .leftAnkle].allSatisfy { accepted.contains($0) }
        let hasRightLeg = [.rightHip, .rightKnee, .rightAnkle].allSatisfy { accepted.contains($0) }

        let category: PoseSampleQualityCategory
        if !hasTorso {
            category = .torsoInsufficient
        } else if hasLeftArm && hasRightArm && hasLeftLeg && hasRightLeg {
            category = .complete
        } else {
            category = .partial
        }

        return PoseSampleQuality(
            category: category,
            acceptedJointCount: accepted.count,
            missingJoints: missing,
            hasSufficientTorso: hasTorso,
            hasSufficientBothArms: hasLeftArm && hasRightArm,
            hasSufficientBothLegs: hasLeftLeg && hasRightLeg
        )
    }
}
