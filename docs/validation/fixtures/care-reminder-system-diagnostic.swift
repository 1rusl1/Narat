@MainActor
private struct NaratNotificationDiagnosticView: View {
    @State private var status = "Starting isolated notification diagnostic"
    @State private var started = false
    private let center = SystemCareReminderNotifications()
    private var file: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("narat-system-os-diagnostic.json") }

    var body: some View {
        Text(status).padding().accessibilityIdentifier("notification.diagnostic.status")
            .task { guard !started else { return }; started = true; await run() }
    }

    private func save(_ data: [String: Any]) {
        if let encoded = try? JSONSerialization.data(withJSONObject: data, options: [.sortedKeys, .prettyPrinted]) {
            try? encoded.write(to: file, options: .atomic)
        }
    }

    private func run() async {
        var evidence: [String: Any] = ["status": "RUNNING", "synthetic": true, "backend_calls": 0]
        var identifier: String?
        if ProcessInfo.processInfo.arguments.contains("--notification-diagnostic-cleanup") {
            if let data = try? Data(contentsOf: file), let old = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                identifier = old["identifier"] as? String
                evidence = old
            }
            evidence["cleanup_only"] = true
        } else {
            do {
                let before = try await center.inventory()
                evidence["pending_before"] = before.pending.count
                evidence["other_pending_before"] = before.otherPendingCount
                evidence["authorization_before"] = String(describing: try await center.authorization())
                guard before.pending.isEmpty, before.otherPendingCount == 0 else { throw DiagnosticError.baseline }
                let fire = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) + 3600)
                var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
                let parts = calendar.dateComponents([.year, .month, .day], from: fire)
                let due = String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
                let owner = UUID(), plant = UUID(), rule = UUID(), attempt = UUID()
                let occurrence = CareReminderPlan.Occurrence.routine(ruleId: rule)
                let id = CareReminderPlan.identity(ownerId: owner, plantId: plant, occurrence: occurrence, sourceDueYMD: due)
                let candidate = CareReminderPlan.Candidate(id: id, ownerId: owner, plantId: plant, occurrence: occurrence,
                    sourceDueYMD: due, absoluteFireDate: fire, locale: "en")
                let proposal = CareReminderNotificationProposal(candidate: candidate, attemptId: attempt)
                identifier = CareReminderNotificationFactory.prefix + id
                evidence["identifier"] = identifier
                evidence["phase"] = "requesting_authorization"; save(evidence)
                try await center.requestAuthorization()
                evidence["authorization_after"] = String(describing: try await center.authorization())
                guard case .authorized = try await center.authorization() else { throw DiagnosticError.authorization }
                evidence["phase"] = "adding"; save(evidence)
                try await center.add(proposal, now: Date())
                let pending = await UNUserNotificationCenter.current().pendingNotificationRequests()
                let actual = try await center.inventory()
                let item = actual.pending.first { $0.rawIdentifier == identifier }
                let trusted = item?.route?.candidate == candidate && item?.route?.attemptId == attempt
                evidence["raw_request_present"] = pending.contains { $0.identifier == identifier }
                evidence["trusted_roundtrip"] = trusted
                if let request = pending.first(where: { $0.identifier == identifier }),
                   let trigger = request.trigger as? UNCalendarNotificationTrigger,
                   let expected = try CareReminderNotificationFactory.request(proposal, now: Date()).trigger as? UNCalendarNotificationTrigger {
                    evidence["date_components_equal"] = trigger.dateComponents == expected.dateComponents
                    evidence["actual_components"] = String(describing: trigger.dateComponents)
                    evidence["expected_components"] = String(describing: expected.dateComponents)
                    evidence["nonrepeating"] = !trigger.repeats
                }
                guard trusted else { throw DiagnosticError.roundtrip }
                evidence["status"] = "PASS"
            } catch {
                evidence["status"] = "FAIL"
                evidence["failure_type"] = String(describing: error)
            }
        }
        evidence["phase"] = "cleanup"; save(evidence)
        if let identifier {
            try? await center.removePending([identifier])
            try? await center.removeDelivered([identifier])
            for _ in 0..<30 {
                if let inventory = try? await center.inventory(),
                   !inventory.pending.contains(where: { $0.rawIdentifier == identifier }),
                   !inventory.delivered.contains(where: { $0.rawIdentifier == identifier }) {
                    evidence["synthetic_request_removed"] = true
                    evidence["pending_after"] = inventory.pending.count
                    evidence["other_pending_after"] = inventory.otherPendingCount
                    break
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        if evidence["synthetic_request_removed"] as? Bool != true {
            evidence["status"] = "FAIL"; evidence["cleanup_unconfirmed"] = true
        }
        evidence["phase"] = "complete"; save(evidence)
        status = "Notification diagnostic: " + (evidence["status"] as? String ?? "FAIL")
    }
    private enum DiagnosticError: Error { case baseline, authorization, roundtrip }
}
