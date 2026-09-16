import Foundation

/// A Foundation-only snapshot keeps alarm identity independent of the UI and AlarmKit.
nonisolated struct RetirementAlarmShift: Codable, Equatable, Sendable {
    let uid: String
    let start: Date
    let end: Date
    let location: String
}

nonisolated struct RetirementAlarmRecord: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var shift: RetirementAlarmShift
    var knownUIDs: Set<String>
    var isPresent: Bool
    var overrideEnabled: Bool?
    var isConsumed: Bool
    /// Set only after AlarmKit accepts a reservation; cleared after our own cancellation.
    var scheduledDate: Date?

    init(shift: RetirementAlarmShift) {
        id = UUID()
        self.shift = shift
        knownUIDs = [shift.uid]
        isPresent = true
        overrideEnabled = nil
        isConsumed = false
        scheduledDate = nil
    }
}

nonisolated struct RetirementAlarmAccount: Codable, Equatable, Sendable {
    var isEnabled = false
    var hasCurrentSnapshot = false
    var records: [RetirementAlarmRecord] = []
}

nonisolated enum RetirementAlarmPolicy {
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return calendar
    }

    static func isEligible(_ shift: RetirementAlarmShift) -> Bool {
        let components = calendar.dateComponents([.hour, .minute], from: shift.end)
        return shift.end > shift.start && components.hour == 19 && components.minute == 45
    }

    static func recordIndex(uid: String, in records: [RetirementAlarmRecord]) -> Int? {
        if let index = records.firstIndex(where: { $0.isPresent && $0.shift.uid == uid }) { return index }
        if let index = records.firstIndex(where: { $0.shift.uid == uid }) { return index }
        let aliases = records.indices.filter { records[$0].knownUIDs.contains(uid) }
        return aliases.count == 1 ? aliases.first : nil
    }

    /// A changed UID inherits a preference only when both snapshots have one shift
    /// on that date at that location. Split shifts must never steal one another's settings.
    static func merging(
        _ shifts: [RetirementAlarmShift],
        into existing: [RetirementAlarmRecord]
    ) -> [RetirementAlarmRecord] {
        var seenUIDs: Set<String> = []
        let incoming = shifts.filter { seenUIDs.insert($0.uid).inserted }
        var records = existing
        let previousCounts = Dictionary(grouping: existing.filter(\.isPresent)) { identityBucket($0.shift) }
        let incomingCounts = Dictionary(grouping: incoming, by: identityBucket)
        var claimed: Set<UUID> = []
        var unmatchedExact: [RetirementAlarmShift] = []
        var pending: [RetirementAlarmShift] = []

        for index in records.indices {
            records[index].isPresent = false
        }

        // Current UIDs win globally before aliases, regardless of incoming row order.
        for shift in incoming {
            let matches = records.indices.filter {
                !claimed.contains(records[$0].id) && records[$0].shift.uid == shift.uid
            }
            if matches.count == 1, let index = matches.first {
                update(&records[index], with: shift)
                claimed.insert(records[index].id)
            } else {
                unmatchedExact.append(shift)
            }
        }
        for shift in unmatchedExact {
            let matches = records.indices.filter {
                !claimed.contains(records[$0].id) && records[$0].knownUIDs.contains(shift.uid)
            }
            if matches.count == 1, let index = matches.first {
                update(&records[index], with: shift)
                claimed.insert(records[index].id)
            } else {
                pending.append(shift)
            }
        }

        for shift in pending {
            let bucket = identityBucket(shift)
            let previous = previousCounts[bucket] ?? []
            if previous.count == 1,
               incomingCounts[bucket]?.count == 1,
               let prior = previous.first,
               !claimed.contains(prior.id),
               let index = records.firstIndex(where: { $0.id == prior.id }) {
                update(&records[index], with: shift)
                claimed.insert(prior.id)
            } else {
                let record = RetirementAlarmRecord(shift: shift)
                records.append(record)
                claimed.insert(record.id)
            }
        }
        return records
    }

    static func desiredRecords(
        in account: RetirementAlarmAccount,
        now: Date
    ) -> [RetirementAlarmRecord] {
        guard account.isEnabled, account.hasCurrentSnapshot else { return [] }
        return account.records.filter {
            $0.isPresent && $0.overrideEnabled != false && !$0.isConsumed
                && $0.shift.end > now && isEligible($0.shift)
        }.sorted {
            $0.shift.end == $1.shift.end
                ? $0.id.uuidString < $1.id.uuidString
                : $0.shift.end < $1.shift.end
        }
    }

    /// Missing one-shot reservations have already fired or been dismissed. Our
    /// own successful cancellations clear scheduledDate, so they don't become tombstones.
    static func observing(
        registeredIDs: Set<UUID>,
        records: [RetirementAlarmRecord]
    ) -> [RetirementAlarmRecord] {
        records.map { original in
            var record = original
            if record.scheduledDate != nil && !registeredIDs.contains(record.id) {
                record.isConsumed = true
                record.scheduledDate = nil
            }
            return record
        }
    }

    private static func identityBucket(_ shift: RetirementAlarmShift) -> String {
        let day = calendar.dateComponents([.year, .month, .day], from: shift.start)
        let location = shift.location.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(day.year ?? 0)-\(day.month ?? 0)-\(day.day ?? 0)|\(location)"
    }

    private static func update(_ record: inout RetirementAlarmRecord, with shift: RetirementAlarmShift) {
        record.knownUIDs.insert(shift.uid)
        record.shift = shift
        record.isPresent = true
    }
}
