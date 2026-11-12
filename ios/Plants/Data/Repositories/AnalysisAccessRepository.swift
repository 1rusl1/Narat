import Foundation
import Security

public struct ModeQuotaSummary: Codable, Sendable, Equatable {
    public let mode: AnalysisMode
    public let allowed: Bool
    public let activeQuotaKind: QuotaKind
    public let remaining: Int
    public let limit: Int
    public let inProgressJobId: UUID?
    public let nextResetAt: Date?
    public let reason: String?

    public init(
        mode: AnalysisMode,
        allowed: Bool,
        activeQuotaKind: QuotaKind,
        remaining: Int,
        limit: Int,
        inProgressJobId: UUID? = nil,
        nextResetAt: Date? = nil,
        reason: String? = nil
    ) {
        self.mode = mode
        self.allowed = allowed
        self.activeQuotaKind = activeQuotaKind
        self.remaining = remaining
        self.limit = limit
        self.inProgressJobId = inProgressJobId
        self.nextResetAt = nextResetAt
        self.reason = reason
    }
}

public struct AnalysisAccessState: Codable, Sendable, Equatable {
    public let isGuest: Bool
    public let starter: StarterAccess
    public let identificationQuota: ModeQuotaSummary
    public let diagnosisQuota: ModeQuotaSummary
    public let canAlwaysUseCatalogue: Bool

    public init(
        isGuest: Bool,
        starter: StarterAccess,
        identificationQuota: ModeQuotaSummary,
        diagnosisQuota: ModeQuotaSummary,
        canAlwaysUseCatalogue: Bool = true
    ) {
        self.isGuest = isGuest
        self.starter = starter
        self.identificationQuota = identificationQuota
        self.diagnosisQuota = diagnosisQuota
        self.canAlwaysUseCatalogue = canAlwaysUseCatalogue
    }
}

public protocol InstallationCredentialStoring: Sendable {
    func getOrCreateCredential() -> String
}

public struct KeychainInstallationCredentialStore: InstallationCredentialStoring {
    private let service: String
    private let account: String

    public init(
        service: String = "app.narat.plants.installation",
        account: String = "installation_credential"
    ) {
        self.service = service
        self.account = account
    }

    public func getOrCreateCredential() -> String {
        if let existing = readFromKeychain(), !existing.isEmpty {
            return existing
        }
        let generated = "\(UUID().uuidString.lowercased())-\(UUID().uuidString.lowercased())"
        switch saveToKeychain(generated) {
        case errSecSuccess: return generated
        case errSecDuplicateItem: return readFromKeychain() ?? ""
        default: return ""
        }
    }

    private func readFromKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func saveToKeychain(_ value: String) -> OSStatus {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        return SecItemAdd(query as CFDictionary, nil)
    }
}

public actor AnalysisAccessRepository {
    private let credentialStore: any InstallationCredentialStoring
    private var currentState: AnalysisAccessState

    public init(
        credentialStore: any InstallationCredentialStoring = KeychainInstallationCredentialStore(),
        initialState: AnalysisAccessState? = nil
    ) {
        self.credentialStore = credentialStore
        self.currentState = initialState ?? AnalysisAccessState(
            isGuest: true,
            starter: StarterAccess(identificationRemaining: 1, diagnosisRemaining: 1),
            identificationQuota: ModeQuotaSummary(
                mode: .identification,
                allowed: true,
                activeQuotaKind: .starterIdentification,
                remaining: 1,
                limit: 1
            ),
            diagnosisQuota: ModeQuotaSummary(
                mode: .diagnosis,
                allowed: true,
                activeQuotaKind: .starterDiagnosis,
                remaining: 1,
                limit: 1
            ),
            canAlwaysUseCatalogue: true
        )
    }

    public func installationCredential() -> String {
        credentialStore.getOrCreateCredential()
    }

    func fetchSnapshot(
        api: PlantsAPIClient, context: SyncSessionLease, expectedGuest: Bool, guestCredential: String?
    ) async throws -> AnalysisAccessWireDTO {
        try await api.fetchAnalysisAccess(
            context: context, expectedGuest: expectedGuest,
            guestCredential: expectedGuest ? guestCredential ?? installationCredential() : nil
        )
    }

    public func currentAccessState() -> AnalysisAccessState {
        currentState
    }

    public func updateAccessState(_ newState: AnalysisAccessState) {
        currentState = newState
    }

    public func markStarterConsumed(for mode: AnalysisMode, at date: Date = Date()) {
        guard mode.isSelectable else { return }
        let newIdRem = mode == .identification ? 0 : currentState.starter.identificationRemaining
        let newDiagRem = mode == .diagnosis ? 0 : currentState.starter.diagnosisRemaining
        let earliest = currentState.starter.firstStarterSuccessAt ?? date

        let newStarter = StarterAccess(
            identificationRemaining: newIdRem,
            diagnosisRemaining: newDiagRem,
            firstStarterSuccessAt: earliest
        )

        let idQuota = ModeQuotaSummary(
            mode: .identification,
            allowed: newIdRem > 0,
            activeQuotaKind: .starterIdentification,
            remaining: newIdRem,
            limit: 1,
            reason: newIdRem == 0 ? "starter_exhausted" : nil
        )
        let diagQuota = ModeQuotaSummary(
            mode: .diagnosis,
            allowed: newDiagRem > 0,
            activeQuotaKind: .starterDiagnosis,
            remaining: newDiagRem,
            limit: 1,
            reason: newDiagRem == 0 ? "starter_exhausted" : nil
        )

        currentState = AnalysisAccessState(
            isGuest: currentState.isGuest,
            starter: newStarter,
            identificationQuota: idQuota,
            diagnosisQuota: diagQuota,
            canAlwaysUseCatalogue: true
        )
    }
}
