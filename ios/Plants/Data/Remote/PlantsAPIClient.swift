import CryptoKit
import Foundation

struct ProfileSettingsDTO: Decodable, Sendable, Equatable {
    let preferredLocale: String
    let reminderHourLocal: Int

    private enum CodingKeys: String, CodingKey {
        case preferredLocale = "preferred_locale"
        case reminderHourLocal = "reminder_hour_local"
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        preferredLocale = try values.decode(String.self, forKey: .preferredLocale)
        reminderHourLocal = try values.decode(Int.self, forKey: .reminderHourLocal)
        guard ["en", "pl"].contains(preferredLocale), (0...23).contains(reminderHourLocal) else {
            throw SyncWireValidationError.invalidPage
        }
    }
}

struct ProfileReminderHourCommand: Sendable {
    let envelope: CommandEnvelopeDTO
    let reminderHourLocal: Int

    private init(envelope: CommandEnvelopeDTO, reminderHourLocal: Int) {
        self.envelope = envelope
        self.reminderHourLocal = reminderHourLocal
    }

    /// Only the exact persisted representation made by this type can be retried.
    init?(_ envelope: CommandEnvelopeDTO) {
        guard envelope.commandName == "profile.update", envelope.plantId == nil,
              let object = try? JSONSerialization.jsonObject(with: Data(envelope.payloadJSON.utf8)),
              let payload = object as? [String: Any], payload.count == 1,
              let hour = payload["reminder_hour_local"] as? Int,
              let expected = try? Self.make(reminderHourLocal: hour, operationId: envelope.operationId),
              expected.envelope == envelope else { return nil }
        self = expected
    }

    static func make(reminderHourLocal: Int, operationId: UUID = UUID()) throws -> Self {
        guard (0...23).contains(reminderHourLocal) else {
            throw SyncWireValidationError.invalidRequest
        }
        return Self(
            envelope: CommandEnvelopeDTO(
                operationId: operationId, commandName: "profile.update",
                payloadJSON: "{\"reminder_hour_local\":\(reminderHourLocal)}"
            ),
            reminderHourLocal: reminderHourLocal
        )
    }
}

private struct ProfileSettingsResponse: Decodable {
    let profile: ProfileSettingsDTO
}

struct ProfileReminderHourReceipt: Decodable, Sendable {
    let profile: ProfileSettingsDTO
    let watermarkRaw: String
    let watermark: Int64

    private enum CodingKeys: String, CodingKey {
        case profile, watermark
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        profile = try values.decode(ProfileSettingsDTO.self, forKey: .profile)
        watermarkRaw = try values.decode(String.self, forKey: .watermark)
        guard let micros = SQLTimestamp.microseconds(from: watermarkRaw), micros >= 0 else {
            throw SyncWireValidationError.invalidPage
        }
        watermark = micros
    }
}

struct PlantCareRecommendation: Decodable, Sendable, Equatable {
    struct Source: Decodable, Sendable, Equatable {
        let url: URL
        let locator: String

        var isVerifiedLink: Bool {
            guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
            return parts.scheme?.lowercased() == "https" && parts.host?.isEmpty == false
                && parts.user == nil && parts.password == nil
                && !locator.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    struct NextCheck: Decodable, Sendable, Equatable {
        let dueOn: String
        let anchorOn: String
        let intervalDays: Int
        let basis: String
        let source: Source

        enum CodingKeys: String, CodingKey {
            case dueOn = "due_on"
            case anchorOn = "anchor_on"
            case intervalDays = "interval_days"
            case basis, source
        }

        fileprivate func matches(interval: Int?) -> Bool {
            guard intervalDays > 0, intervalDays == interval, source.isVerifiedLink,
                  !basis.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            guard let anchor = SQLCalendarDay.date(from: anchorOn),
                  let due = SQLCalendarDay.date(from: dueOn) else { return false }
            return SQLCalendarDay.calendar.dateComponents([.day], from: anchor, to: due).day == intervalDays
        }
    }

    struct RoutineCheck: Decodable, Sendable, Equatable {
        enum AnchorKind: String, Decodable, Sendable {
            case water
            case checkSoil = "check_soil"
        }

        let ruleId: UUID
        let careRevision: Int
        let dueLocalDate: String
        let anchorLocalDate: String
        let anchorKind: AnchorKind

        enum CodingKeys: String, CodingKey {
            case ruleId = "rule_id"
            case careRevision = "care_revision"
            case dueLocalDate = "due_local_date"
            case anchorLocalDate = "anchor_local_date"
            case anchorKind = "anchor_kind"
        }
    }

    struct RoutineContext: Sendable, Equatable {
        let plantId: UUID
        let check: RoutineCheck
    }

    let actionId: String
    let actionCode: String
    let text: String
    let nextCheckIntervalDays: Int?
    let source: Source
    fileprivate(set) var nextCheck: NextCheck? = nil
    fileprivate(set) var routineContext: RoutineContext? = nil

    enum CodingKeys: String, CodingKey {
        case actionId = "action_id"
        case actionCode = "action_code"
        case text, source
        case nextCheckIntervalDays = "next_check_interval_days"
    }
}

private struct PlantCareRecommendationResponse: Decodable {
    enum Status: String, Decodable { case available, unavailable }

    let plantId: UUID
    let status: Status
    let recommendation: PlantCareRecommendation?
    let nextCheck: PlantCareRecommendation.NextCheck?
    let routineCheck: PlantCareRecommendation.RoutineCheck?

    enum CodingKeys: String, CodingKey {
        case plantId = "plant_id"
        case status, recommendation
        case nextCheck = "next_check"
        case routineCheck = "routine_check"
    }

    func validated(for expectedPlantId: UUID) throws -> PlantCareRecommendation? {
        guard plantId == expectedPlantId else { throw AnalysisHTTPError.invalidResponse }
        if status == .unavailable, recommendation == nil, nextCheck == nil, routineCheck == nil { return nil }
        guard status == .available, var recommendation,
              recommendation.actionCode == "check_soil",
              recommendation.nextCheckIntervalDays.map({ $0 > 0 }) ?? true,
              [recommendation.actionId, recommendation.text].allSatisfy({
                  !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              }),
              recommendation.source.isVerifiedLink,
              nextCheck?.matches(interval: recommendation.nextCheckIntervalDays) ?? true else {
            throw AnalysisHTTPError.invalidResponse
        }
        if let routineCheck {
            guard let nextCheck,
                  (1...9_007_199_254_740_991).contains(routineCheck.careRevision),
                  routineCheck.dueLocalDate == nextCheck.dueOn,
                  routineCheck.anchorLocalDate == nextCheck.anchorOn else {
                throw AnalysisHTTPError.invalidResponse
            }
            recommendation.routineContext = .init(plantId: plantId, check: routineCheck)
        }
        recommendation.nextCheck = nextCheck
        return recommendation
    }
}

enum ManualWateringAction: Sendable, Equatable {
    case record
    case undo(UUID)
    case correctDate(entryId: UUID, occurredAt: String, timezone: String)

    static let correctionCommand = "care.correct_date"
    static let undoCommand = "care.undo"

    static func accepts(command: String) -> Bool {
        ["care.record", undoCommand, correctionCommand].contains(command)
    }

    init?(envelope: CommandEnvelopeDTO) {
        guard envelope.plantId != nil,
              Self.accepts(command: envelope.commandName),
              let payload = try? JSONSerialization.jsonObject(with: Data(envelope.payloadJSON.utf8)) as? [String: String] else {
            return nil
        }
        switch envelope.commandName {
        case "care.record":
            guard payload.count == 3, payload["action_code"] == "water",
                  let occurredAt = payload["occurred_at"], SQLTimestamp.microseconds(from: occurredAt) != nil,
                  let timezone = payload["timezone"], TimeZone(identifier: timezone) != nil else { return nil }
            self = .record
        case Self.undoCommand:
            guard payload.count == 1, let id = payload["entry_id"], let entryId = UUID(uuidString: id) else { return nil }
            self = .undo(entryId)
        default:
            guard payload.count == 3, let id = payload["entry_id"], let entryId = UUID(uuidString: id),
                  let occurredAt = payload["occurred_at"], SQLTimestamp.microseconds(from: occurredAt) != nil,
                  let timezone = payload["timezone"], TimeZone(identifier: timezone) != nil else { return nil }
            self = .correctDate(entryId: entryId, occurredAt: occurredAt, timezone: timezone)
        }
    }

    static func correction(entryId: UUID, date: Date, timezone: TimeZone) -> Self {
        .correctDate(entryId: entryId, occurredAt: timestamp(date, timezone: timezone), timezone: timezone.identifier)
    }

    fileprivate static func timestamp(_ date: Date, timezone: TimeZone) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = timezone
        return formatter.string(from: date)
    }

    func envelope(plantId: UUID, operationId: UUID = UUID(), now: Date = Date(),
                  timezone: TimeZone = .current) throws -> CommandEnvelopeDTO {
        let name: String
        let payload: [String: String]
        switch self {
        case .record:
            name = "care.record"
            payload = ["action_code": "water", "occurred_at": Self.timestamp(now, timezone: timezone), "timezone": timezone.identifier]
        case let .undo(entryId):
            name = Self.undoCommand
            payload = ["entry_id": entryId.uuidString.lowercased()]
        case let .correctDate(entryId, occurredAt, timezone):
            name = Self.correctionCommand
            payload = ["entry_id": entryId.uuidString.lowercased(), "occurred_at": occurredAt, "timezone": timezone]
        }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return CommandEnvelopeDTO(operationId: operationId, commandName: name, plantId: plantId,
                                  payloadJSON: String(decoding: data, as: UTF8.self))
    }
}

struct FirstAidRecordCommand: Sendable {
    static let name = "care.first_aid.record"
    let envelope: CommandEnvelopeDTO
    let plantId: UUID
    let jobId: UUID

    init?(envelope: CommandEnvelopeDTO) {
        guard envelope.commandName == Self.name, let plantId = envelope.plantId,
              let fields = try? JSONDecoder().decode([String: String].self, from: Data(envelope.payloadJSON.utf8)),
              fields.count == 3, let jobId = fields["job_id"].flatMap(UUID.init(uuidString:)),
              let date = fields["occurred_at"], SQLTimestamp.microseconds(from: date) != nil,
              let timezone = fields["timezone"], TimeZone(identifier: timezone) != nil else { return nil }
        self.envelope = envelope
        self.plantId = plantId
        self.jobId = jobId
    }

    static func make(for action: RecordableFirstAidAction, date: Date, timezone: TimeZone) throws -> FirstAidRecordCommand {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let body = try encoder.encode([
            "job_id": action.jobId.uuidString.lowercased(),
            "occurred_at": ManualWateringAction.timestamp(date, timezone: timezone),
            "timezone": timezone.identifier
        ])
        let envelope = CommandEnvelopeDTO(operationId: UUID(), commandName: name, plantId: action.plantId,
                                          payloadJSON: String(decoding: body, as: UTF8.self))
        guard let command = Self(envelope: envelope) else { throw SyncWireValidationError.invalidRequest }
        return command
    }
}

struct FirstAidRecordReceipt: Decodable, Sendable {
    let plantId: UUID
    let entryId: UUID
    let controlId: UUID?
    let watermark: Int64

    enum CodingKeys: String, CodingKey {
        case plantId = "plant_id"
        case entryId = "entry_id"
        case controlId = "control_id"
        case reversalId = "reversal_id"
        case state, watermark
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        plantId = try values.decode(UUID.self, forKey: .plantId)
        entryId = try values.decode(UUID.self, forKey: .entryId)
        controlId = try values.decode(UUID?.self, forKey: .controlId)
        guard try values.decode(String.self, forKey: .state) == "active",
              try values.decode(UUID?.self, forKey: .reversalId) == nil,
              let time = SQLTimestamp.microseconds(from: try values.decode(String.self, forKey: .watermark)) else {
            throw SyncWireValidationError.invalidPage
        }
        watermark = time
    }
}

enum PlantLightCode: String, Codable, Sendable, CaseIterable {
    case low, medium, brightIndirect = "bright_indirect", directSun = "direct_sun", unknown

    var label: String {
        switch self {
        case .low: "Low light"
        case .medium: "Medium light"
        case .brightIndirect: "Bright indirect light"
        case .directSun: "Direct sunlight"
        case .unknown: "Unknown"
        }
    }
}

enum PlantDrainageCode: String, Codable, Sendable, CaseIterable {
    case yes, no, unknown

    var label: String {
        switch self {
        case .yes: "Drainage holes"
        case .no: "No drainage holes"
        case .unknown: "Unknown drainage"
        }
    }
}

enum PlantWateringCode: String, Codable, Sendable, CaseIterable {
    case severalWeekly = "several_weekly", weekly, lessOften = "less_often"
    case frequent, moderate, sparse, unknown

    static let choices: [Self] = [.severalWeekly, .weekly, .lessOften, .unknown]

    var label: String {
        switch self {
        case .severalWeekly: "Several times a week"
        case .weekly: "Once a week"
        case .lessOften: "Less often"
        case .frequent: "Frequent watering"
        case .moderate: "Moderate watering"
        case .sparse: "Sparse watering"
        case .unknown: "Unknown watering frequency"
        }
    }
}

enum PlantPotType: String, Codable, Sendable, CaseIterable {
    case terracotta, plastic, glazedCeramic = "glazed_ceramic"
    case standardDrainage = "standard_drainage", other, unknown

    var label: String {
        switch self {
        case .terracotta: "Terracotta"
        case .plastic: "Plastic"
        case .glazedCeramic: "Glazed ceramic"
        case .standardDrainage: "Standard drainage pot"
        case .other: "Other pot type"
        case .unknown: "Unknown pot type"
        }
    }
}

struct PlantConditionCodes: Decodable, Sendable {
    let id: UUID
    let plantId: UUID
    let light: PlantLightCode?
    let drainage: PlantDrainageCode?
    let watering: PlantWateringCode?
    let potType: PlantPotType?

    enum CodingKeys: String, CodingKey {
        case id
        case plantId = "plant_id"
        case light = "light_code"
        case drainage = "drainage_code"
        case watering = "watering_code"
        case potType = "pot_type"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        plantId = try values.decode(UUID.self, forKey: .plantId)
        light = (try? values.decode(String.self, forKey: .light)).flatMap(PlantLightCode.init(rawValue:))
        drainage = (try? values.decode(String.self, forKey: .drainage)).flatMap(PlantDrainageCode.init(rawValue:))
        watering = (try? values.decode(String.self, forKey: .watering)).flatMap(PlantWateringCode.init(rawValue:))
        potType = (try? values.decode(String.self, forKey: .potType)).flatMap(PlantPotType.init(rawValue:))
    }
}

struct PlantEditCommand: Sendable {
    enum Change: Sendable {
        case name(String)
        case taxon(UUID)
        case light(PlantLightCode)
        case drainage(PlantDrainageCode)
        case watering(PlantWateringCode)
        case potType(PlantPotType)
    }

    static let name = "plant.edit"
    let envelope: CommandEnvelopeDTO
    let change: Change

    static func normalizedName(_ input: String) -> String? {
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...120).contains(name.unicodeScalars.count), !name.utf8.contains(0) else { return nil }
        return name
    }

    static func make(plantId: UUID, change: Change) throws -> Self {
        let fields: [String: Any]
        switch change {
        case let .name(input):
            guard let name = normalizedName(input) else { throw SyncWireValidationError.invalidRequest }
            fields = ["personal_name": name]
        case let .taxon(id):
            fields = ["taxon_id": id.uuidString.lowercased()]
        case let .light(light):
            fields = ["conditions": ["light_code": light.rawValue]]
        case let .drainage(drainage):
            fields = ["conditions": ["drainage_code": drainage.rawValue]]
        case let .watering(watering):
            fields = ["conditions": ["watering_code": watering.rawValue]]
        case let .potType(potType):
            fields = ["conditions": ["pot_type": potType.rawValue]]
        }
        let payload = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        let envelope = CommandEnvelopeDTO(
            operationId: UUID(), commandName: Self.name, plantId: plantId,
            payloadJSON: String(decoding: payload, as: UTF8.self)
        )
        guard let command = Self(envelope) else { throw SyncWireValidationError.invalidRequest }
        return command
    }

    init?(_ envelope: CommandEnvelopeDTO) {
        guard envelope.commandName == Self.name, envelope.plantId != nil,
              let fields = try? JSONSerialization.jsonObject(with: Data(envelope.payloadJSON.utf8)) as? [String: Any],
              fields.count == 1 else { return nil }
        if let name = fields["personal_name"] as? String, Self.normalizedName(name) == name {
            change = .name(name)
        } else if let taxon = fields["taxon_id"] as? String, let id = UUID(uuidString: taxon) {
            change = .taxon(id)
        } else if let conditions = fields["conditions"] as? [String: String], conditions.count == 1,
                  let light = conditions["light_code"].flatMap(PlantLightCode.init(rawValue:)) {
            change = .light(light)
        } else if let conditions = fields["conditions"] as? [String: String], conditions.count == 1,
                  let drainage = conditions["drainage_code"].flatMap(PlantDrainageCode.init(rawValue:)) {
            change = .drainage(drainage)
        } else if let conditions = fields["conditions"] as? [String: String], conditions.count == 1,
                  let watering = conditions["watering_code"].flatMap(PlantWateringCode.init(rawValue:)) {
            change = .watering(watering)
        } else if let conditions = fields["conditions"] as? [String: String], conditions.count == 1,
                  let potType = conditions["pot_type"].flatMap(PlantPotType.init(rawValue:)) {
            change = .potType(potType)
        } else {
            return nil
        }
        self.envelope = envelope
    }
}

struct PlantEditReceipt: Decodable, Sendable {
    let plantId: UUID
    let revision: Int
    let careRevision: Int
    let conditionSnapshotId: UUID?
    let watermark: Int64

    enum CodingKeys: String, CodingKey {
        case plantId = "plant_id"
        case revision, watermark
        case careRevision = "care_revision"
        case conditionSnapshotId = "condition_snapshot_id"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        plantId = try values.decode(UUID.self, forKey: .plantId)
        revision = try values.decode(Int.self, forKey: .revision)
        careRevision = try values.decode(Int.self, forKey: .careRevision)
        conditionSnapshotId = try values.decode(UUID?.self, forKey: .conditionSnapshotId)
        guard (1...9_007_199_254_740_991).contains(revision), (1...revision).contains(careRevision),
              let micros = SQLTimestamp.microseconds(from: try values.decode(String.self, forKey: .watermark))
        else { throw SyncWireValidationError.invalidPage }
        watermark = micros
    }
}

struct BasicCareEnableReceipt: Decodable, Sendable {
    static let commandName = "basic_care.enable"

    let plantId: UUID
    let enabled: Bool
    let enabledAt: String

    enum CodingKeys: String, CodingKey {
        case plantId = "plant_id"
        case enabled
        case enabledAt = "enabled_at"
    }
}

/// Fixture-only transport command. Keep the captured envelope unchanged on replay.
struct RoutineSoilCheckCompletionCommand: Sendable {
    static let name = "care.check_soil.complete"
    let envelope: CommandEnvelopeDTO
    let ruleId: UUID
    let careRevision: Int
    let dueLocalDate: String

    private struct Payload: Codable {
        let ruleId: UUID
        let expectedCareRevision: Int32
        let dueLocalDate: String
        let occurredAt: String
        let timezone: String

        enum CodingKeys: String, CodingKey {
            case ruleId = "rule_id"
            case expectedCareRevision = "expected_care_revision"
            case dueLocalDate = "due_local_date"
            case occurredAt = "occurred_at"
            case timezone
        }
    }

    static func make(
        plantId: UUID, routineContext: PlantCareRecommendation.RoutineContext,
        occurredAt: String, timezone: String, operationId: UUID = UUID()
    ) throws -> Self {
        guard routineContext.plantId == plantId,
              let revision = Int32(exactly: routineContext.check.careRevision)
        else { throw SyncWireValidationError.invalidRequest }
        let payload = Payload(
            ruleId: routineContext.check.ruleId, expectedCareRevision: revision,
            dueLocalDate: routineContext.check.dueLocalDate, occurredAt: occurredAt, timezone: timezone
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payload)
        let envelope = CommandEnvelopeDTO(
            operationId: operationId, commandName: name, plantId: plantId,
            payloadJSON: String(decoding: data, as: UTF8.self)
        )
        guard let command = Self(envelope) else { throw SyncWireValidationError.invalidRequest }
        return command
    }

    init?(_ envelope: CommandEnvelopeDTO) {
        let data = Data(envelope.payloadJSON.utf8)
        guard envelope.commandName == Self.name, envelope.plantId != nil,
              let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              fields.count == 5,
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.expectedCareRevision > 0,
              SQLCalendarDay.date(from: payload.dueLocalDate) != nil,
              SQLTimestamp.microseconds(from: payload.occurredAt) != nil,
              payload.timezone == "UTC" || payload.timezone == "GMT"
                || TimeZone.knownTimeZoneIdentifiers.contains(payload.timezone)
        else { return nil }
        self.envelope = envelope
        ruleId = payload.ruleId
        careRevision = Int(payload.expectedCareRevision)
        dueLocalDate = payload.dueLocalDate
    }
}

struct RoutineSoilCheckCompletionReceipt: Decodable, Sendable {
    enum State: String, Decodable, Sendable { case completed }

    let plantId: UUID
    let ruleId: UUID
    let careRevision: Int32
    let occurrenceKey: String
    let dueLocalDate: String
    let taskId: UUID
    let entryId: UUID
    let state: State
    let watermark: Int64

    enum CodingKeys: String, CodingKey {
        case plantId = "plant_id"
        case ruleId = "rule_id"
        case careRevision = "care_revision"
        case occurrenceKey = "occurrence_key"
        case dueLocalDate = "due_local_date"
        case taskId = "task_id"
        case entryId = "entry_id"
        case state, watermark
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        plantId = try values.decode(UUID.self, forKey: .plantId)
        ruleId = try values.decode(UUID.self, forKey: .ruleId)
        careRevision = try values.decode(Int32.self, forKey: .careRevision)
        occurrenceKey = try values.decode(String.self, forKey: .occurrenceKey)
        dueLocalDate = try values.decode(String.self, forKey: .dueLocalDate)
        taskId = try values.decode(UUID.self, forKey: .taskId)
        entryId = try values.decode(UUID.self, forKey: .entryId)
        state = try values.decode(State.self, forKey: .state)
        guard careRevision > 0,
              !occurrenceKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              SQLCalendarDay.date(from: dueLocalDate) != nil,
              let micros = SQLTimestamp.microseconds(from: try values.decode(String.self, forKey: .watermark))
        else { throw SyncWireValidationError.invalidPage }
        watermark = micros
    }

    func validate(for command: RoutineSoilCheckCompletionCommand) throws {
        guard plantId == command.envelope.plantId, ruleId == command.ruleId,
              Int(careRevision) == command.careRevision, dueLocalDate == command.dueLocalDate
        else { throw SyncWireValidationError.invalidPage }
    }
}

struct RoutineSoilCheckUndoCommand: Sendable {
    static let name = "care.check_soil.undo"
    let envelope: CommandEnvelopeDTO
    let taskId: UUID
    let entryId: UUID

    private struct Payload: Codable {
        let entryId: UUID
        enum CodingKeys: String, CodingKey { case entryId = "entry_id" }
    }

    static func make(
        plantId: UUID, taskId: UUID, entryId: UUID, operationId: UUID = UUID()
    ) throws -> Self {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Payload(entryId: entryId))
        let envelope = CommandEnvelopeDTO(
            operationId: operationId, commandName: name, plantId: plantId,
            payloadJSON: String(decoding: data, as: UTF8.self)
        )
        guard let command = Self(envelope, taskId: taskId) else {
            throw SyncWireValidationError.invalidRequest
        }
        return command
    }

    /// Keep the caller's exact envelope on retry; taskId is receipt context, never payload.
    init?(_ envelope: CommandEnvelopeDTO, taskId: UUID) {
        let data = Data(envelope.payloadJSON.utf8)
        guard envelope.commandName == Self.name, envelope.plantId != nil,
              let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(fields.keys) == ["entry_id"],
              let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else { return nil }
        self.envelope = envelope
        self.taskId = taskId
        entryId = payload.entryId
    }
}

struct RoutineSoilCheckUndoReceipt: Decodable, Sendable {
    enum State: String, Decodable, Sendable { case voided }

    let plantId: UUID
    let taskId: UUID
    let entryId: UUID
    let reversalId: UUID
    let state: State
    let watermark: Int64

    enum CodingKeys: String, CodingKey {
        case plantId = "plant_id"
        case taskId = "task_id"
        case entryId = "entry_id"
        case reversalId = "reversal_id"
        case state, watermark
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        plantId = try values.decode(UUID.self, forKey: .plantId)
        taskId = try values.decode(UUID.self, forKey: .taskId)
        entryId = try values.decode(UUID.self, forKey: .entryId)
        reversalId = try values.decode(UUID.self, forKey: .reversalId)
        state = try values.decode(State.self, forKey: .state)
        guard let micros = SQLTimestamp.microseconds(from: try values.decode(String.self, forKey: .watermark)),
              micros >= 0
        else { throw SyncWireValidationError.invalidPage }
        watermark = micros
    }

    func validate(for command: RoutineSoilCheckUndoCommand) throws {
        guard plantId == command.envelope.plantId, taskId == command.taskId,
              entryId == command.entryId
        else { throw SyncWireValidationError.invalidPage }
    }
}

struct CareRecommendationRefreshCommand: Sendable {
    static let name = "care.recommendation.refresh"
    let envelope: CommandEnvelopeDTO
    let careRevision: Int

    private struct Payload: Codable {
        let expectedCareRevision: Int

        enum CodingKeys: String, CodingKey {
            case expectedCareRevision = "expected_care_revision"
        }
    }

    static func make(plantId: UUID, careRevision: Int) throws -> Self {
        let payload = try JSONEncoder().encode(Payload(expectedCareRevision: careRevision))
        let envelope = CommandEnvelopeDTO(
            operationId: UUID(), commandName: name, plantId: plantId,
            payloadJSON: String(decoding: payload, as: UTF8.self)
        )
        guard let command = Self(envelope) else { throw SyncWireValidationError.invalidRequest }
        return command
    }

    init?(_ envelope: CommandEnvelopeDTO) {
        let data = Data(envelope.payloadJSON.utf8)
        guard envelope.commandName == Self.name, envelope.plantId != nil,
              let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              fields.count == 1,
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              (1...Int(Int32.max)).contains(payload.expectedCareRevision)
        else { return nil }
        self.envelope = envelope
        self.careRevision = payload.expectedCareRevision
    }
}

private struct CareRecommendationRefreshReceipt: Decodable {
    enum State: String, Decodable { case refreshed, paused }
    enum PauseReason: String, Decodable {
        case insufficientEvidence = "insufficient_evidence"
        case missingWateringAnchor = "missing_watering_anchor"
        case automaticCareUnavailable = "automatic_care_unavailable"
    }

    let plantId: UUID
    let careRevision: Int
    let state: State
    let reason: PauseReason?
    let watermark: String

    enum CodingKeys: String, CodingKey {
        case plantId = "plant_id"
        case careRevision = "care_revision"
        case state, reason, watermark
    }

    func validate(for command: CareRecommendationRefreshCommand) throws -> Int64 {
        guard plantId == command.envelope.plantId, careRevision == command.careRevision,
              (state == .paused) == (reason != nil),
              let micros = SQLTimestamp.microseconds(from: watermark)
        else { throw SyncWireValidationError.invalidPage }
        return micros
    }
}

struct PlantDeleteReceipt: Decodable, Sendable {
    static let commandName = "plant.delete"
    let plantId: UUID
    let deletionJobId: UUID
    let watermark: Int64

    enum CodingKeys: String, CodingKey {
        case plantId = "plant_id"
        case deletionJobId = "deletion_job_id"
        case state, watermark
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        plantId = try values.decode(UUID.self, forKey: .plantId)
        deletionJobId = try values.decode(UUID.self, forKey: .deletionJobId)
        guard try values.decode(String.self, forKey: .state) == "deleting",
              let micros = SQLTimestamp.microseconds(from: try values.decode(String.self, forKey: .watermark))
        else { throw SyncWireValidationError.invalidPage }
        watermark = micros
    }
}

enum FirstAidObservationStatus: String, CaseIterable, Codable, Sendable {
    case improved, unchanged, worse, unknown
}

struct FirstAidObservationCommand: Sendable {
    static let name = "care.first_aid.observe"
    let envelope: CommandEnvelopeDTO
    let plantId: UUID
    let controlId: UUID
    let status: FirstAidObservationStatus
    let photoId: UUID?

    init?(envelope: CommandEnvelopeDTO) {
        guard envelope.commandName == Self.name, let plantId = envelope.plantId,
              let fields = try? JSONDecoder().decode([String: String].self, from: Data(envelope.payloadJSON.utf8)),
              let controlId = fields["control_id"].flatMap(UUID.init(uuidString:)),
              let status = fields["status_code"].flatMap(FirstAidObservationStatus.init(rawValue:)) else { return nil }
        let photoId = fields["photo_id"].flatMap(UUID.init(uuidString:))
        guard fields.count == (photoId == nil ? 2 : 3) else { return nil }
        self.envelope = envelope
        self.plantId = plantId
        self.controlId = controlId
        self.status = status
        self.photoId = photoId
    }

    static func make(
        plantId: UUID, controlId: UUID, status: FirstAidObservationStatus, photoId: UUID? = nil, operationId: UUID = UUID()
    ) throws -> Self {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var fields = ["control_id": controlId.uuidString.lowercased(), "status_code": status.rawValue]
        fields["photo_id"] = photoId?.uuidString.lowercased()
        let data = try encoder.encode(fields)
        let envelope = CommandEnvelopeDTO(operationId: operationId, commandName: name, plantId: plantId,
                                          payloadJSON: String(decoding: data, as: UTF8.self))
        guard let command = Self(envelope: envelope) else { throw SyncWireValidationError.invalidRequest }
        return command
    }
}

/// Local outbox stage. Only the ready-asset observation command crosses the wire.
struct FirstAidObservationPhotoDraft: Sendable {
    static let name = "local.first_aid.observe_photo"
    let envelope: CommandEnvelopeDTO
    let plantId: UUID
    let controlId: UUID
    let status: FirstAidObservationStatus
    let uploadOperationId: UUID

    init?(envelope: CommandEnvelopeDTO) {
        guard envelope.commandName == Self.name, let plantId = envelope.plantId,
              let fields = try? JSONDecoder().decode([String: String].self, from: Data(envelope.payloadJSON.utf8)),
              fields.count == 3, let controlId = fields["control_id"].flatMap(UUID.init(uuidString:)),
              let status = fields["status_code"].flatMap(FirstAidObservationStatus.init(rawValue:)),
              let uploadId = fields["upload_operation_id"].flatMap(UUID.init(uuidString:)),
              uploadId != envelope.operationId else { return nil }
        self.envelope = envelope
        self.plantId = plantId
        self.controlId = controlId
        self.status = status
        uploadOperationId = uploadId
    }

    static func make(
        plantId: UUID, controlId: UUID, status: FirstAidObservationStatus, operationId: UUID = UUID()
    ) throws -> Self {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode([
            "control_id": controlId.uuidString.lowercased(), "status_code": status.rawValue,
            "upload_operation_id": UUID().uuidString.lowercased()
        ])
        let envelope = CommandEnvelopeDTO(operationId: operationId, commandName: name, plantId: plantId,
                                          payloadJSON: String(decoding: data, as: UTF8.self))
        guard let draft = Self(envelope: envelope) else { throw SyncWireValidationError.invalidRequest }
        return draft
    }
}

struct FirstAidObservationReceipt: Decodable, Sendable {
    let plantId: UUID
    let controlId: UUID
    let observationId: UUID
    let watermark: Int64

    enum CodingKeys: String, CodingKey {
        case plantId = "plant_id"
        case controlId = "control_id"
        case observationId = "observation_id"
        case state, watermark
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        plantId = try values.decode(UUID.self, forKey: .plantId)
        controlId = try values.decode(UUID.self, forKey: .controlId)
        observationId = try values.decode(UUID.self, forKey: .observationId)
        guard try values.decode(String.self, forKey: .state) == "completed",
              let micros = SQLTimestamp.microseconds(from: try values.decode(String.self, forKey: .watermark))
        else { throw SyncWireValidationError.invalidPage }
        watermark = micros
    }
}

private struct ManualWateringReceipt: Decodable {
    let plantId: UUID
    let entryId: UUID
    let reversalId: UUID?
    let state: String
    let watermark: String

    enum CodingKeys: String, CodingKey {
        case plantId = "plant_id"
        case entryId = "entry_id"
        case reversalId = "reversal_id"
        case state, watermark
    }

    func validate(plantId expectedPlantId: UUID?, action: ManualWateringAction) throws -> Int64 {
        guard plantId == expectedPlantId, let micros = SQLTimestamp.microseconds(from: watermark) else {
            throw SyncWireValidationError.invalidPage
        }
        switch action {
        case .record:
            guard state == "active", reversalId == nil else { throw SyncWireValidationError.invalidPage }
        case let .undo(expectedEntryId):
            guard state == "voided", entryId == expectedEntryId, reversalId != nil else {
                throw SyncWireValidationError.invalidPage
            }
        case let .correctDate(expectedEntryId, _, _):
            guard state == "active", entryId == expectedEntryId, reversalId == nil else {
                throw SyncWireValidationError.invalidPage
            }
        }
        return micros
    }
}

public struct APIErrorResponse: Codable, Sendable, Equatable, Error {
    public struct ErrorBody: Codable, Sendable, Equatable {
        public let code: String
        public let message: String
        public let retryable: Bool
    }
    public let error: ErrorBody
}

public protocol PlantsAPITransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
    func sendWithoutRedirect(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

extension PlantsAPITransport {
    public func sendWithoutRedirect(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw URLError(.unsupportedURL)
    }
}

public struct URLSessionAPITransport: PlantsAPITransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }

    public func sendWithoutRedirect(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request, delegate: AnalysisUploadRedirectDelegate())
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }
}

/// A captured operation is invalid after *any* auth-context change, including A -> B -> A.
struct SyncSessionLease: Sendable {
    let ownerId: UUID
    let generation: UInt64
    let session: NativeAuthSession?
    fileprivate let authority: SyncSessionAuthority
}

/// The short synchronous critical section also covers LocalStore's save. There is no
/// lock across an await: auth changes and disk publication have one ordering.
final class SyncSessionAuthority: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var canonical = false
    private var session: NativeAuthSession?
    private var permanentOwnerId: UUID?

    private struct AccountClaims: Decodable {
        let sub: UUID
        let isAnonymous: Bool

        enum CodingKeys: String, CodingKey {
            case sub
            case isAnonymous = "is_anonymous"
        }
    }

    /// Inspect the bearer supplied by the auth SDK, not a caller's guest/permanent guess.
    /// This is a fail-closed client gate; the server still authenticates the JWT.
    private static func permanentOwner(for session: NativeAuthSession) -> UUID? {
        let parts = session.accessToken.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty }) else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONDecoder().decode(AccountClaims.self, from: data),
              !claims.isAnonymous, claims.sub == session.userId else { return nil }
        return claims.sub
    }

    func bind(_ session: NativeAuthSession?) {
        lock.withLock {
            generation &+= 1
            canonical = true
            self.session = session
            permanentOwnerId = session.flatMap { Self.permanentOwner(for: $0) }
        }
    }

    func invalidate() {
        lock.withLock {
            generation &+= 1
            session = nil
            permanentOwnerId = nil
        }
    }

    func capture(ownerId: UUID, explicitSession: NativeAuthSession? = nil) throws -> SyncSessionLease {
        try lock.withLock {
            let captured = canonical ? session : explicitSession
            if canonical {
                guard let captured, explicitSession == nil || captured == explicitSession else {
                    throw SyncWireValidationError.invalidSession
                }
            }
            let lease = SyncSessionLease(
                ownerId: ownerId, generation: generation, session: captured, authority: self
            )
            try validateLocked(lease)
            return lease
        }
    }

    private func validateLocked(_ lease: SyncSessionLease) throws {
        try Task.checkCancellation()
        guard lease.generation == generation,
              !canonical || (session != nil && session == lease.session) else {
            throw SyncWireValidationError.invalidSession
        }
        if let captured = lease.session {
            guard captured.userId == lease.ownerId,
                  !captured.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  captured.expiresAt > Date() else { throw SyncWireValidationError.invalidSession }
        }
    }

    /// Explicit-session capture is a transport compatibility path, not bound proof.
    /// Check on this authority under the very lock that covers the disk action.
    func withBoundValid<T>(_ lease: SyncSessionLease, _ body: () throws -> T) throws -> T {
        try lock.withLock {
            try validateLocked(lease)
            guard canonical, session != nil, lease.authority === self else {
                throw SyncWireValidationError.invalidSession
            }
            return try body()
        }
    }

    /// Permanent-account proof belongs to this binding and generation, including ABA.
    /// Keep the proof check and the protected disk action in the same critical section.
    func withPermanentBoundValid<T>(_ lease: SyncSessionLease, _ body: () throws -> T) throws -> T {
        try lock.withLock {
            try validateLocked(lease)
            guard canonical, session != nil, lease.authority === self,
                  permanentOwnerId == lease.ownerId else {
                throw SyncWireValidationError.invalidSession
            }
            return try body()
        }
    }

    func withValid<T>(_ lease: SyncSessionLease, _ body: () throws -> T) throws -> T {
        try lock.withLock {
            try validateLocked(lease)
            return try body()
        }
    }
}

/// Only a typed canonical receipt can authorize the durable create acknowledgement.
enum OutboxCommandResult: Sendable {
    case generic
    case catalogueCreate(PlantCreateReceiptDTO)
    case wateringDateCorrection(watermark: Int64)
    case careUndone(reversalId: UUID, watermark: Int64)
    case firstAidRecorded(FirstAidRecordReceipt)
    case firstAidObserved(FirstAidObservationReceipt)
    case plantEdited(PlantEditReceipt)
    case careRecommendationRefreshed(watermark: Int64)
    case basicCareEnabled(BasicCareEnableReceipt)
    case plantDeleting(PlantDeleteReceipt)
}

public actor PlantsAPIClient {
    public let baseURL: URL
    private let transport: any PlantsAPITransport
    private var installationCredential: String?
    private var clientLocale: String
    private var bearerToken: String?
    nonisolated let syncAuthority = SyncSessionAuthority()

    public init(
        baseURL: URL = URL(string: "https://api.narat.app/functions/v1/plants-api")!,
        transport: any PlantsAPITransport = URLSessionAPITransport(),
        installationCredential: String? = nil,
        clientLocale: String = "pl",
        bearerToken: String? = nil
    ) {
        self.baseURL = baseURL
        self.transport = transport
        self.installationCredential = installationCredential
        self.clientLocale = clientLocale
        self.bearerToken = bearerToken
    }

    public enum LocaleError: Error, Sendable, Equatable {
        case unsupportedLocale
    }

    /// Header metadata only: retain credentials, bound authority and in-flight operations.
    public func updateClientLocale(_ locale: String) throws {
        try Task.checkCancellation()
        guard locale == "en" || locale == "pl" else { throw LocaleError.unsupportedLocale }
        clientLocale = locale
    }

    public func updateContext(
        installationCredential: String?,
        clientLocale: String,
        bearerToken: String?
    ) {
        syncAuthority.invalidate()
        self.installationCredential = installationCredential
        self.clientLocale = clientLocale
        self.bearerToken = bearerToken
    }

    /// Bind on sign-in/refresh, and bind nil on sign-out. Once bound, this client
    /// never falls back to legacy sync, even while signed out. UI wiring is separate.
    public func bindSyncSession(_ session: NativeAuthSession?) {
        syncAuthority.bind(session)
        bearerToken = session?.accessToken
    }

    func fetchProfileSettings(context: SyncSessionLease) async throws -> ProfileSettingsDTO {
        try syncAuthority.withBoundValid(context) {}
        guard let locale = SupportedLocale(rawValue: clientLocale) else {
            throw LocaleError.unsupportedLocale
        }
        let request = try buildRequest(path: "me", method: "GET")
        let response = try await analysisRequest(
            request, locale: locale, context: context,
            status: [200], forbidRedirects: true
        ) as ProfileSettingsResponse
        return try syncAuthority.withBoundValid(context) { response.profile }
    }

    func updateProfileReminderHour(
        _ command: ProfileReminderHourCommand, context: SyncSessionLease
    ) async throws -> ProfileReminderHourReceipt {
        try syncAuthority.withPermanentBoundValid(context) {}
        guard let locale = SupportedLocale(rawValue: clientLocale) else {
            throw LocaleError.unsupportedLocale
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let request = try buildRequest(
            path: "commands", method: "POST", operationId: command.envelope.operationId,
            body: encoder.encode(command.envelope)
        )
        let receipt = try await analysisRequest(
            request, locale: locale, context: context,
            status: [200], forbidRedirects: true
        ) as ProfileReminderHourReceipt
        return try syncAuthority.withPermanentBoundValid(context) {
            guard receipt.profile.reminderHourLocal == command.reminderHourLocal else {
                throw SyncWireValidationError.invalidPage
            }
            return receipt
        }
    }

    func captureSyncContext(ownerId: UUID) throws -> SyncSessionLease {
        try syncAuthority.capture(ownerId: ownerId)
    }

    func validateSyncContext(_ context: SyncSessionLease) throws {
        try syncAuthority.withValid(context) {}
    }

    /// Authenticated engine path; errors never trigger a legacy retry.
    func fetchSyncPage(
        context: SyncSessionLease, since: String?, until: String?,
        cursor: SyncWireCursorDTO?, limit: Int
    ) async throws -> SyncWireResult {
        try validateSyncContext(context)
        guard let session = context.session else { throw SyncWireValidationError.invalidSession }
        let result = try await fetchSyncWirePage(
            session: session, since: since, until: until, cursor: cursor, limit: limit
        )
        try validateSyncContext(context)
        return result
    }

    /// Fixture-only until durable acknowledgement is implemented by the next package.
    func sendOutboxCommand(
        _ command: RoutineSoilCheckCompletionCommand, context: SyncSessionLease
    ) async throws -> RoutineSoilCheckCompletionReceipt {
        let session = try syncAuthority.withBoundValid(context) {
            guard let session = context.session else { throw SyncWireValidationError.invalidSession }
            return session
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let body = try encoder.encode(command.envelope)
        var request = try buildRequest(
            path: "commands", method: "POST", operationId: command.envelope.operationId, body: body
        )
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("en", forHTTPHeaderField: "X-Client-Locale")
        request.setValue(nil, forHTTPHeaderField: "X-Installation-Credential")
        let receipt = try await execute(request, as: RoutineSoilCheckCompletionReceipt.self, expectedStatus: 200)
        return try syncAuthority.withBoundValid(context) {
            try receipt.validate(for: command)
            return receipt
        }
    }

    /// Dedicated transport only; durable undo acknowledgement belongs to a later package.
    func sendOutboxCommand(
        _ command: RoutineSoilCheckUndoCommand, context: SyncSessionLease
    ) async throws -> RoutineSoilCheckUndoReceipt {
        let session = try syncAuthority.withBoundValid(context) {
            guard let session = context.session else { throw SyncWireValidationError.invalidSession }
            return session
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let body = try encoder.encode(command.envelope)
        var request = try buildRequest(
            path: "commands", method: "POST", operationId: command.envelope.operationId, body: body
        )
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        request.setValue("en", forHTTPHeaderField: "X-Client-Locale")
        request.setValue(nil, forHTTPHeaderField: "X-Installation-Credential")
        let receipt = try await execute(request, as: RoutineSoilCheckUndoReceipt.self, expectedStatus: 200)
        return try syncAuthority.withBoundValid(context) {
            try receipt.validate(for: command)
            return receipt
        }
    }

    func sendOutboxCommand(
        _ envelope: CommandEnvelopeDTO, context: SyncSessionLease
    ) async throws -> OutboxCommandResult {
        try validateSyncContext(context)
        guard envelope.commandName != FirstAidObservationPhotoDraft.name,
              envelope.commandName != RoutineSoilCheckCompletionCommand.name,
              envelope.commandName != RoutineSoilCheckUndoCommand.name,
              envelope.commandName != "profile.update"
        else { throw SyncWireValidationError.invalidRequest }
        let catalogueCreate = context.session != nil && envelope.commandName == "plant.create"
        let plantDelete = envelope.commandName == PlantDeleteReceipt.commandName
        let plantEdit = envelope.commandName == PlantEditCommand.name
        let recommendationRefresh = CareRecommendationRefreshCommand(envelope)
        let basicCareEnable = envelope.commandName == BasicCareEnableReceipt.commandName
        if basicCareEnable {
            try syncAuthority.withBoundValid(context) {}
            guard envelope.plantId != nil, envelope.payloadJSON == "{}"
            else { throw SyncWireValidationError.invalidRequest }
        }
        if envelope.commandName == CareRecommendationRefreshCommand.name {
            try syncAuthority.withBoundValid(context) {}
            guard recommendationRefresh != nil else { throw SyncWireValidationError.invalidRequest }
        }
        let manualWatering = context.session == nil ? nil : ManualWateringAction(envelope: envelope)
        let firstAid = envelope.commandName == FirstAidRecordCommand.name
        let observation = FirstAidObservationCommand(envelope: envelope)
        if plantDelete {
            try syncAuthority.withBoundValid(context) {}
            guard envelope.plantId != nil, envelope.payloadJSON == "{}"
            else { throw SyncWireValidationError.invalidRequest }
        }
        if plantEdit {
            try syncAuthority.withBoundValid(context) {}
            guard PlantEditCommand(envelope) != nil else { throw SyncWireValidationError.invalidRequest }
        }
        if firstAid {
            try syncAuthority.withBoundValid(context) {}
            guard FirstAidRecordCommand(envelope: envelope) != nil else { throw SyncWireValidationError.invalidRequest }
        }
        if envelope.commandName == FirstAidObservationCommand.name {
            try syncAuthority.withBoundValid(context) {}
            guard observation != nil else { throw SyncWireValidationError.invalidRequest }
        }
        if envelope.commandName == ManualWateringAction.correctionCommand, manualWatering == nil {
            throw SyncWireValidationError.invalidRequest
        }
        if catalogueCreate { try CatalogueCreateWire.validate(envelope) }
        let encoder = JSONEncoder()
        if catalogueCreate || plantDelete || plantEdit || recommendationRefresh != nil || basicCareEnable
            || manualWatering != nil || firstAid || observation != nil {
            encoder.outputFormatting = [.sortedKeys]
        }
        encoder.dateEncodingStrategy = .iso8601
        let body = try encoder.encode(envelope)
        var request = try buildRequest(
            path: "commands", method: "POST", operationId: envelope.operationId, body: body
        )
        if let session = context.session {
            request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        }
        if manualWatering != nil || firstAid || observation != nil || recommendationRefresh != nil || basicCareEnable {
            request.setValue("en", forHTTPHeaderField: "X-Client-Locale")
            request.setValue(nil, forHTTPHeaderField: "X-Installation-Credential")
        }
        if plantDelete || plantEdit {
            request.setValue(nil, forHTTPHeaderField: "X-Installation-Credential")
        }
        // Build and dispatch with the captured token in the same actor turn.
        let result: OutboxCommandResult
        if catalogueCreate {
            let receipt = try await execute(request, as: PlantCreateReceiptDTO.self, expectedStatus: 200)
            try CatalogueCreateWire.validate(receipt, for: envelope)
            result = .catalogueCreate(receipt)
        } else if plantDelete {
            let receipt = try await execute(request, as: PlantDeleteReceipt.self, expectedStatus: 200)
            guard receipt.plantId == envelope.plantId else { throw SyncWireValidationError.invalidPage }
            result = .plantDeleting(receipt)
        } else if plantEdit {
            let receipt = try await execute(request, as: PlantEditReceipt.self, expectedStatus: 200)
            guard receipt.plantId == envelope.plantId else { throw SyncWireValidationError.invalidPage }
            result = .plantEdited(receipt)
        } else if let recommendationRefresh {
            let receipt = try await execute(request, as: CareRecommendationRefreshReceipt.self, expectedStatus: 200)
            result = .careRecommendationRefreshed(watermark: try receipt.validate(for: recommendationRefresh))
        } else if basicCareEnable {
            let receipt = try await execute(request, as: BasicCareEnableReceipt.self, expectedStatus: 200)
            guard receipt.plantId == envelope.plantId, receipt.enabled,
                  SQLTimestamp.microseconds(from: receipt.enabledAt) != nil
            else { throw SyncWireValidationError.invalidPage }
            result = .basicCareEnabled(receipt)
        } else if firstAid {
            let receipt = try await execute(request, as: FirstAidRecordReceipt.self, expectedStatus: 200)
            guard receipt.plantId == envelope.plantId else { throw SyncWireValidationError.invalidPage }
            result = .firstAidRecorded(receipt)
        } else if let observation {
            let receipt = try await execute(request, as: FirstAidObservationReceipt.self, expectedStatus: 200)
            guard receipt.plantId == observation.plantId, receipt.controlId == observation.controlId
            else { throw SyncWireValidationError.invalidPage }
            result = .firstAidObserved(receipt)
        } else if let manualWatering {
            let receipt = try await execute(request, as: ManualWateringReceipt.self, expectedStatus: 200)
            let watermark = try receipt.validate(plantId: envelope.plantId, action: manualWatering)
            switch manualWatering {
            case .record: result = .generic
            case .correctDate: result = .wateringDateCorrection(watermark: watermark)
            case .undo:
                guard let reversalId = receipt.reversalId else { throw SyncWireValidationError.invalidPage }
                result = .careUndone(reversalId: reversalId, watermark: watermark)
            }
        } else {
            _ = try await execute(request, as: CommandResponseDTO.self)
            result = .generic
        }
        try validateSyncContext(context)
        return result
    }

    /// Read-only wire boundary; callers must supply a lease from the bound session.
    /// Guest/permanent metadata is explicit because NativeAuthSession has no anonymous flag.
    func fetchAnalysisAccess(
        context: SyncSessionLease, expectedGuest: Bool, guestCredential: String? = nil
    ) async throws -> AnalysisAccessWireDTO {
        let session = try syncAuthority.withBoundValid(context) {
            guard let session = context.session else { throw SyncWireValidationError.invalidSession }
            return session
        }
        let credential = expectedGuest ? guestCredential ?? installationCredential : nil
        if expectedGuest {
            guard let credential,
                  !credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AnalysisAccessWireError.missingInstallationCredential
            }
        }
        var request = try buildRequest(path: "analysis/access", method: "GET")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(credential, forHTTPHeaderField: "X-Installation-Credential")
        let snapshot = try await execute(
            request, as: AnalysisAccessWireDTO.self, expectedStatus: 200, forbidRedirects: true
        )
        // Validate the captured generation, including cancellation and A -> B -> A,
        // before exposing a snapshot. Never consult a replacement bearer or owner.
        return try syncAuthority.withBoundValid(context) {
            guard snapshot.ownerId == context.ownerId, snapshot.isGuest == expectedGuest else {
                throw AnalysisAccessWireError.identityMismatch
            }
            return snapshot
        }
    }

    public func buildRequest(
        path: String,
        method: String,
        queryItems: [URLQueryItem] = [],
        operationId: UUID? = nil,
        body: Data? = nil
    ) throws -> URLRequest {
        var components = URLComponents(
            url: baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))),
            resolvingAgainstBaseURL: false
        )
        if !queryItems.isEmpty {
            components?.queryItems = queryItems
        }
        guard let url = components?.url else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(clientLocale, forHTTPHeaderField: "X-Client-Locale")

        if let credential = installationCredential, !credential.isEmpty {
            request.setValue(credential, forHTTPHeaderField: "X-Installation-Credential")
        }
        if let opId = operationId {
            request.setValue(opId.uuidString.lowercased(), forHTTPHeaderField: "X-Operation-Id")
        }
        if let token = bearerToken, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = body
        return request
    }

    public func sendCommand(_ envelope: CommandEnvelopeDTO) async throws -> CommandResponseDTO {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let body = try encoder.encode(envelope)
        let request = try buildRequest(
            path: "commands",
            method: "POST",
            operationId: envelope.operationId,
            body: body
        )
        return try await execute(request, as: CommandResponseDTO.self)
    }

    /// Returns only the SQL receipt. Outbox acknowledgement belongs to the sync layer.
    public func sendCatalogueCreate(_ envelope: CommandEnvelopeDTO) async throws -> PlantCreateReceiptDTO {
        try CatalogueCreateWire.validate(envelope)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let body = try encoder.encode(envelope)
        let request = try buildRequest(
            path: "commands",
            method: "POST",
            operationId: envelope.operationId,
            body: body
        )
        let receipt = try await execute(request, as: PlantCreateReceiptDTO.self)
        try CatalogueCreateWire.validate(receipt, for: envelope)
        return receipt
    }

    /// Explicit legacy DTO/Date compatibility API. Bound SyncEngine uses the overload above.
    public func fetchSyncPage(
        since: Date?,
        until: Date?,
        cursor: SyncCursorDTO?,
        limit: Int = 200
    ) async throws -> SyncPageDTO {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var query: [URLQueryItem] = [
            URLQueryItem(name: "limit", value: String(limit))
        ]
        if let since {
            query.append(URLQueryItem(name: "since", value: formatter.string(from: since)))
        }
        if let until {
            query.append(URLQueryItem(name: "until", value: formatter.string(from: until)))
        }
        if let cursor {
            query.append(URLQueryItem(name: "cursor_updated_at", value: formatter.string(from: cursor.updatedAt)))
            query.append(URLQueryItem(name: "cursor_entity_type", value: cursor.entityType))
            query.append(URLQueryItem(name: "cursor_id", value: cursor.id.uuidString.lowercased()))
        }

        let request = try buildRequest(path: "sync", method: "GET", queryItems: query)
        return try await execute(request, as: SyncPageDTO.self)
    }

    private func execute<T: Decodable>(
        _ request: URLRequest, as type: T.Type, expectedStatus: Int? = nil, forbidRedirects: Bool = false
    ) async throws -> T {
        let (data, http) = try await (forbidRedirects ? transport.sendWithoutRedirect(request) : transport.send(request))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard (200..<300).contains(http.statusCode) else {
            if let apiErr = try? decoder.decode(APIErrorResponse.self, from: data) {
                throw apiErr
            }
            throw URLError(.badServerResponse)
        }
        if let expectedStatus, http.statusCode != expectedStatus {
            throw URLError(.badServerResponse)
        }
        return try decoder.decode(T.self, from: data)
    }

    func searchPublishedCatalogue(
        query: String, locale: SupportedLocale, limit: Int, offset: Int
    ) async throws -> PublishedCataloguePage {
        let request = try publicCatalogueRequest(
            path: "catalogue", locale: locale, query: [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "limit", value: String(limit)),
                URLQueryItem(name: "offset", value: String(offset))
            ]
        )
        let page = try await execute(request, as: PublishedCataloguePage.self, expectedStatus: 200)
        guard page.locale == locale.rawValue, page.limit == limit, page.offset == offset,
              limit > 0, offset >= 0, page.total >= 0,
              page.items.count == min(limit, max(0, page.total - offset)),
              page.releaseVersion != nil || page.total == 0,
              Set(page.items.map(\.id)).count == page.items.count,
              page.items.allSatisfy(\.hasValidIdentity) else {
            throw URLError(.cannotParseResponse)
        }
        return page
    }

    func fetchPublishedSpecies(slug: String, locale: SupportedLocale) async throws -> PublishedSpeciesCard {
        guard PublishedSpeciesCard.isValidSlug(slug) else { throw URLError(.badURL) }
        let card = try await fetchPublishedSpecies(identifier: slug, locale: locale)
        guard card.id == slug else { throw URLError(.cannotParseResponse) }
        return card
    }

    func fetchPublishedSpecies(taxonId: UUID, locale: SupportedLocale) async throws -> PublishedSpeciesCard {
        let card = try await fetchPublishedSpecies(identifier: taxonId.uuidString.lowercased(), locale: locale)
        guard card.taxonId == taxonId else { throw URLError(.cannotParseResponse) }
        return card
    }

    private func fetchPublishedSpecies(identifier: String, locale: SupportedLocale) async throws -> PublishedSpeciesCard {
        let request = try publicCatalogueRequest(path: "catalogue/\(identifier)", locale: locale)
        let card = try await execute(request, as: PublishedSpeciesCard.self, expectedStatus: 200)
        guard card.hasValidIdentity else { throw URLError(.cannotParseResponse) }
        return card
    }

    private func publicCatalogueRequest(
        path: String, locale: SupportedLocale, query: [URLQueryItem] = []
    ) throws -> URLRequest {
        var request = try buildRequest(path: path, method: "GET", queryItems: query)
        request.setValue(locale.rawValue, forHTTPHeaderField: "X-Client-Locale")
        request.setValue(nil, forHTTPHeaderField: "Authorization")
        request.setValue(nil, forHTTPHeaderField: "X-Installation-Credential")
        return request
    }
}

struct PublishedCataloguePage: Decodable, Sendable {
    let releaseVersion: String?
    let kbReleaseId: UUID?
    let locale: String
    let total: Int
    let limit: Int
    let offset: Int
    let items: [PublishedSpeciesCard]

    enum CodingKeys: String, CodingKey {
        case releaseVersion = "release_version"
        case kbReleaseId = "kb_release_id"
        case locale, total, limit, offset, items
    }
}

struct PublishedSpeciesCard: Decodable, Sendable, Identifiable {
    struct Description: Decodable, Sendable {
        let text: String
        let language: String?
        let attribution: String?
        let sourceURL: URL?

        enum CodingKeys: String, CodingKey {
            case text, language, attribution
            case sourceURL = "source_url"
        }
    }

    struct Photo: Decodable, Sendable {
        let downloadURL: URL?
        let sourcePage: URL?
        let attribution: String?
        let author: String?
        let license: String?

        enum CodingKeys: String, CodingKey {
            case downloadURL = "download_url"
            case sourcePage = "source_page"
            case attribution, author, license
        }
    }

    let id: String
    let taxonId: UUID
    let displayName: String
    let scientificName: String
    let description: Description?
    let heroImage: Photo?
    let careProfileAvailable: Bool

    enum CodingKeys: String, CodingKey {
        case id = "plant_id"
        case taxonId = "taxon_id"
        case displayName = "display_name"
        case scientificName = "scientific_name"
        case description
        case heroImage = "hero_image"
        case careProfileAvailable = "care_profile_available"
    }

    static func isValidSlug(_ value: String) -> Bool {
        value.range(of: #"^[a-z][a-z0-9_]*\z"#, options: .regularExpression) != nil
    }

    var hasValidIdentity: Bool {
        Self.isValidSlug(id) && !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !scientificName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public enum CatalogueCreateValidationError: Error, Sendable {
    case invalidCommand
    case invalidPayload
}

// Validate the catalogue subset without rewriting the caller's persisted payload.
enum CatalogueCreateWire {
    private static let conditionValues: [String: Set<String>] = [
        "light_level": ["low", "medium", "bright_indirect", "direct_sun", "unknown"],
        "light_code": ["low", "medium", "bright_indirect", "direct_sun", "unknown"],
        "light_source": ["manual", "unknown"],
        "watering_habit": ["several_weekly", "weekly", "less_often", "frequent", "moderate", "sparse", "unknown"],
        "watering_code": ["several_weekly", "weekly", "less_often", "frequent", "moderate", "sparse", "unknown"],
        "last_watered": ["yes", "no", "within_7_days", "over_7_days", "unknown"],
        "drainage_code": ["yes", "no", "within_7_days", "over_7_days", "unknown"],
        "pot_type": ["terracotta", "plastic", "glazed_ceramic", "standard_drainage", "other", "unknown"]
    ]

    static func validate(_ envelope: CommandEnvelopeDTO) throws {
        guard envelope.commandName == "plant.create", envelope.plantId == nil else {
            throw CatalogueCreateValidationError.invalidCommand
        }
        guard let data = envelope.payloadJSON.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              payload["creation_source"] as? String == "catalogue" else {
            throw CatalogueCreateValidationError.invalidPayload
        }
        if payload["diagnosis_job_id"] != nil {
            guard Set(payload.keys).isSubset(of: ["creation_source", "add_method", "creation_intent",
                                                 "diagnosis_job_id", "plant_id", "personal_name"]),
                  payload["add_method"] as? String == "scan",
                  payload["creation_intent"] as? String == "problem",
                  uuid(payload["diagnosis_job_id"]) != nil,
                  let slug = payload["plant_id"] as? String, !slug.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  payload["personal_name"] == nil || payload["personal_name"] is String else {
                throw CatalogueCreateValidationError.invalidPayload
            }
            return
        }
        if payload["add_method"] as? String == "scan" {
            guard Set(payload.keys).isSubset(of: ["creation_source", "add_method", "creation_intent",
                                                 "identification_job_id", "taxon_id", "origin_flow_id", "personal_name"]),
                  payload["creation_intent"] as? String == "care",
                  uuid(payload["identification_job_id"]) != nil, uuid(payload["taxon_id"]) != nil,
                  payload["origin_flow_id"] == nil || uuid(payload["origin_flow_id"]) != nil,
                  payload["personal_name"] == nil || payload["personal_name"] is String else {
                throw CatalogueCreateValidationError.invalidPayload
            }
            return
        }
        guard fields(payload, kind: "payload") else { throw CatalogueCreateValidationError.invalidPayload }
        let overrides = payload["overrides"] as? [String: Any] ?? [:]
        guard [payload["plant_id"], payload["taxon_id"], overrides["plant_id"], overrides["taxon_id"]]
            .contains(where: { ($0 as? String)?.isEmpty == false }) else {
            throw CatalogueCreateValidationError.invalidPayload
        }
    }

    static func identificationTaxon(_ envelope: CommandEnvelopeDTO) -> UUID? {
        guard let payload = try? JSONSerialization.jsonObject(with: Data(envelope.payloadJSON.utf8)) as? [String: Any],
              payload["add_method"] as? String == "scan" else { return nil }
        return uuid(payload["taxon_id"])
    }

    static func diagnosisSpecies(_ envelope: CommandEnvelopeDTO) -> String? {
        guard let payload = try? JSONSerialization.jsonObject(with: Data(envelope.payloadJSON.utf8)) as? [String: Any],
              uuid(payload["diagnosis_job_id"]) != nil else { return nil }
        return payload["plant_id"] as? String
    }

    static func validate(_ receipt: PlantCreateReceiptDTO, for envelope: CommandEnvelopeDTO) throws {
        if (identificationTaxon(envelope) != nil || diagnosisSpecies(envelope) != nil), receipt.photoId == nil {
            throw AnalysisHTTPError.invalidResponse
        }
    }

    private static func uuid(_ value: Any?) -> UUID? { (value as? String).flatMap(UUID.init(uuidString:)) }

    private static func fields(_ object: [String: Any], kind: String) -> Bool {
        for (key, value) in object {
            let isNull = value is NSNull
            if kind != "payload", let allowed = conditionValues[key] {
                guard isNull || (value as? String).map(allowed.contains) == true else { return false }
            } else if kind != "payload", key == "light_confirmed" {
                // NSNumber bridges numeric 0/1 to Bool; accept only JSON booleans.
                guard isNull || (value as? NSNumber).map({ String(cString: $0.objCType) == "c" }) == true else {
                    return false
                }
            } else if kind != "conditions", ["plant_id", "personal_name", "display_name"].contains(key) {
                guard isNull || (value as? String).map({
                    key != "plant_id" || !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }) == true else { return false }
            } else if kind != "conditions", key == "taxon_id" {
                guard isNull || (value as? String).flatMap(UUID.init(uuidString:)) != nil else { return false }
            } else if kind == "payload", key == "origin_flow_id" {
                guard isNull || (value as? String).flatMap(UUID.init(uuidString:)) != nil else { return false }
            } else if kind == "payload", key == "photo_id" {
                guard isNull else { return false }
            } else if kind == "payload", ["creation_source", "add_method"].contains(key) {
                guard value as? String == "catalogue" else { return false }
            } else if kind == "payload", key == "creation_intent" {
                guard let intent = value as? String, ["care", "problem"].contains(intent) else { return false }
            } else if kind == "payload", ["conditions", "overrides"].contains(key) {
                guard let nested = value as? [String: Any], fields(nested, kind: key) else { return false }
            } else {
                return false
            }
        }
        return true
    }
}

// MARK: - Canonical SQL transport, separate from the legacy engine API

extension PlantsAPIClient {
    /// The caller supplies one authenticated session for both ownership and Authorization.
    /// This does not apply changes or advance any persisted checkpoint.
    public func fetchSyncWirePage(
        session: NativeAuthSession,
        since: String? = nil,
        until: String? = nil,
        cursor: SyncWireCursorDTO? = nil,
        limit: Int = 200
    ) async throws -> SyncWireResult {
        let context = try syncAuthority.capture(ownerId: session.userId, explicitSession: session)
        try SyncWireRules.validateRequest(since: since, until: until, cursor: cursor, limit: limit)
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let since { query.append(URLQueryItem(name: "since", value: since)) }
        if let until { query.append(URLQueryItem(name: "until", value: until)) }
        if let cursor {
            query.append(URLQueryItem(name: "cursor_updated_at", value: cursor.updatedAt))
            query.append(URLQueryItem(name: "cursor_entity_type", value: cursor.entityType))
            query.append(URLQueryItem(name: "cursor_id", value: cursor.id.uuidString.lowercased()))
        }
        var request = try buildRequest(path: "sync", method: "GET", queryItems: query)
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        // A literal '+' must not be interpreted as a form-encoded space by a query parser.
        if let url = request.url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
            request.url = components.url
        }
        let page = try await execute(request, as: SyncWirePageDTO.self)
        try validateSyncContext(context)
        try page.validate(since: since, requestedUntil: until, cursor: cursor, limit: limit)
        return SyncWireResult(ownerId: session.userId, page: page)
    }
}

private final class AnalysisUploadRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

extension PlantsAPIClient {
    private enum UploadScope {
        case analysis
        case firstAid(plantId: UUID, controlId: UUID)

        var mediaPath: String {
            switch self {
            case .analysis: "media"
            case .firstAid: "media/first-aid"
            }
        }
    }

    func issueAnalysisUpload(
        jpeg: Data, operationId: UUID, locale: SupportedLocale, context: SyncSessionLease, guestCredential: String? = nil
    ) async throws -> AnalysisUploadTicket {
        try await issuePhotoUpload(jpeg: jpeg, operationId: operationId, scope: .analysis,
                                   locale: locale, context: context, guestCredential: guestCredential)
    }

    func issueFirstAidPhotoUpload(
        jpeg: Data, draft: FirstAidObservationPhotoDraft, context: SyncSessionLease
    ) async throws -> AnalysisUploadTicket {
        try await issuePhotoUpload(jpeg: jpeg, operationId: draft.uploadOperationId,
                                   scope: .firstAid(plantId: draft.plantId, controlId: draft.controlId),
                                   locale: .en, context: context)
    }

    private func issuePhotoUpload(
        jpeg: Data, operationId: UUID, scope: UploadScope, locale: SupportedLocale,
        context: SyncSessionLease, guestCredential: String? = nil
    ) async throws -> AnalysisUploadTicket {
        guard !jpeg.isEmpty, jpeg.count <= AnalysisPhotoInput.maxCloudBytes else {
            throw AnalysisHTTPError.invalidUpload
        }
        let digest = SHA256.hash(data: jpeg).map { String(format: "%02x", $0) }.joined()
        var fields: [String: Any] = [
            "operation_id": operationId.uuidString.lowercased(), "mime_type": "image/jpeg",
            "byte_size": jpeg.count, "content_sha256": digest
        ]
        let privateUpload: Bool
        switch scope {
        case .analysis: privateUpload = false
        case let .firstAid(plantId, controlId):
            privateUpload = true
            fields["plant_id"] = plantId.uuidString.lowercased()
            fields["control_id"] = controlId.uuidString.lowercased()
        }
        let body = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        let request = try buildRequest(path: scope.mediaPath + "/upload-ticket", method: "POST", body: body)
        let ticket: AnalysisUploadTicket = try await analysisRequest(
            request, locale: locale, context: context, status: [200], installation: guestCredential,
            forbidRedirects: privateUpload
        )
        guard (0...60).contains(ticket.expiresInSeconds), ticket.maxByteSize >= jpeg.count,
              !ticket.storageBucket.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !ticket.storagePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              isUploadURL(ticket.signedUploadURL, photoAssetId: ticket.photoAssetId, mediaPath: scope.mediaPath) else {
            throw AnalysisHTTPError.invalidUpload
        }
        return ticket
    }

    func uploadAnalysisJPEG(
        _ jpeg: Data, ticket: AnalysisUploadTicket, locale: SupportedLocale,
        context: SyncSessionLease, guestCredential: String? = nil
    ) async throws {
        try await uploadPhotoJPEG(jpeg, ticket: ticket, mediaPath: "media", locale: locale,
                                  context: context, guestCredential: guestCredential)
    }

    func uploadFirstAidJPEG(_ jpeg: Data, ticket: AnalysisUploadTicket, context: SyncSessionLease) async throws {
        try await uploadPhotoJPEG(jpeg, ticket: ticket, mediaPath: "media/first-aid", locale: .en, context: context)
    }

    private func uploadPhotoJPEG(
        _ jpeg: Data, ticket: AnalysisUploadTicket, mediaPath: String, locale: SupportedLocale,
        context: SyncSessionLease, guestCredential: String? = nil
    ) async throws {
        guard !jpeg.isEmpty, jpeg.count <= min(ticket.maxByteSize, AnalysisPhotoInput.maxCloudBytes),
              isUploadURL(ticket.signedUploadURL, photoAssetId: ticket.photoAssetId, mediaPath: mediaPath) else {
            throw AnalysisHTTPError.invalidUpload
        }
        var request = URLRequest(url: ticket.signedUploadURL)
        request.httpMethod = "PUT"
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        request.httpBody = jpeg
        let photo: AnalysisUploadedPhoto = try await analysisRequest(
            request, locale: locale, context: context, status: [200], installation: guestCredential, forbidRedirects: true
        )
        try validateUploadedPhoto(photo, id: ticket.photoAssetId)
    }

    func confirmAnalysisPhoto(
        id: UUID, locale: SupportedLocale, context: SyncSessionLease, guestCredential: String? = nil
    ) async throws {
        try await confirmPhotoUpload(id: id, mediaPath: "media", locale: locale, context: context,
                                     guestCredential: guestCredential)
    }

    func confirmFirstAidPhoto(id: UUID, context: SyncSessionLease) async throws {
        try await confirmPhotoUpload(id: id, mediaPath: "media/first-aid", locale: .en,
                                     context: context, forbidRedirects: true)
    }

    private func confirmPhotoUpload(
        id: UUID, mediaPath: String, locale: SupportedLocale, context: SyncSessionLease,
        guestCredential: String? = nil, forbidRedirects: Bool = false
    ) async throws {
        let body = try JSONEncoder().encode(["photo_asset_id": id.uuidString.lowercased()])
        let request = try buildRequest(path: mediaPath + "/complete", method: "POST", body: body)
        let photo: AnalysisUploadedPhoto = try await analysisRequest(
            request, locale: locale, context: context, status: [200], installation: guestCredential,
            forbidRedirects: forbidRedirects
        )
        try validateUploadedPhoto(photo, id: id)
    }

    func createAnalysisJob(
        operationId: UUID, mode: AnalysisMode, photoAssetId: UUID,
        flowId: UUID? = nil, targetPlantId: UUID? = nil,
        initialContext: InitialDiagnosisContext? = nil,
        locale: SupportedLocale, context: SyncSessionLease, guestCredential: String? = nil
    ) async throws -> AnalysisJobWire {
        guard mode == .diagnosis || mode == .identification,
              targetPlantId == nil || (mode == .diagnosis && guestCredential == nil),
              initialContext == nil || (mode == .diagnosis && targetPlantId == nil),
              guestCredential == nil || mode != .diagnosis || initialContext != nil else {
            throw AnalysisHTTPError.invalidResponse
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        struct Body: Encodable {
            let operation_id: String
            let mode: AnalysisMode
            let photo_asset_id: String
            let flow_id: String?
            let target_plant_id: String?
            let initial_context: InitialDiagnosisContext?
        }
        let body = try encoder.encode(Body(
            operation_id: operationId.uuidString.lowercased(), mode: mode,
            photo_asset_id: photoAssetId.uuidString.lowercased(),
            flow_id: flowId?.uuidString.lowercased(), target_plant_id: targetPlantId?.uuidString.lowercased(),
            initial_context: initialContext
        ))
        let request = try buildRequest(path: "analysis/jobs", method: "POST", body: body)
        let job: AnalysisJobWire = try await analysisRequest(
            request, locale: locale, context: context, status: [200, 202], installation: guestCredential
        )
        try job.validate(mode: mode, targetPlantId: targetPlantId, photoAssetId: targetPlantId == nil ? nil : photoAssetId)
        return job
    }

    func fetchAnalysisJob(
        id: UUID, mode: AnalysisMode, targetPlantId: UUID? = nil, photoAssetId: UUID? = nil,
        locale: SupportedLocale, context: SyncSessionLease, guestCredential: String? = nil
    ) async throws -> AnalysisJobWire {
        guard mode == .diagnosis || mode == .identification,
              (targetPlantId == nil) == (photoAssetId == nil),
              targetPlantId == nil || (mode == .diagnosis && guestCredential == nil) else {
            throw AnalysisHTTPError.invalidResponse
        }
        let request = try buildRequest(path: "analysis/jobs/\(id.uuidString.lowercased())", method: "GET")
        let job: AnalysisJobWire = try await analysisRequest(
            request, locale: locale, context: context, status: [200], installation: guestCredential
        )
        try job.validate(mode: mode, jobId: id, targetPlantId: targetPlantId, photoAssetId: photoAssetId)
        return job
    }

    func registerPhotoInstallation(credential: String, context: SyncSessionLease) async throws -> UUID {
        let reply: PhotoInstallationRegistration = try await guestPhotoRequest(
            path: "installations/register", body: [:], credential: credential, context: context
        )
        return reply.installationId
    }

    func bindPhotoInstallation(
        id: UUID, credential: String, context: SyncSessionLease
    ) async throws {
        let reply: PhotoInstallationBinding = try await guestPhotoRequest(
            path: "installations/bind", body: ["installation_id": id.uuidString.lowercased()],
            credential: credential, context: context
        )
        guard reply.bound, reply.installationId == id, reply.ownerId == context.ownerId else {
            throw AnalysisHTTPError.invalidResponse
        }
    }

    func createPhotoDraft(
        operationId: UUID, jobId: UUID, taxonId: UUID, credential: String, context: SyncSessionLease
    ) async throws -> GuestPhotoDraftReceipt {
        let result: GuestPhotoDraftReceipt = try await guestPhotoRequest(
            path: "drafts",
            body: ["operation_id": operationId.uuidString.lowercased(), "identification_job_id": jobId.uuidString.lowercased(),
                   "taxon_id": taxonId.uuidString.lowercased()],
            credential: credential, context: context
        )
        guard SQLTimestamp.date(from: result.expiresAt) != nil else { throw AnalysisHTTPError.invalidResponse }
        return result
    }

    nonisolated static func isGuestPhotoSession(_ session: NativeAuthSession) -> Bool {
        struct Claims: Decodable {
            let sub: UUID
            let is_anonymous: Bool
        }
        let parts = session.accessToken.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty }), session.expiresAt > Date() else { return false }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONDecoder().decode(Claims.self, from: data) else { return false }
        return claims.is_anonymous && claims.sub == session.userId
    }

    func createDiagnosisPhotoDraft(
        operationId: UUID, jobId: UUID, credential: String, context: SyncSessionLease
    ) async throws -> GuestPhotoDraftReceipt {
        try syncAuthority.withBoundValid(context) {
            guard let session = context.session, Self.isGuestPhotoSession(session) else {
                throw SyncWireValidationError.invalidSession
            }
        }
        let result: GuestPhotoDraftReceipt = try await guestPhotoRequest(
            path: "drafts",
            body: ["operation_id": operationId.uuidString.lowercased(),
                   "diagnosis_job_id": jobId.uuidString.lowercased()],
            credential: credential, context: context
        )
        guard SQLTimestamp.date(from: result.expiresAt) != nil else { throw AnalysisHTTPError.invalidResponse }
        return result
    }

    func preparePhotoClaim(
        operationId: UUID, draftId: UUID, credential: String, context: SyncSessionLease
    ) async throws -> GuestPhotoClaimProof {
        let result: GuestPhotoClaimProof = try await guestPhotoRequest(
            path: "claims/prepare", body: ["operation_id": operationId.uuidString.lowercased(), "draft_id": draftId.uuidString.lowercased()],
            credential: credential, context: context
        )
        guard result.draftId == draftId, SQLTimestamp.date(from: result.proofExpiresAt) != nil else {
            throw AnalysisHTTPError.invalidResponse
        }
        return result
    }

    func commitPhotoClaim(
        operationId: UUID, claimId: UUID, credential: String, context: SyncSessionLease
    ) async throws -> GuestPhotoClaimReceipt {
        try await guestPhotoRequest(
            path: "claims/commit", body: ["operation_id": operationId.uuidString.lowercased(), "claim_id": claimId.uuidString.lowercased()],
            credential: credential, context: context
        )
    }

    private func guestPhotoRequest<T: Decodable>(
        path: String, body: [String: String], credential: String, context: SyncSessionLease
    ) async throws -> T {
        guard credential.count >= 16 else { throw AnalysisHTTPError.invalidResponse }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let request = try buildRequest(path: path, method: "POST", body: encoder.encode(body))
        return try await analysisRequest(
            request, locale: .en, context: context, status: [200, 201], installation: credential, forbidRedirects: true
        )
    }

    func fetchCareRecommendation(
        plantId: UUID, context: SyncSessionLease
    ) async throws -> PlantCareRecommendation? {
        let request = try buildRequest(
            path: "plants/\(plantId.uuidString.lowercased())/care/recommendation", method: "GET"
        )
        let response: PlantCareRecommendationResponse = try await analysisRequest(
            request, locale: .en, context: context, status: [200], forbidRedirects: true
        )
        return try syncAuthority.withBoundValid(context) { try response.validated(for: plantId) }
    }

    func fetchPlantPhoto(plantId: UUID, context: SyncSessionLease) async throws -> Data {
        try await fetchPrivatePhoto(path: "plants/\(plantId.uuidString.lowercased())/photo", context: context)
    }

    func fetchObservationPhoto(observationId: UUID, context: SyncSessionLease) async throws -> Data {
        try await fetchPrivatePhoto(path: "care/observations/\(observationId.uuidString.lowercased())/photo", context: context)
    }

    private func fetchPrivatePhoto(path: String, context: SyncSessionLease) async throws -> Data {
        var request = try buildRequest(path: path, method: "GET")
        try syncAuthority.withBoundValid(context) {
            guard let session = context.session else { throw SyncWireValidationError.invalidSession }
            request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue(nil, forHTTPHeaderField: "X-Installation-Credential")
        }
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("image/jpeg, image/png, image/webp", forHTTPHeaderField: "Accept")
        let (data, response) = try await transport.sendWithoutRedirect(request)
        return try syncAuthority.withBoundValid(context) {
            guard response.statusCode == 200,
                  let mime = response.mimeType, ["image/jpeg", "image/png", "image/webp"].contains(mime),
                  !data.isEmpty, data.count <= 10 * 1024 * 1024 else { throw AnalysisHTTPError.invalidResponse }
            return data
        }
    }

    private func validateUploadedPhoto(_ photo: AnalysisUploadedPhoto, id: UUID) throws {
        guard photo.photoAssetId == id, photo.state == "ready" else {
            throw AnalysisHTTPError.invalidResponse
        }
    }

    private func analysisRequest<T: Decodable>(
        _ input: URLRequest, locale: SupportedLocale, context: SyncSessionLease,
        status: Set<Int>, installation: String? = nil, forbidRedirects: Bool = false
    ) async throws -> T {
        var request = input
        try syncAuthority.withBoundValid(context) {
            guard let session = context.session else { throw SyncWireValidationError.invalidSession }
            request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue(locale.rawValue, forHTTPHeaderField: "X-Client-Locale")
            request.setValue(installation, forHTTPHeaderField: "X-Installation-Credential")
        }
        let data: Data
        let response: HTTPURLResponse
        if forbidRedirects {
            (data, response) = try await transport.sendWithoutRedirect(request)
        } else {
            (data, response) = try await transport.send(request)
        }
        try syncAuthority.withBoundValid(context) {}
        let decoder = JSONDecoder()
        guard status.contains(response.statusCode) else {
            if let failure = try? decoder.decode(APIErrorResponse.self, from: data) {
                throw failure
            }
            throw AnalysisHTTPError.invalidResponse
        }
        let decoded = try decoder.decode(T.self, from: data)
        return try syncAuthority.withBoundValid(context) { decoded }
    }

    private func isUploadURL(_ url: URL, photoAssetId: UUID, mediaPath: String) -> Bool {
        guard let candidate = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let base = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              base.scheme?.lowercased() == "https", candidate.scheme?.lowercased() == "https",
              let expectedHost = base.host?.lowercased(),
              candidate.host?.lowercased() == expectedHost,
              (candidate.port ?? 443) == (base.port ?? 443),
              candidate.user == nil, candidate.password == nil, candidate.fragment == nil
        else { return false }
        let prefix = base.percentEncodedPath.hasSuffix("/")
            ? base.percentEncodedPath : base.percentEncodedPath + "/"
        return candidate.percentEncodedPath == prefix + mediaPath + "/uploads/" + photoAssetId.uuidString.lowercased()
    }
}
