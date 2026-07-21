import Foundation

enum GolferHandedness: String, CaseIterable, Codable, Sendable {
    case rightHanded
    case leftHanded

    var displayName: String {
        switch self {
        case .rightHanded: "Right Handed"
        case .leftHanded: "Left Handed"
        }
    }
}

enum CameraView: String, CaseIterable, Codable, Sendable {
    case faceOn
    case downTheLine
    case unknown

    var displayName: String {
        switch self {
        case .faceOn: "Face On"
        case .downTheLine: "Down the Line"
        case .unknown: "Unknown"
        }
    }
}

enum GolfClub: String, CaseIterable, Codable, Sendable {
    case driver
    case fairwayWood
    case hybrid
    case longIron
    case midIron
    case shortIron
    case wedge
    case unknown

    var displayName: String {
        switch self {
        case .driver: "Driver"
        case .fairwayWood: "Fairway Wood"
        case .hybrid: "Hybrid"
        case .longIron: "Long Iron"
        case .midIron: "Mid Iron"
        case .shortIron: "Short Iron"
        case .wedge: "Wedge"
        case .unknown: "Unknown"
        }
    }
}

enum AnnotatorRole: String, CaseIterable, Codable, Sendable {
    case golfer
    case coach
    case developer
    case unknown

    var displayName: String {
        switch self {
        case .golfer: "Golfer"
        case .coach: "Coach"
        case .developer: "Developer"
        case .unknown: "Unknown"
        }
    }
}

enum SwingPosition: String, CaseIterable, Codable, Sendable {
    case address
    case top
    case impact
    case finish

    var displayName: String {
        switch self {
        case .address: "Address"
        case .top: "Top"
        case .impact: "Impact"
        case .finish: "Finish"
        }
    }

    var explanation: String {
        switch self {
        case .address: "Final settled position before the backswing begins."
        case .top: "End of the backswing immediately before the downswing."
        case .impact: "Frame closest to club-ball contact."
        case .finish: "Stable completed follow-through."
        }
    }
}

enum PositionReadiness: String, Codable, Sendable {
    case poseReady
    case posePartial
    case visualOnly

    var displayName: String {
        switch self {
        case .poseReady: "Pose-ready"
        case .posePartial: "Pose-partial"
        case .visualOnly: "Visual-only"
        }
    }
}

struct SwingAnnotationContext: Codable, Equatable, Sendable {
    var golferHandedness: GolferHandedness = .rightHanded
    var cameraView: CameraView = .unknown
    var golfClub: GolfClub = .unknown
    var golferIdentifier: String = ""
    var annotatorIdentifier: String?
    var annotatorRole: AnnotatorRole = .unknown
    var coachNotes: String = ""
    var recordingDate: Date?
    var videoDurationSeconds: Double = 0
    var videoWidth: Int = 0
    var videoHeight: Int = 0
    var reportedFrameRate: Double = 0
}

enum ExportedCoordinateSystem: String, Codable, Sendable {
    case normalizedTopLeft
}

struct ExportedAnalysisConfiguration: Codable, Equatable, Sendable {
    let intervalStartSeconds: Double
    let intervalEndSeconds: Double
    let requestedSamplingRate: Double
    let effectiveSamplingRate: Double
    let analyzedSampleCount: Int
    let confidenceThreshold: Double
    let maximumInterpolationGapSamples: Int
    let smoothingWindowSize: Int
    let smoothingCenterWeight: Double
    let smoothingNeighborWeight: Double
    let outlierThresholdBodyScale: Double
    let outlierNeighborSpanBodyScale: Double

    init(
        intervalStartSeconds: Double,
        intervalEndSeconds: Double,
        requestedSamplingRate: Double,
        analyzedSampleCount: Int,
        confidenceThreshold: Double,
        cleaningConfiguration: PoseTrackCleaningConfiguration = PoseTrackCleaningConfiguration()
    ) {
        self.intervalStartSeconds = intervalStartSeconds
        self.intervalEndSeconds = intervalEndSeconds
        self.requestedSamplingRate = requestedSamplingRate
        let duration = intervalEndSeconds - intervalStartSeconds
        self.effectiveSamplingRate = duration > 0 && analyzedSampleCount > 0 ? Double(analyzedSampleCount) / duration : 0
        self.analyzedSampleCount = analyzedSampleCount
        self.confidenceThreshold = confidenceThreshold
        maximumInterpolationGapSamples = cleaningConfiguration.maximumInterpolatedGapSamples
        smoothingWindowSize = PoseTrackCleaningConfiguration.smoothingWindowSize
        smoothingCenterWeight = cleaningConfiguration.smoothingCenterWeight
        smoothingNeighborWeight = cleaningConfiguration.smoothingNeighborWeight
        outlierThresholdBodyScale = cleaningConfiguration.outlierDistanceScaleThreshold
        outlierNeighborSpanBodyScale = cleaningConfiguration.outlierNeighborDistanceScaleThreshold
    }
}

struct SwingAnnotationIdentity: Equatable, Sendable {
    var annotationID: UUID
    var createdAt: Date

    init(annotationID: UUID = UUID(), createdAt: Date = Date()) {
        self.annotationID = annotationID
        self.createdAt = createdAt
    }
}

struct PositionLandmarkAvailability: Codable, Equatable, Sendable {
    let shoulderMidpoint: Bool
    let hipMidpoint: Bool
    let torsoAxis: Bool
    let leftShoulder: Bool
    let rightShoulder: Bool
    let leftHip: Bool
    let rightHip: Bool
    let atLeastOneElbow: Bool
    let atLeastOneWrist: Bool
    let bothWrists: Bool
    let wristMidpoint: Bool
}

struct SwingPositionAnnotation: Equatable, Sendable {
    let position: SwingPosition
    let sampleIndex: Int
    let sampleID: UUID
    let requestedTimestamp: Double
    let actualTimestamp: Double
    let poseQualityCategory: PoseSampleQualityCategory
    let readiness: PositionReadiness
    let availability: PositionLandmarkAvailability
    let cleanedPoseSample: CleanedPoseSample
    let missingJoints: [BodyJoint]
    var note: String?
}

struct SwingAnnotationRecord: Codable, Equatable, Sendable {
    static let schemaVersion = 2

    let schemaVersion: Int
    let annotationID: UUID
    let createdAt: Date
    let sourceVideoFilename: String
    let coordinateSystem: ExportedCoordinateSystem
    let context: SwingAnnotationContext
    let analysisConfiguration: ExportedAnalysisConfiguration
    let positions: [ExportedAnnotatedSwingPosition]

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case annotationID
        case createdAt
        case sourceVideoFilename
        case coordinateSystem
        case context
        case analysisConfiguration
        case positions
    }

    init(
        schemaVersion: Int = SwingAnnotationRecord.schemaVersion,
        annotationID: UUID,
        createdAt: Date,
        sourceVideoFilename: String,
        coordinateSystem: ExportedCoordinateSystem = .normalizedTopLeft,
        context: SwingAnnotationContext,
        analysisConfiguration: ExportedAnalysisConfiguration,
        positions: [ExportedAnnotatedSwingPosition]
    ) {
        self.schemaVersion = schemaVersion
        self.annotationID = annotationID
        self.createdAt = createdAt
        self.sourceVideoFilename = sourceVideoFilename
        self.coordinateSystem = coordinateSystem
        self.context = context
        self.analysisConfiguration = analysisConfiguration
        self.positions = positions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.schemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported swing annotation schema version: \(schemaVersion)."
            )
        }

        self.schemaVersion = schemaVersion
        annotationID = try container.decode(UUID.self, forKey: .annotationID)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        sourceVideoFilename = try container.decode(String.self, forKey: .sourceVideoFilename)
        coordinateSystem = try container.decode(ExportedCoordinateSystem.self, forKey: .coordinateSystem)
        context = try container.decode(SwingAnnotationContext.self, forKey: .context)
        analysisConfiguration = try container.decode(ExportedAnalysisConfiguration.self, forKey: .analysisConfiguration)
        positions = try container.decode([ExportedAnnotatedSwingPosition].self, forKey: .positions)
    }
}

struct ExportedAnnotatedSwingPosition: Codable, Equatable, Sendable {
    let position: String
    let sampleIndex: Int
    let requestedTimestampSeconds: Double
    let actualTimestampSeconds: Double
    let poseQualityCategory: String
    let poseReadiness: String
    let note: String?
    let landmarkAvailability: PositionLandmarkAvailability
    let cleanedJoints: [ExportedJointPoint]
    let derivedLandmarks: ExportedDerivedBodyLandmarks
    let missingJoints: [String]
}

struct SwingAnnotationDatasetExport: Equatable, Sendable {
    let stagingDirectory: URL
    let videoURL: URL
    let annotationURL: URL

    var shareItems: [URL] { [videoURL, annotationURL] }
}

struct ExportedJointPoint: Codable, Equatable, Sendable {
    let joint: String
    let x: Double
    let y: Double
    let confidence: Double?
    let source: String
}

struct ExportedPoint: Codable, Equatable, Sendable {
    let x: Double
    let y: Double
    let usesInterpolatedPoint: Bool
}

struct ExportedVector: Codable, Equatable, Sendable {
    let dx: Double
    let dy: Double
    let length: Double
    let usesInterpolatedPoint: Bool
}

struct ExportedDerivedBodyLandmarks: Codable, Equatable, Sendable {
    let shoulderMidpoint: ExportedPoint?
    let hipMidpoint: ExportedPoint?
    let wristMidpoint: ExportedPoint?
    let ankleMidpoint: ExportedPoint?
    let torsoCenter: ExportedPoint?
    let torsoAxis: ExportedVector?
    let shoulderLine: ExportedVector?
    let hipLine: ExportedVector?
    let approximateTorsoLength: Double?
    let approximateShoulderWidth: Double?
}

struct SwingAnnotationValidation: Equatable, Sendable {
    let canExport: Bool
    let message: String
}

struct PositionReadinessConfiguration: Equatable, Sendable {
    var torsoJoints: [BodyJoint]

    init(torsoJoints: [BodyJoint] = [.neck, .root, .leftShoulder, .rightShoulder, .leftHip, .rightHip]) {
        self.torsoJoints = torsoJoints
    }
}

@MainActor
enum SwingAnnotationBuilder {
    static func availability(for sample: CleanedPoseSample) -> PositionLandmarkAvailability {
        PositionLandmarkAvailability(
            shoulderMidpoint: sample.landmarks.shoulderMidpoint != nil,
            hipMidpoint: sample.landmarks.hipMidpoint != nil,
            torsoAxis: sample.landmarks.torsoAxis != nil,
            leftShoulder: sample.joints[.leftShoulder] != nil,
            rightShoulder: sample.joints[.rightShoulder] != nil,
            leftHip: sample.joints[.leftHip] != nil,
            rightHip: sample.joints[.rightHip] != nil,
            atLeastOneElbow: sample.joints[.leftElbow] != nil || sample.joints[.rightElbow] != nil,
            atLeastOneWrist: sample.joints[.leftWrist] != nil || sample.joints[.rightWrist] != nil,
            bothWrists: sample.joints[.leftWrist] != nil && sample.joints[.rightWrist] != nil,
            wristMidpoint: sample.landmarks.wristMidpoint != nil
        )
    }

    static func readiness(for sample: CleanedPoseSample) -> PositionReadiness {
        readiness(for: sample, configuration: PositionReadinessConfiguration())
    }

    static func readiness(for sample: CleanedPoseSample, configuration: PositionReadinessConfiguration) -> PositionReadiness {
        let hasTorso = configuration.torsoJoints.allSatisfy { sample.joints[$0] != nil }
        guard hasTorso else { return .visualOnly }

        let hasLeftArmChain = [.leftShoulder, .leftElbow, .leftWrist].allSatisfy { sample.joints[$0] != nil }
        let hasRightArmChain = [.rightShoulder, .rightElbow, .rightWrist].allSatisfy { sample.joints[$0] != nil }
        return hasLeftArmChain || hasRightArmChain ? .poseReady : .posePartial
    }

    static func validate(annotations: [SwingPosition: SwingPositionAnnotation]) -> SwingAnnotationValidation {
        let missing = SwingPosition.allCases.filter { annotations[$0] == nil }
        guard missing.isEmpty else {
            return SwingAnnotationValidation(canExport: false, message: "Assign all four positions before exporting: \(missing.map(\.displayName).joined(separator: ", ")).")
        }

        let ordered = SwingPosition.allCases.compactMap { annotations[$0] }
        for pair in zip(ordered, ordered.dropFirst()) where pair.0.actualTimestamp >= pair.1.actualTimestamp {
            return SwingAnnotationValidation(
                canExport: false,
                message: "Chronological order must be Address < Top < Impact < Finish. \(pair.0.position.displayName) is not before \(pair.1.position.displayName)."
            )
        }

        return SwingAnnotationValidation(canExport: true, message: "Annotation is complete and chronologically valid.")
    }

    static func record(
        identity: SwingAnnotationIdentity,
        sourceVideoFilename: String,
        context: SwingAnnotationContext,
        analysisConfiguration: ExportedAnalysisConfiguration,
        annotations: [SwingPosition: SwingPositionAnnotation]
    ) throws -> SwingAnnotationRecord {
        let validation = validate(annotations: annotations)
        guard validation.canExport else { throw SwingAnnotationExportError.invalid(validation.message) }

        return SwingAnnotationRecord(
            schemaVersion: SwingAnnotationRecord.schemaVersion,
            annotationID: identity.annotationID,
            createdAt: identity.createdAt,
            sourceVideoFilename: sourceVideoFilename,
            coordinateSystem: .normalizedTopLeft,
            context: context,
            analysisConfiguration: analysisConfiguration,
            positions: SwingPosition.allCases.compactMap { position in
                annotations[position].map(exportedPosition)
            }
        )
    }

    private static func exportedPosition(_ annotation: SwingPositionAnnotation) -> ExportedAnnotatedSwingPosition {
        ExportedAnnotatedSwingPosition(
            position: annotation.position.rawValue,
            sampleIndex: annotation.sampleIndex,
            requestedTimestampSeconds: annotation.requestedTimestamp,
            actualTimestampSeconds: annotation.actualTimestamp,
            poseQualityCategory: annotation.poseQualityCategory.rawValue,
            poseReadiness: annotation.readiness.rawValue,
            note: normalizedNote(annotation.note),
            landmarkAvailability: annotation.availability,
            cleanedJoints: annotation.cleanedPoseSample.joints.map { joint, point in
                ExportedJointPoint(joint: joint.rawValue, x: point.x, y: point.y, confidence: point.confidence, source: sourceName(point.source))
            }.sorted { $0.joint < $1.joint },
            derivedLandmarks: exportedLandmarks(annotation.cleanedPoseSample.landmarks),
            missingJoints: annotation.missingJoints.map(\.rawValue).sorted()
        )
    }

    private static func exportedLandmarks(_ landmarks: DerivedBodyLandmarks) -> ExportedDerivedBodyLandmarks {
        ExportedDerivedBodyLandmarks(
            shoulderMidpoint: exportedPoint(landmarks.shoulderMidpoint),
            hipMidpoint: exportedPoint(landmarks.hipMidpoint),
            wristMidpoint: exportedPoint(landmarks.wristMidpoint),
            ankleMidpoint: exportedPoint(landmarks.ankleMidpoint),
            torsoCenter: exportedPoint(landmarks.torsoCenter),
            torsoAxis: exportedVector(landmarks.torsoAxis),
            shoulderLine: exportedVector(landmarks.shoulderLine),
            hipLine: exportedVector(landmarks.hipLine),
            approximateTorsoLength: landmarks.approximateTorsoLength,
            approximateShoulderWidth: landmarks.approximateShoulderWidth
        )
    }

    private static func exportedPoint(_ point: DerivedLandmarkPoint?) -> ExportedPoint? {
        point.map { ExportedPoint(x: $0.x, y: $0.y, usesInterpolatedPoint: $0.usesInterpolatedPoint) }
    }

    private static func exportedVector(_ vector: DerivedLandmarkVector?) -> ExportedVector? {
        vector.map { ExportedVector(dx: $0.dx, dy: $0.dy, length: $0.length, usesInterpolatedPoint: $0.usesInterpolatedPoint) }
    }

    private static func sourceName(_ source: JointPointSource) -> String {
        switch source {
        case .observed: "observed"
        case .interpolated: "interpolated"
        }
    }

    static func normalizedNote(_ note: String?) -> String? {
        guard let note else { return nil }
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum SwingAnnotationExportError: Error, Equatable {
    case invalid(String)
}
