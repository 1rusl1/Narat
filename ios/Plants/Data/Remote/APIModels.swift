import Foundation

// MARK: - Profile & Overrides DTOs (FR-035, FR-046..048)

public struct ProfileDTO: Codable, Sendable, Equatable {
    public let id: UUID
    public let accountState: String
    public let anonymous: Bool
    public let preferredLocale: String
    public let reminderHourLocal: Int
    public let freeSelectionExplicit: Bool
    public let trialReminderOptIn: Bool
    public let monthlyReportOptIn: Bool
    public let updatedAt: Date

    public init(
        id: UUID,
        accountState: String = "active",
        anonymous: Bool = false,
        preferredLocale: String = "pl",
        reminderHourLocal: Int = 9,
        freeSelectionExplicit: Bool = false,
        trialReminderOptIn: Bool = false,
        monthlyReportOptIn: Bool = false,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.accountState = accountState
        self.anonymous = anonymous
        self.preferredLocale = preferredLocale
        self.reminderHourLocal = reminderHourLocal
        self.freeSelectionExplicit = freeSelectionExplicit
        self.trialReminderOptIn = trialReminderOptIn
        self.monthlyReportOptIn = monthlyReportOptIn
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case accountState = "account_state"
        case anonymous
        case preferredLocale = "preferred_locale"
        case reminderHourLocal = "reminder_hour_local"
        case freeSelectionExplicit = "free_selection_explicit"
        case trialReminderOptIn = "trial_reminder_opt_in"
        case monthlyReportOptIn = "monthly_report_opt_in"
        case updatedAt = "updated_at"
    }
}

public struct ClaimOverridesDTO: Codable, Sendable, Equatable {
    public var plantId: String?
    public var taxonId: UUID?
    public var displayName: String?
    public var lightLevel: LightLevel?
    public var lightSource: LightSource?
    public var lightConfirmed: Bool?
    public var wateringHabit: WateringHabit?
    public var lastWatered: LastWateredBucket?
    public var potType: PotType?
    public var seasonOverride: SeasonOverride?

    public init(
        plantId: String? = nil,
        taxonId: UUID? = nil,
        displayName: String? = nil,
        lightLevel: LightLevel? = nil,
        lightSource: LightSource? = nil,
        lightConfirmed: Bool? = nil,
        wateringHabit: WateringHabit? = nil,
        lastWatered: LastWateredBucket? = nil,
        potType: PotType? = nil,
        seasonOverride: SeasonOverride? = nil
    ) {
        self.plantId = plantId
        self.taxonId = taxonId
        self.displayName = displayName
        self.lightLevel = lightLevel
        self.lightSource = lightSource
        self.lightConfirmed = lightConfirmed
        self.wateringHabit = wateringHabit
        self.lastWatered = lastWatered
        self.potType = potType
        self.seasonOverride = seasonOverride
    }

    enum CodingKeys: String, CodingKey {
        case plantId = "plant_id"
        case taxonId = "taxon_id"
        case displayName = "display_name"
        case lightLevel = "light_level"
        case lightSource = "light_source"
        case lightConfirmed = "light_confirmed"
        case wateringHabit = "watering_habit"
        case lastWatered = "last_watered"
        case potType = "pot_type"
        case seasonOverride = "season_override"
    }
}

public struct AnalysisReceiptDTO: Codable, Sendable, Equatable {
    public let analysisId: UUID
    public let kbReleaseId: UUID
    public let mode: AnalysisMode
    public let plantId: String?
    public let selectedConditionId: String?
    public let decisionRevision: Int
    public let issuedAt: Date
    public let signature: String

    public init(
        analysisId: UUID,
        kbReleaseId: UUID,
        mode: AnalysisMode,
        plantId: String?,
        selectedConditionId: String?,
        decisionRevision: Int = 1,
        issuedAt: Date,
        signature: String
    ) {
        self.analysisId = analysisId
        self.kbReleaseId = kbReleaseId
        self.mode = mode
        self.plantId = plantId
        self.selectedConditionId = selectedConditionId
        self.decisionRevision = decisionRevision
        self.issuedAt = issuedAt
        self.signature = signature
    }

    enum CodingKeys: String, CodingKey {
        case analysisId = "analysis_id"
        case kbReleaseId = "kb_release_id"
        case mode
        case plantId = "plant_id"
        case selectedConditionId = "selected_condition_id"
        case decisionRevision = "decision_revision"
        case issuedAt = "issued_at"
        case signature
    }
}

// MARK: - Monthly Progress Report DTO (FR-068)

public struct PlantProgressHighlightDTO: Codable, Sendable, Equatable {
    public let plantId: UUID
    public let displayName: String
    public let careActionsCount: Int
    public let latestOutcome: ObservationOutcome?
    public let beforePhotoAssetId: UUID?
    public let afterPhotoAssetId: UUID?

    public init(
        plantId: UUID,
        displayName: String,
        careActionsCount: Int,
        latestOutcome: ObservationOutcome? = nil,
        beforePhotoAssetId: UUID? = nil,
        afterPhotoAssetId: UUID? = nil
    ) {
        self.plantId = plantId
        self.displayName = displayName
        self.careActionsCount = careActionsCount
        self.latestOutcome = latestOutcome
        self.beforePhotoAssetId = beforePhotoAssetId
        self.afterPhotoAssetId = afterPhotoAssetId
    }

    enum CodingKeys: String, CodingKey {
        case plantId = "plant_id"
        case displayName = "display_name"
        case careActionsCount = "care_actions_count"
        case latestOutcome = "latest_outcome"
        case beforePhotoAssetId = "before_photo_asset_id"
        case afterPhotoAssetId = "after_photo_asset_id"
    }
}

public struct ProgressReportDTO: Codable, Sendable, Equatable {
    public let monthKey: String
    public let isPartialPeriod: Bool
    public let totalCareActions: Int
    public let activePlantsCount: Int
    public let resolvedIssuesCount: Int
    public let highlights: [PlantProgressHighlightDTO]
    public let watermark: Date

    public init(
        monthKey: String,
        isPartialPeriod: Bool,
        totalCareActions: Int,
        activePlantsCount: Int,
        resolvedIssuesCount: Int,
        highlights: [PlantProgressHighlightDTO],
        watermark: Date
    ) {
        self.monthKey = monthKey
        self.isPartialPeriod = isPartialPeriod
        self.totalCareActions = totalCareActions
        self.activePlantsCount = activePlantsCount
        self.resolvedIssuesCount = resolvedIssuesCount
        self.highlights = highlights
        self.watermark = watermark
    }

    enum CodingKeys: String, CodingKey {
        case monthKey = "month_key"
        case isPartialPeriod = "is_partial_period"
        case totalCareActions = "total_care_actions"
        case activePlantsCount = "active_plants_count"
        case resolvedIssuesCount = "resolved_issues_count"
        case highlights
        case watermark
    }
}

// MARK: - Sync & Command Envelopes (contracts/sync.md, contracts/api.md)

public struct SyncCursorDTO: Codable, Sendable, Equatable {
    public let updatedAt: Date
    public let entityType: String
    public let id: UUID

    public init(updatedAt: Date, entityType: String, id: UUID) {
        self.updatedAt = updatedAt
        self.entityType = entityType
        self.id = id
    }

    enum CodingKeys: String, CodingKey {
        case updatedAt = "updated_at"
        case entityType = "entity_type"
        case id
    }
}

public struct SyncItemDTO: Codable, Sendable, Equatable {
    public let entityType: String
    public let id: UUID
    public let updatedAt: Date
    public let deletedAt: Date?
    public let payloadJSON: String

    public init(
        entityType: String,
        id: UUID,
        updatedAt: Date,
        deletedAt: Date? = nil,
        payloadJSON: String
    ) {
        self.entityType = entityType
        self.id = id
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.payloadJSON = payloadJSON
    }

    enum CodingKeys: String, CodingKey {
        case entityType = "entity_type"
        case id
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
        case payloadJSON = "payload_json"
    }
}

public struct SyncPageDTO: Codable, Sendable, Equatable {
    public let ownerId: UUID
    public let items: [SyncItemDTO]
    public let hasMore: Bool
    public let nextCursor: SyncCursorDTO?
    public let serverWatermark: Date
    public let limit: Int

    public init(
        ownerId: UUID,
        items: [SyncItemDTO],
        hasMore: Bool,
        nextCursor: SyncCursorDTO?,
        serverWatermark: Date,
        limit: Int
    ) {
        self.ownerId = ownerId
        self.items = items
        self.hasMore = hasMore
        self.nextCursor = nextCursor
        self.serverWatermark = serverWatermark
        self.limit = limit
    }

    enum CodingKeys: String, CodingKey {
        case ownerId = "owner_id"
        case items
        case hasMore = "has_more"
        case nextCursor = "next_cursor"
        case serverWatermark = "server_watermark"
        case limit
    }
}

public struct CommandEnvelopeDTO: Codable, Sendable, Equatable {
    public let operationId: UUID
    public let commandName: String
    public let plantId: UUID?
    public let payloadJSON: String

    public init(
        operationId: UUID,
        commandName: String,
        plantId: UUID? = nil,
        payloadJSON: String
    ) {
        self.operationId = operationId
        self.commandName = commandName
        self.plantId = plantId
        self.payloadJSON = payloadJSON
    }

    enum CodingKeys: String, CodingKey {
        case operationId = "operation_id"
        case commandName = "command_name"
        case plantId = "plant_id"
        case payloadJSON = "payload_json"
    }
}

public struct CommandResponseDTO: Codable, Sendable, Equatable {
    public let status: String
    public let operationId: UUID
    public let replayed: Bool
    public let watermark: Date?

    public init(
        status: String,
        operationId: UUID,
        replayed: Bool = false,
        watermark: Date? = nil
    ) {
        self.status = status
        self.operationId = operationId
        self.replayed = replayed
        self.watermark = watermark
    }

    enum CodingKeys: String, CodingKey {
        case status
        case operationId = "operation_id"
        case replayed
        case watermark
    }
}

// MARK: - Authoritative catalogue create receipt (collection-http.md)

/// The raw SQL boundary must be retained: Date cannot represent every microsecond exactly.
public struct PlantCreateReceiptDTO: Codable, Sendable, Equatable {
    public let plantId: UUID
    public let careRevision: Int
    public let contextState: String
    public let nextAvailableStep: String
    /// compute_next_available_step currently returns TEXT or SQL NULL.
    public let paidAction: String?
    public let planAvailability: String
    public let watermark: Date
    public let watermarkRaw: String

    enum CodingKeys: String, CodingKey {
        case plantId = "plant_id"
        case careRevision = "care_revision"
        case contextState = "context_state"
        case nextAvailableStep = "next_available_step"
        case paidAction = "paid_action"
        case planAvailability = "plan_availability"
        case watermark
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        plantId = try values.decode(UUID.self, forKey: .plantId)
        careRevision = try values.decode(Int.self, forKey: .careRevision)
        contextState = try values.decode(String.self, forKey: .contextState)
        nextAvailableStep = try values.decode(String.self, forKey: .nextAvailableStep)
        paidAction = try values.decodeIfPresent(String.self, forKey: .paidAction)
        planAvailability = try values.decode(String.self, forKey: .planAvailability)
        watermarkRaw = try values.decode(String.self, forKey: .watermark)
        guard (1...9_007_199_254_740_991).contains(careRevision),
              !contextState.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !nextAvailableStep.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !planAvailability.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let date = SQLTimestamp.date(from: watermarkRaw) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath, debugDescription: "Invalid catalogue create receipt"
            ))
        }
        watermark = date
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(plantId, forKey: .plantId)
        try values.encode(careRevision, forKey: .careRevision)
        try values.encode(contextState, forKey: .contextState)
        try values.encode(nextAvailableStep, forKey: .nextAvailableStep)
        try values.encodeIfPresent(paidAction, forKey: .paidAction)
        try values.encode(planAvailability, forKey: .planAvailability)
        try values.encode(watermarkRaw, forKey: .watermark)
    }
}

/// Strict SQL ISO timestamps, independent of JSONDecoder's legacy date strategy.
enum SQLTimestamp {
    static func date(from value: String) -> Date? {
        let pattern = #"^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(?:\.([0-9]{1,6}))?(Z|[+-][0-9]{2}:[0-9]{2})$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              match.range.length == value.utf16.count else { return nil }
        func group(_ index: Int) -> String? {
            guard let range = Range(match.range(at: index), in: value) else { return nil }
            return String(value[range])
        }
        guard let year = group(1).flatMap(Int.init), year > 0,
              let month = group(2).flatMap(Int.init), (1...12).contains(month),
              let day = group(3).flatMap(Int.init), (1...31).contains(day),
              let hour = group(4).flatMap(Int.init), (0...23).contains(hour),
              let minute = group(5).flatMap(Int.init), (0...59).contains(minute),
              let second = group(6).flatMap(Int.init), (0...59).contains(second),
              let zone = group(8) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute, second: second
        )
        guard let whole = calendar.date(from: components) else { return nil }
        let checked = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: whole)
        guard checked.year == year, checked.month == month, checked.day == day,
              checked.hour == hour, checked.minute == minute, checked.second == second else { return nil }
        var offset = 0
        if zone != "Z" {
            let parts = zone.dropFirst().split(separator: ":")
            guard parts.count == 2, let hours = Int(parts[0]), hours <= 15,
                  let minutes = Int(parts[1]), minutes <= 59 else { return nil }
            offset = (hours * 3600 + minutes * 60) * (zone.first == "-" ? -1 : 1)
        }
        let fraction = group(7).flatMap { Double("0." + $0) } ?? 0
        return whole.addingTimeInterval(fraction - Double(offset))
    }
}

// MARK: - Canonical SQL sync wire (legacy DTOs above remain disk-compatible)

/// Recursive SQL JSON data; numbers are decoded without a Double conversion.
public indirect enum SyncWireJSON: Codable, Sendable, Equatable {
    case object([String: SyncWireJSON])
    case array([SyncWireJSON])
    case string(String)
    case number(Decimal)
    case bool(Bool)
    case null

    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let bool = try? value.decode(Bool.self) { self = .bool(bool) }
        else if let string = try? value.decode(String.self) { self = .string(string) }
        else if let object = try? value.decode([String: SyncWireJSON].self) { self = .object(object) }
        else if let array = try? value.decode([SyncWireJSON].self) { self = .array(array) }
        else { self = .number(try value.decode(Decimal.self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case let .object(object): try value.encode(object)
        case let .array(array): try value.encode(array)
        case let .string(string): try value.encode(string)
        case let .number(number): try value.encode(number)
        case let .bool(bool): try value.encode(bool)
        case .null: try value.encodeNil()
        }
    }
}

public enum SyncWireValidationError: Error, Sendable {
    case invalidRequest
    case invalidPage
    case invalidSession
}

/// All timestamp properties intentionally retain their original SQL spelling.
public struct SyncWireCursorDTO: Decodable, Sendable, Equatable {
    public let since: String?
    public let until: String
    public let updatedAt: String
    public let entityType: String
    public let id: UUID

    public init(since: String?, until: String, updatedAt: String, entityType: String, id: UUID) {
        self.since = since
        self.until = until
        self.updatedAt = updatedAt
        self.entityType = entityType
        self.id = id
    }

    enum CodingKeys: String, CodingKey {
        case since, until, id
        case updatedAt = "updated_at"
        case entityType = "entity_type"
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // decode(Optional.self), rather than decodeIfPresent, requires the nullable key.
        since = try values.decode(String?.self, forKey: .since)
        until = try values.decode(String.self, forKey: .until)
        updatedAt = try values.decode(String.self, forKey: .updatedAt)
        entityType = try values.decode(String.self, forKey: .entityType)
        id = try values.decode(UUID.self, forKey: .id)
        guard SyncWireRules.validCursor(self) else { throw SyncWireValidationError.invalidPage }
    }
}

public struct SyncWireChangeDTO: Decodable, Sendable, Equatable {
    public let entityType: String
    public let id: UUID
    public let updatedAt: String
    public let deletedAt: String?
    public let data: SyncWireJSON

    enum CodingKeys: String, CodingKey {
        case id, data
        case entityType = "entity_type"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        entityType = try values.decode(String.self, forKey: .entityType)
        id = try values.decode(UUID.self, forKey: .id)
        updatedAt = try values.decode(String.self, forKey: .updatedAt)
        deletedAt = try values.decode(String?.self, forKey: .deletedAt)
        data = try values.decode(SyncWireJSON.self, forKey: .data)
        guard SyncWireRules.entityTypes.contains(entityType),
              SQLTimestamp.microseconds(from: updatedAt) != nil,
              deletedAt == nil || SQLTimestamp.microseconds(from: deletedAt!) != nil else {
            throw SyncWireValidationError.invalidPage
        }
        if deletedAt == nil {
            guard case .object = data else { throw SyncWireValidationError.invalidPage }
        } else {
            guard data == .null else { throw SyncWireValidationError.invalidPage }
        }
    }
}

public struct SyncWireProfileDTO: Codable, Sendable, Equatable {
    public let preferredLocale: String
    public let reminderHourLocal: Int
    public let reportNotificationsEnabled: Bool
    public let trialReminderEnabled: Bool

    enum CodingKeys: String, CodingKey {
        case preferredLocale = "preferred_locale"
        case reminderHourLocal = "reminder_hour_local"
        case reportNotificationsEnabled = "report_notifications_enabled"
        case trialReminderEnabled = "trial_reminder_enabled"
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        preferredLocale = try values.decode(String.self, forKey: .preferredLocale)
        reminderHourLocal = try values.decode(Int.self, forKey: .reminderHourLocal)
        reportNotificationsEnabled = try values.decode(Bool.self, forKey: .reportNotificationsEnabled)
        trialReminderEnabled = try values.decode(Bool.self, forKey: .trialReminderEnabled)
        guard ["en", "pl"].contains(preferredLocale), (0...23).contains(reminderHourLocal) else {
            throw SyncWireValidationError.invalidPage
        }
    }
}

public struct SyncWireEntitlementDTO: Codable, Sendable, Equatable {
    public let productId: String
    public let state: String
    public let offerKind: String
    public let validUntil: String?
    public let graceUntil: String?
    public let trialEndAt: String?
    public let autoRenewEnabled: Bool

    enum CodingKeys: String, CodingKey {
        case productId = "product_id"
        case state
        case offerKind = "offer_kind"
        case validUntil = "valid_until"
        case graceUntil = "grace_until"
        case trialEndAt = "trial_end_at"
        case autoRenewEnabled = "auto_renew_enabled"
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        productId = try values.decode(String.self, forKey: .productId)
        state = try values.decode(String.self, forKey: .state)
        offerKind = try values.decode(String.self, forKey: .offerKind)
        validUntil = try values.decode(String?.self, forKey: .validUntil)
        graceUntil = try values.decode(String?.self, forKey: .graceUntil)
        trialEndAt = try values.decode(String?.self, forKey: .trialEndAt)
        autoRenewEnabled = try values.decode(Bool.self, forKey: .autoRenewEnabled)
        guard !productId.isEmpty, !state.isEmpty, ["trial", "paid"].contains(offerKind),
              [validUntil, graceUntil, trialEndAt].allSatisfy({
                  $0 == nil || SQLTimestamp.microseconds(from: $0!) != nil
              }) else { throw SyncWireValidationError.invalidPage }
    }
}

public struct SyncWirePageDTO: Decodable, Sendable, Equatable {
    public let until: String
    public let hasMore: Bool
    public let lastCursor: SyncWireCursorDTO?
    public let nextSince: String?
    public let profile: SyncWireProfileDTO
    public let entitlement: SyncWireEntitlementDTO?
    public let changes: [SyncWireChangeDTO]

    enum CodingKeys: String, CodingKey {
        case until, profile, entitlement, changes
        case hasMore = "has_more"
        case lastCursor = "last_cursor"
        case nextSince = "next_since"
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        until = try values.decode(String.self, forKey: .until)
        hasMore = try values.decode(Bool.self, forKey: .hasMore)
        lastCursor = try values.decode(SyncWireCursorDTO?.self, forKey: .lastCursor)
        nextSince = try values.decode(String?.self, forKey: .nextSince)
        profile = try values.decode(SyncWireProfileDTO.self, forKey: .profile)
        entitlement = try values.decode(SyncWireEntitlementDTO?.self, forKey: .entitlement)
        changes = try values.decode([SyncWireChangeDTO].self, forKey: .changes)
        try validate(since: lastCursor?.since, requestedUntil: nil, cursor: nil, limit: 500)
    }

    func validate(since: String?, requestedUntil: String?, cursor: SyncWireCursorDTO?, limit: Int) throws {
        guard let end = SQLTimestamp.microseconds(from: until), changes.count <= limit,
              requestedUntil == nil || SyncWireRules.sameTime(requestedUntil, until),
              since == nil || SQLTimestamp.microseconds(from: since!).map({ $0 <= end }) == true else {
            throw SyncWireValidationError.invalidPage
        }
        var previous = cursor.map { SyncWireRules.key($0.updatedAt, $0.entityType, $0.id) }
        for change in changes {
            let key = SyncWireRules.key(change.updatedAt, change.entityType, change.id)
            guard key.0 <= end,
                  since == nil || SQLTimestamp.microseconds(from: since!).map({ key.0 > $0 }) == true,
                  previous == nil || previous! < key else { throw SyncWireValidationError.invalidPage }
            previous = key
        }
        if hasMore {
            guard let lastCursor, let last = changes.last, nextSince == nil,
                  SyncWireRules.sameTime(lastCursor.since, since),
                  SyncWireRules.sameTime(lastCursor.until, until),
                  SyncWireRules.key(lastCursor.updatedAt, lastCursor.entityType, lastCursor.id)
                    == SyncWireRules.key(last.updatedAt, last.entityType, last.id) else {
                throw SyncWireValidationError.invalidPage
            }
        } else {
            guard lastCursor == nil, SyncWireRules.sameTime(nextSince, until) else {
                throw SyncWireValidationError.invalidPage
            }
        }
    }
}

/// Ownership is local authenticated context, never a field supplied by the response.
public struct SyncWireResult: Sendable, Equatable {
    public let ownerId: UUID
    public let page: SyncWirePageDTO
}

enum SyncWireRules {
    static let entityTypes: Set<String> = [
        "plants", "condition_snapshots", "photo_assets", "analysis_summaries",
        "care_plan_summaries", "care_tasks", "care_entries", "care_reversals",
        "schedule_changes", "basic_care_memberships", "first_aid_followups",
        "care_observations", "recovery_transitions", "notification_claim_summaries"
    ]

    static func sameTime(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        guard let parsed = SQLTimestamp.microseconds(from: lhs) else { return false }
        return parsed == SQLTimestamp.microseconds(from: rhs)
    }

    static func key(_ timestamp: String, _ entity: String, _ id: UUID) -> (Int64, String, String) {
        // Only called after validating timestamps. UUID hex order matches PostgreSQL UUID order.
        (SQLTimestamp.microseconds(from: timestamp)!, entity, id.uuidString.lowercased())
    }

    static func validCursor(_ cursor: SyncWireCursorDTO) -> Bool {
        guard let end = SQLTimestamp.microseconds(from: cursor.until),
              let position = SQLTimestamp.microseconds(from: cursor.updatedAt),
              entityTypes.contains(cursor.entityType), position <= end else { return false }
        return cursor.since == nil ||
            SQLTimestamp.microseconds(from: cursor.since!).map({ $0 < position }) == true
    }

    static func validateRequest(since: String?, until: String?, cursor: SyncWireCursorDTO?, limit: Int) throws {
        guard (1...500).contains(limit),
              since == nil || SQLTimestamp.microseconds(from: since!) != nil,
              until == nil || SQLTimestamp.microseconds(from: until!) != nil else {
            throw SyncWireValidationError.invalidRequest
        }
        if let since, let until {
            guard SQLTimestamp.microseconds(from: since)! <= SQLTimestamp.microseconds(from: until)! else {
                throw SyncWireValidationError.invalidRequest
            }
        }
        if let cursor {
            guard validCursor(cursor), until != nil,
                  sameTime(cursor.since, since), sameTime(cursor.until, until) else {
                throw SyncWireValidationError.invalidRequest
            }
        }
    }
}

extension SQLTimestamp {
    /// Parse the whole second separately so binary Date fractions cannot merge adjacent SQL microseconds.
    static func microseconds(from raw: String) -> Int64? {
        guard date(from: raw) != nil else { return nil }
        let fractionRange = raw.range(of: #"\.[0-9]{1,6}"#, options: .regularExpression)
        var whole = raw
        var fraction: Int64 = 0
        if let fractionRange {
            let digits = String(raw[fractionRange].dropFirst())
            fraction = Int64(digits + String(repeating: "0", count: 6 - digits.count))!
            whole.removeSubrange(fractionRange)
        }
        guard let seconds = date(from: whole) else { return nil }
        return Int64(seconds.timeIntervalSince1970.rounded()) * 1_000_000 + fraction
    }
}
