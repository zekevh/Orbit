import Dispatch
import Foundation
import SQLite3

enum OrbitDatabaseError: LocalizedError {
    case openFailed(String)
    case prepareFailed(String)
    case stepFailed(String)
    case bindFailed(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let message),
             .prepareFailed(let message),
             .stepFailed(let message),
             .bindFailed(let message):
            message
        }
    }
}

final class OrbitDatabase: @unchecked Sendable {
    private static let currentSchemaVersion = 4

    private let db: OpaquePointer
    private let queue = DispatchQueue(label: "io.zvh.orbit.database")

    private enum ContactListActivitySQL {
        case derived
        case zero
    }

    init() throws {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Orbit", isDirectory: true)

        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)

        let dbURL = appSupport.appendingPathComponent("orbit.sqlite")
        var handle: OpaquePointer?
        if sqlite3_open(dbURL.path, &handle) != SQLITE_OK {
            let message = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Could not open database"
            sqlite3_close(handle)
            throw OrbitDatabaseError.openFailed(message)
        }
        guard let handle else {
            throw OrbitDatabaseError.openFailed("SQLite handle was nil")
        }

        db = handle
        try queue.sync {
            try execute("PRAGMA foreign_keys = ON;")
            try migrate()
        }
    }

    deinit {
        sqlite3_close(db)
    }

    nonisolated func syncContacts(_ snapshots: [ContactSyncSnapshot]) throws {
        try queue.sync {
            try execute("BEGIN IMMEDIATE TRANSACTION;")
            do {
                let statement = try prepare(Self.contactUpsertSQL)
                defer { sqlite3_finalize(statement) }
                for snapshot in snapshots {
                    try upsert(snapshot: snapshot, statement: statement)
                }
                try rebuildContactDerivedFields()
                try execute("COMMIT;")
            } catch {
                try? execute("ROLLBACK;")
                throw error
            }
        }
    }

    nonisolated func fetchContacts(filter: SidebarFilter, search: String) throws -> [ContactListItem] {
        try queue.sync {
            let searchTerm = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().nonEmpty
            let likeValue = searchTerm.map { "%\($0)%" }
            let prefixLikeValue = searchTerm.map { "\($0)%" }
            let wordPrefixLikeValue = searchTerm.map { "% \($0)%" }
            let filterClause: String
            switch filter {
            case .allContacts:
                filterClause = ""
            case .needsVerification:
                filterClause = """
                AND c.primary_phone IS NOT NULL
                AND TRIM(c.primary_phone) != ''
                AND c.verification_status != 'verified'
                AND c.image_data IS NULL
                AND c.enriched_image_data IS NULL
                """
            case .duplicates:
                filterClause = ""
            case .needsFollowUp:
                filterClause = "AND c.open_follow_up_count > 0"
            case .recentActivity:
                filterClause = """
                AND c.is_archived = 0
                AND c.last_activity_at >= strftime('%s','now') - 2592000
                """
            case .archived:
                filterClause = "AND c.is_archived = 1"
            }

            let archiveClause: String
            switch filter {
            case .archived, .recentActivity:
                archiveClause = ""
            default:
                archiveClause = "AND c.is_archived = 0"
            }

            if searchTerm == nil && filter != .recentActivity {
                let sql = """
                SELECT
                    \(Self.contactListColumns(activity: .derived))
                FROM contacts c
                WHERE 1 = 1
                \(archiveClause)
                \(filterClause)
                ORDER BY
                    CASE WHEN c.next_follow_up_at IS NULL THEN 1 ELSE 0 END,
                    c.next_follow_up_at ASC,
                    c.display_name COLLATE NOCASE ASC;
                """

                let statement = try prepare(sql)
                defer { sqlite3_finalize(statement) }
                return contactListItems(from: statement)
            }

            let searchClause: String
            if searchTerm == nil {
                searchClause = "1 = 1"
            } else {
                searchClause = "c.search_text LIKE ?"
            }

            let sql = """
            SELECT
                \(Self.contactListColumns(activity: .derived))
            FROM contacts c
            WHERE \(searchClause)
            \(archiveClause)
            \(filterClause)
            ORDER BY
                CASE
                    WHEN ? IS NULL THEN 0
                    WHEN c.display_name = ? COLLATE NOCASE THEN 0
                    WHEN c.display_name LIKE ? COLLATE NOCASE THEN 1
                    WHEN c.display_name LIKE ? COLLATE NOCASE THEN 2
                    WHEN c.organization_name LIKE ? COLLATE NOCASE THEN 3
                    WHEN c.job_title LIKE ? COLLATE NOCASE THEN 4
                    WHEN c.primary_email LIKE ? COLLATE NOCASE THEN 5
                    ELSE 6
                END,
                CASE WHEN c.next_follow_up_at IS NULL THEN 1 ELSE 0 END,
                c.next_follow_up_at ASC,
                c.last_activity_at DESC,
                c.display_name COLLATE NOCASE ASC;
            """

            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            if let likeValue {
                try bindText(likeValue, to: 1, in: statement)
                try bindText(searchTerm, to: 2, in: statement)
                try bindText(searchTerm, to: 3, in: statement)
                try bindText(prefixLikeValue, to: 4, in: statement)
                try bindText(wordPrefixLikeValue, to: 5, in: statement)
                try bindText(likeValue, to: 6, in: statement)
                try bindText(likeValue, to: 7, in: statement)
                try bindText(likeValue, to: 8, in: statement)
            } else {
                for index in 1...7 {
                    try bindText(nil, to: Int32(index), in: statement)
                }
            }

            var items: [ContactListItem] = []
            items = contactListItems(from: statement)
            return items
        }
    }

    nonisolated func fetchDuplicateGroups(search: String) throws -> [ContactDuplicateGroup] {
        try queue.sync {
            let searchTerm = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().nonEmpty
            var grouped: [String: (kind: DuplicateMatchKind, value: String, contacts: [ContactListItem])] = [:]

            try appendDuplicateGroups(
                kind: .phone,
                keyColumn: "phone_key",
                displayExpression: "COALESCE(primary_phone, '')",
                minimumKeyLength: 6,
                searchTerm: searchTerm,
                grouped: &grouped
            )
            try appendDuplicateGroups(
                kind: .email,
                keyColumn: "email_key",
                displayExpression: "LOWER(TRIM(COALESCE(primary_email, '')))",
                minimumKeyLength: 3,
                searchTerm: searchTerm,
                grouped: &grouped
            )
            try appendDuplicateGroups(
                kind: .name,
                keyColumn: "name_key",
                displayExpression: "TRIM(COALESCE(NULLIF(TRIM(given_name || ' ' || family_name), ''), display_name, ''))",
                minimumKeyLength: 3,
                searchTerm: searchTerm,
                grouped: &grouped
            )

            return grouped.values
                .map { ContactDuplicateGroup(kind: $0.kind, value: $0.value, contacts: $0.contacts) }
                .sorted { lhs, rhs in
                    if lhs.kind.rawValue != rhs.kind.rawValue {
                        return lhs.kind.rawValue < rhs.kind.rawValue
                    }
                    return lhs.value.localizedCaseInsensitiveCompare(rhs.value) == .orderedAscending
                }
        }
    }

    nonisolated func fetchMergeCandidates(contactIDs: [Int64]) throws -> [ContactMergeCandidate] {
        guard !contactIDs.isEmpty else { return [] }
        return try queue.sync {
            let placeholders = Array(repeating: "?", count: contactIDs.count).joined(separator: ",")
            let statement = try prepare("""
            SELECT id, apple_identifier, display_name, given_name, family_name,
                   organization_name, is_company, job_title, primary_email, primary_phone
            FROM contacts
            WHERE id IN (\(placeholders))
            ORDER BY display_name COLLATE NOCASE ASC;
            """)
            defer { sqlite3_finalize(statement) }
            for (index, contactID) in contactIDs.enumerated() {
                try bindInt64(contactID, to: Int32(index + 1), in: statement)
            }

            var candidates: [ContactMergeCandidate] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                candidates.append(
                    ContactMergeCandidate(
                        id: sqlite3_column_int64(statement, 0),
                        appleIdentifier: string(at: 1, in: statement),
                        displayName: string(at: 2, in: statement),
                        givenName: string(at: 3, in: statement),
                        familyName: string(at: 4, in: statement),
                        organizationName: string(at: 5, in: statement),
                        isCompany: sqlite3_column_int64(statement, 6) != 0,
                        jobTitle: string(at: 7, in: statement),
                        primaryEmail: optionalString(at: 8, in: statement),
                        primaryPhone: optionalString(at: 9, in: statement)
                    )
                )
            }
            return candidates
        }
    }

    private func appendDuplicateGroups(
        kind: DuplicateMatchKind,
        keyColumn: String,
        displayExpression: String,
        minimumKeyLength: Int,
        searchTerm: String?,
        grouped: inout [String: (kind: DuplicateMatchKind, value: String, contacts: [ContactListItem])]
    ) throws {
        let sql = """
        WITH duplicate_keys AS (
            SELECT \(keyColumn) AS duplicate_key
            FROM contacts
            WHERE is_archived = 0
              AND LENGTH(\(keyColumn)) >= ?
            GROUP BY duplicate_key
            HAVING COUNT(*) > 1
        )
        SELECT
            c.\(keyColumn) AS duplicate_key,
            \(displayExpression) AS duplicate_value,
            \(Self.contactListColumns(activity: .zero))
        FROM contacts c
        JOIN duplicate_keys dk ON dk.duplicate_key = c.\(keyColumn)
        WHERE c.is_archived = 0
        ORDER BY duplicate_key COLLATE NOCASE ASC, c.display_name COLLATE NOCASE ASC;
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(minimumKeyLength))

        while sqlite3_step(statement) == SQLITE_ROW {
            let key = string(at: 0, in: statement)
            let value = string(at: 1, in: statement).nonEmpty ?? key
            let item = contactListItem(from: statement, offset: 2)
            if let searchTerm, !searchableDuplicateFields(item, value: value).contains(where: { $0.contains(searchTerm) }) {
                continue
            }
            let groupKey = "\(kind.rawValue):\(key)"
            var group = grouped[groupKey] ?? (kind: kind, value: value, contacts: [])
            if !group.contacts.contains(where: { $0.id == item.id }) {
                group.contacts.append(item)
            }
            grouped[groupKey] = group
        }
    }

    private func searchableDuplicateFields(_ item: ContactListItem, value: String) -> [String] {
        [
            value,
            item.displayName,
            item.subtitle,
            item.primaryEmail ?? "",
            item.primaryPhone ?? ""
        ].map { $0.lowercased() }
    }

    private static func contactListColumns(activity: ContactListActivitySQL) -> String {
        let activityColumns: String
        switch activity {
        case .derived:
            activityColumns = """
            c.last_activity_at,
            c.next_follow_up_at,
            c.open_follow_up_count
            """
        case .zero:
            activityColumns = """
            0 AS last_activity_at,
            NULL AS next_follow_up_at,
            0 AS open_follow_up_count
            """
        }

        return """
        c.id,
        c.apple_identifier,
        c.display_name,
        COALESCE(NULLIF(TRIM(c.job_title || CASE
            WHEN c.job_title != '' AND c.organization_name != '' THEN ' at '
            ELSE ''
        END || c.organization_name), ''), '') AS subtitle,
        c.primary_email,
        c.primary_phone,
        c.city,
        c.country,
        \(activityColumns),
        c.verification_status,
        CASE
            WHEN c.enriched_image_data IS NOT NULL OR c.image_data IS NOT NULL THEN 1
            ELSE 0
        END AS has_any_image,
        c.is_archived
        """
    }

    private func contactListItems(from statement: OpaquePointer?) -> [ContactListItem] {
        var items: [ContactListItem] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            items.append(contactListItem(from: statement, offset: 0))
        }
        return items
    }

    private func contactListItem(from statement: OpaquePointer?, offset: Int32) -> ContactListItem {
        let lastActivityAt = optionalDate(at: offset + 8, in: statement).flatMap {
            $0.timeIntervalSince1970 > 0 ? $0 : nil
        }
        return ContactListItem(
            id: sqlite3_column_int64(statement, offset + 0),
            appleIdentifier: string(at: offset + 1, in: statement),
            displayName: string(at: offset + 2, in: statement),
            subtitle: string(at: offset + 3, in: statement),
            primaryEmail: optionalString(at: offset + 4, in: statement),
            primaryPhone: optionalString(at: offset + 5, in: statement),
            city: optionalString(at: offset + 6, in: statement),
            country: optionalString(at: offset + 7, in: statement),
            lastActivityAt: lastActivityAt,
            nextFollowUpAt: optionalDate(at: offset + 9, in: statement),
            openFollowUpCount: Int(sqlite3_column_int64(statement, offset + 10)),
            verificationStatus: ContactVerificationStatus(rawValue: string(at: offset + 11, in: statement)) ?? .unverified,
            hasAnyImage: sqlite3_column_int64(statement, offset + 12) != 0,
            isArchived: sqlite3_column_int64(statement, offset + 13) != 0
        )
    }

    nonisolated func fetchContactBundle(contactID: Int64) throws -> OrbitContactBundle? {
        try queue.sync {
            guard let core = try fetchContactCore(contactID: contactID) else {
                return nil
            }

            return OrbitContactBundle(
                id: contactID,
                core: core,
                notes: try fetchNotes(contactID: contactID),
                insights: try fetchInsights(contactID: contactID),
                followUps: try fetchFollowUps(contactID: contactID)
            )
        }
    }

    nonisolated func addNote(contactID: Int64, body: String, source: NoteSource) throws {
        try queue.sync {
            let sql = """
            INSERT INTO notes (contact_id, body, source, created_at)
            VALUES (?, ?, ?, ?);
            """
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            try bindInt64(contactID, to: 1, in: statement)
            try bindText(body, to: 2, in: statement)
            try bindText(source.rawValue, to: 3, in: statement)
            sqlite3_bind_double(statement, 4, Date().timeIntervalSince1970)
            try stepDone(statement)
            try refreshContactDerivedFields(contactID: contactID)
        }
    }

    nonisolated func upsertInsight(
        contactID: Int64,
        insightID: Int64?,
        body: String,
        kind: InsightKind,
        source: InsightSource
    ) throws {
        try queue.sync {
            if let insightID {
                let sql = """
                UPDATE insights
                SET body = ?, kind = ?, source = ?, updated_at = ?
                WHERE id = ? AND contact_id = ?;
                """
                let statement = try prepare(sql)
                defer { sqlite3_finalize(statement) }
                try bindText(body, to: 1, in: statement)
                try bindText(kind.rawValue, to: 2, in: statement)
                try bindText(source.rawValue, to: 3, in: statement)
                sqlite3_bind_double(statement, 4, Date().timeIntervalSince1970)
                try bindInt64(insightID, to: 5, in: statement)
                try bindInt64(contactID, to: 6, in: statement)
                try stepDone(statement)
                try refreshContactDerivedFields(contactID: contactID)
            } else {
                let sql = """
                INSERT INTO insights (contact_id, body, kind, source, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?);
                """
                let statement = try prepare(sql)
                defer { sqlite3_finalize(statement) }
                try bindInt64(contactID, to: 1, in: statement)
                try bindText(body, to: 2, in: statement)
                try bindText(kind.rawValue, to: 3, in: statement)
                try bindText(source.rawValue, to: 4, in: statement)
                let now = Date().timeIntervalSince1970
                sqlite3_bind_double(statement, 5, now)
                sqlite3_bind_double(statement, 6, now)
                try stepDone(statement)
                try refreshContactDerivedFields(contactID: contactID)
            }
        }
    }

    nonisolated func deleteInsight(id: Int64) throws {
        try queue.sync {
            let contactID = try contactID(forRowID: id, in: "insights")
            let statement = try prepare("DELETE FROM insights WHERE id = ?;")
            defer { sqlite3_finalize(statement) }
            try bindInt64(id, to: 1, in: statement)
            try stepDone(statement)
            if let contactID {
                try refreshContactDerivedFields(contactID: contactID)
            }
        }
    }

    nonisolated func upsertFollowUp(
        contactID: Int64,
        followUpID: Int64?,
        title: String,
        note: String,
        dueAt: Date?,
        source: FollowUpSource
    ) throws {
        try queue.sync {
            if let followUpID {
                let sql = """
                UPDATE follow_ups
                SET title = ?, note = ?, due_at = ?, source = ?, completed_at = NULL
                WHERE id = ? AND contact_id = ?;
                """
                let statement = try prepare(sql)
                defer { sqlite3_finalize(statement) }
                try bindText(title, to: 1, in: statement)
                try bindText(note.nonEmpty, to: 2, in: statement)
                if let dueAt {
                    sqlite3_bind_double(statement, 3, dueAt.timeIntervalSince1970)
                } else {
                    sqlite3_bind_null(statement, 3)
                }
                try bindText(source.rawValue, to: 4, in: statement)
                try bindInt64(followUpID, to: 5, in: statement)
                try bindInt64(contactID, to: 6, in: statement)
                try stepDone(statement)
                try refreshContactDerivedFields(contactID: contactID)
            } else {
                let sql = """
                INSERT INTO follow_ups (contact_id, title, note, due_at, source, created_at)
                VALUES (?, ?, ?, ?, ?, ?);
                """
                let statement = try prepare(sql)
                defer { sqlite3_finalize(statement) }
                try bindInt64(contactID, to: 1, in: statement)
                try bindText(title, to: 2, in: statement)
                try bindText(note.nonEmpty, to: 3, in: statement)
                if let dueAt {
                    sqlite3_bind_double(statement, 4, dueAt.timeIntervalSince1970)
                } else {
                    sqlite3_bind_null(statement, 4)
                }
                try bindText(source.rawValue, to: 5, in: statement)
                sqlite3_bind_double(statement, 6, Date().timeIntervalSince1970)
                try stepDone(statement)
                try refreshContactDerivedFields(contactID: contactID)
            }
        }
    }

    nonisolated func completeFollowUp(id: Int64) throws {
        try queue.sync {
            let contactID = try contactID(forRowID: id, in: "follow_ups")
            let statement = try prepare("UPDATE follow_ups SET completed_at = ? WHERE id = ?;")
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_double(statement, 1, Date().timeIntervalSince1970)
            try bindInt64(id, to: 2, in: statement)
            try stepDone(statement)
            if let contactID {
                try refreshContactDerivedFields(contactID: contactID)
            }
        }
    }

    nonisolated func contactPayload(contactID: Int64) throws -> [String: Any]? {
        try queue.sync {
            guard let core = try fetchContactCore(contactID: contactID) else { return nil }
            let notes = try fetchNotes(contactID: contactID)
            let insights = try fetchInsights(contactID: contactID)
            let followUps = try fetchFollowUps(contactID: contactID)
            let formatter = ISO8601DateFormatter()

            return [
                "today": formatter.string(from: .now),
                "contact": [
                    "id": core.id,
                    "display_name": core.displayName,
                    "organization_name": core.organizationName,
                    "job_title": core.jobTitle,
                    "primary_email": jsonValue(core.primaryEmail),
                    "primary_phone": jsonValue(core.primaryPhone),
                    "verified_phone_e164": jsonValue(core.verifiedPhoneE164),
                    "verification_status": core.verificationStatus.rawValue,
                    "verified_display_name": jsonValue(core.verifiedDisplayName),
                    "verification_note": core.verificationNote,
                    "verified_at": jsonValue(core.verifiedAt.map { formatter.string(from: $0) }),
                    "is_archived": core.isArchived,
                    "archived_at": jsonValue(core.archivedAt.map { formatter.string(from: $0) }),
                    "city": jsonValue(core.city),
                    "country": jsonValue(core.country)
                ],
                "notes": notes.map {
                    [
                        "id": $0.id,
                        "body": $0.body,
                        "source": $0.source.rawValue,
                        "created_at": formatter.string(from: $0.createdAt)
                    ]
                },
                "insights": insights.map {
                    [
                        "id": $0.id,
                        "body": $0.body,
                        "kind": $0.kind.rawValue,
                        "source": $0.source.rawValue,
                        "created_at": formatter.string(from: $0.createdAt),
                        "updated_at": formatter.string(from: $0.updatedAt)
                    ]
                },
                "follow_ups": followUps.map {
                    [
                        "id": $0.id,
                        "title": $0.title,
                        "note": $0.note,
                        "source": $0.source.rawValue,
                        "due_at": jsonValue($0.dueAt.map { formatter.string(from: $0) }),
                        "completed_at": jsonValue($0.completedAt.map { formatter.string(from: $0) }),
                        "created_at": formatter.string(from: $0.createdAt)
                    ]
                }
            ]
        }
    }

    nonisolated func pendingFollowUpsPayload() throws -> [[String: Any]] {
        try queue.sync {
            let sql = """
            SELECT f.id, f.contact_id, c.display_name, f.title, f.note, f.source, f.due_at, f.created_at
            FROM follow_ups f
            JOIN contacts c ON c.id = f.contact_id
            WHERE f.completed_at IS NULL
              AND c.is_archived = 0
            ORDER BY
                CASE WHEN f.due_at IS NULL THEN 1 ELSE 0 END,
                f.due_at ASC,
                f.created_at DESC;
            """
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            let formatter = ISO8601DateFormatter()
            var items: [[String: Any]] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                items.append([
                    "id": sqlite3_column_int64(statement, 0),
                    "contact_id": sqlite3_column_int64(statement, 1),
                    "contact_name": string(at: 2, in: statement),
                    "title": string(at: 3, in: statement),
                    "note": optionalString(at: 4, in: statement) ?? "",
                    "source": string(at: 5, in: statement),
                    "due_at": jsonValue(optionalDate(at: 6, in: statement).map { formatter.string(from: $0) }),
                    "created_at": jsonValue(optionalDate(at: 7, in: statement).map { formatter.string(from: $0) })
                ])
            }
            return items
        }
    }

    private func fetchContactCore(contactID: Int64) throws -> ContactCore? {
        let sql = """
        SELECT id, apple_identifier, given_name, family_name, display_name, organization_name,
               is_company, job_title, primary_email, primary_phone, city, country, birthday_year,
               birthday_month, birthday_day, image_data, enriched_image_data,
               enriched_image_source, verified_display_name, verified_phone_e164,
               verification_status, verification_note, verified_at, last_synced_at,
               is_archived, archived_at
        FROM contacts
        WHERE id = ?;
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bindInt64(contactID, to: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }

        let year = optionalInt(at: 12, in: statement)
        let month = optionalInt(at: 13, in: statement)
        let day = optionalInt(at: 14, in: statement)
        let birthday: DateComponents? =
            year == nil && month == nil && day == nil ? nil :
            DateComponents(year: year, month: month, day: day)

        return ContactCore(
            id: sqlite3_column_int64(statement, 0),
            appleIdentifier: string(at: 1, in: statement),
            givenName: string(at: 2, in: statement),
            familyName: string(at: 3, in: statement),
            displayName: string(at: 4, in: statement),
            organizationName: string(at: 5, in: statement),
            isCompany: sqlite3_column_int64(statement, 6) != 0,
            jobTitle: string(at: 7, in: statement),
            primaryEmail: optionalString(at: 8, in: statement),
            primaryPhone: optionalString(at: 9, in: statement),
            city: optionalString(at: 10, in: statement),
            country: optionalString(at: 11, in: statement),
            birthday: birthday,
            contactImageData: optionalData(at: 15, in: statement),
            enrichedImageData: optionalData(at: 16, in: statement),
            enrichedImageSource: optionalString(at: 17, in: statement),
            verifiedDisplayName: optionalString(at: 18, in: statement),
            verifiedPhoneE164: optionalString(at: 19, in: statement),
            verificationStatus: ContactVerificationStatus(rawValue: string(at: 20, in: statement)) ?? .unverified,
            verificationNote: optionalString(at: 21, in: statement) ?? "",
            verifiedAt: optionalDate(at: 22, in: statement),
            lastSyncedAt: optionalDate(at: 23, in: statement) ?? .now,
            isArchived: sqlite3_column_int64(statement, 24) != 0,
            archivedAt: optionalDate(at: 25, in: statement)
        )
    }

    private func fetchNotes(contactID: Int64) throws -> [OrbitNote] {
        let statement = try prepare("""
        SELECT id, contact_id, body, source, created_at
        FROM notes
        WHERE contact_id = ?
        ORDER BY created_at DESC, id DESC;
        """)
        defer { sqlite3_finalize(statement) }
        try bindInt64(contactID, to: 1, in: statement)

        var notes: [OrbitNote] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            notes.append(
                OrbitNote(
                    id: sqlite3_column_int64(statement, 0),
                    contactID: sqlite3_column_int64(statement, 1),
                    body: string(at: 2, in: statement),
                    source: NoteSource(rawValue: string(at: 3, in: statement)) ?? .manual,
                    createdAt: optionalDate(at: 4, in: statement) ?? .now
                )
            )
        }
        return notes
    }

    private func fetchInsights(contactID: Int64) throws -> [Insight] {
        let statement = try prepare("""
        SELECT id, contact_id, body, kind, source, created_at, updated_at
        FROM insights
        WHERE contact_id = ?
        ORDER BY updated_at DESC, id DESC;
        """)
        defer { sqlite3_finalize(statement) }
        try bindInt64(contactID, to: 1, in: statement)

        var insights: [Insight] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            insights.append(
                Insight(
                    id: sqlite3_column_int64(statement, 0),
                    contactID: sqlite3_column_int64(statement, 1),
                    body: string(at: 2, in: statement),
                    kind: InsightKind(rawValue: string(at: 3, in: statement)) ?? .general,
                    source: InsightSource(rawValue: string(at: 4, in: statement)) ?? .agent,
                    createdAt: optionalDate(at: 5, in: statement) ?? .now,
                    updatedAt: optionalDate(at: 6, in: statement) ?? .now
                )
            )
        }
        return insights
    }

    private func fetchFollowUps(contactID: Int64) throws -> [FollowUpItem] {
        let statement = try prepare("""
        SELECT id, contact_id, title, note, due_at, source, created_at, completed_at
        FROM follow_ups
        WHERE contact_id = ?
        ORDER BY
            CASE WHEN completed_at IS NULL THEN 0 ELSE 1 END,
            due_at ASC,
            created_at DESC;
        """)
        defer { sqlite3_finalize(statement) }
        try bindInt64(contactID, to: 1, in: statement)

        var items: [FollowUpItem] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            items.append(
                FollowUpItem(
                    id: sqlite3_column_int64(statement, 0),
                    contactID: sqlite3_column_int64(statement, 1),
                    title: string(at: 2, in: statement),
                    note: optionalString(at: 3, in: statement) ?? "",
                    dueAt: optionalDate(at: 4, in: statement),
                    source: FollowUpSource(rawValue: string(at: 5, in: statement)) ?? .agent,
                    createdAt: optionalDate(at: 6, in: statement) ?? .now,
                    completedAt: optionalDate(at: 7, in: statement)
                )
            )
        }
        return items
    }

    private static let contactUpsertSQL = """
        INSERT INTO contacts (
            apple_identifier, given_name, family_name, display_name,
            organization_name, is_company, job_title, primary_email, primary_phone,
            city, country, birthday_year, birthday_month, birthday_day,
            image_data, last_synced_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(apple_identifier) DO UPDATE SET
            given_name = excluded.given_name,
            family_name = excluded.family_name,
            display_name = excluded.display_name,
            organization_name = excluded.organization_name,
            is_company = excluded.is_company,
            job_title = excluded.job_title,
            primary_email = excluded.primary_email,
            primary_phone = excluded.primary_phone,
            city = excluded.city,
            country = excluded.country,
            birthday_year = excluded.birthday_year,
            birthday_month = excluded.birthday_month,
            birthday_day = excluded.birthday_day,
            image_data = excluded.image_data,
        last_synced_at = excluded.last_synced_at;
        """

    private static let indexMigrations = [
        "CREATE INDEX IF NOT EXISTS idx_contacts_display_name ON contacts(display_name);",
        "CREATE INDEX IF NOT EXISTS idx_contacts_verification_status ON contacts(verification_status);",
        "CREATE INDEX IF NOT EXISTS idx_contacts_is_archived ON contacts(is_archived);",
        "CREATE INDEX IF NOT EXISTS idx_contacts_archived_follow_up ON contacts(is_archived, next_follow_up_at, display_name);",
        "CREATE INDEX IF NOT EXISTS idx_contacts_archived_activity ON contacts(is_archived, last_activity_at DESC);",
        "CREATE INDEX IF NOT EXISTS idx_contacts_phone_key ON contacts(phone_key);",
        "CREATE INDEX IF NOT EXISTS idx_contacts_email_key ON contacts(email_key);",
        "CREATE INDEX IF NOT EXISTS idx_contacts_name_key ON contacts(name_key);",
        "CREATE INDEX IF NOT EXISTS idx_notes_contact_id_created_at ON notes(contact_id, created_at DESC);",
        "CREATE INDEX IF NOT EXISTS idx_insights_contact_id_updated_at ON insights(contact_id, updated_at DESC);",
        "CREATE INDEX IF NOT EXISTS idx_follow_ups_contact_id_due_at ON follow_ups(contact_id, due_at);",
        "CREATE INDEX IF NOT EXISTS idx_follow_ups_completed_due ON follow_ups(completed_at, due_at, created_at DESC);"
    ]

    private func upsert(snapshot: ContactSyncSnapshot, statement: OpaquePointer?) throws {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        try bindText(snapshot.identifier, to: 1, in: statement)
        try bindText(snapshot.givenName, to: 2, in: statement)
        try bindText(snapshot.familyName, to: 3, in: statement)
        try bindText(snapshot.displayName.nonEmpty ?? snapshot.organizationName.nonEmpty ?? "Unknown Contact", to: 4, in: statement)
        try bindText(snapshot.organizationName, to: 5, in: statement)
        sqlite3_bind_int(statement, 6, snapshot.isCompany ? 1 : 0)
        try bindText(snapshot.jobTitle, to: 7, in: statement)
        try bindText(snapshot.primaryEmail, to: 8, in: statement)
        try bindText(snapshot.primaryPhone, to: 9, in: statement)
        try bindText(snapshot.city, to: 10, in: statement)
        try bindText(snapshot.country, to: 11, in: statement)
        if let birthday = snapshot.birthday?.year { sqlite3_bind_int(statement, 12, Int32(birthday)) } else { sqlite3_bind_null(statement, 12) }
        if let birthday = snapshot.birthday?.month { sqlite3_bind_int(statement, 13, Int32(birthday)) } else { sqlite3_bind_null(statement, 13) }
        if let birthday = snapshot.birthday?.day { sqlite3_bind_int(statement, 14, Int32(birthday)) } else { sqlite3_bind_null(statement, 14) }
        if let data = snapshot.imageData {
            _ = data.withUnsafeBytes { rawBuffer in
                sqlite3_bind_blob(statement, 15, rawBuffer.baseAddress, Int32(rawBuffer.count), SQLITE_TRANSIENT)
            }
        } else {
            sqlite3_bind_null(statement, 15)
        }
        sqlite3_bind_double(statement, 16, Date().timeIntervalSince1970)
        try stepDone(statement)
    }

    nonisolated func updateVerificationStatus(
        contactID: Int64,
        status: ContactVerificationStatus,
        verifiedPhoneE164: String?,
        note: String,
        verifiedAt: Date?
    ) throws {
        try queue.sync {
            let statement = try prepare("""
            UPDATE contacts
            SET verification_status = ?,
                verified_display_name = ?,
                verified_phone_e164 = ?,
                verification_note = ?,
                verified_at = ?
            WHERE id = ?;
            """)
            defer { sqlite3_finalize(statement) }
            try bindText(status.rawValue, to: 1, in: statement)
            sqlite3_bind_null(statement, 2)
            try bindText(verifiedPhoneE164?.nonEmpty, to: 3, in: statement)
            try bindText(note, to: 4, in: statement)
            if let verifiedAt {
                sqlite3_bind_double(statement, 5, verifiedAt.timeIntervalSince1970)
            } else {
                sqlite3_bind_null(statement, 5)
            }
            try bindInt64(contactID, to: 6, in: statement)
            try stepDone(statement)
            try refreshContactDerivedFields(contactID: contactID)
        }
    }

    nonisolated func updateContactIdentity(contactID: Int64, identity: AppleContactIdentityDraft) throws {
        try queue.sync {
            let identity = identity.trimmed
            let statement = try prepare("""
            UPDATE contacts
            SET given_name = ?,
                family_name = ?,
                display_name = ?,
                organization_name = ?,
                is_company = ?,
                last_synced_at = ?
            WHERE id = ?;
            """)
            defer { sqlite3_finalize(statement) }
            try bindText(identity.givenName, to: 1, in: statement)
            try bindText(identity.familyName, to: 2, in: statement)
            try bindText(identity.displayName, to: 3, in: statement)
            try bindText(identity.organizationName, to: 4, in: statement)
            sqlite3_bind_int(statement, 5, identity.isCompany ? 1 : 0)
            sqlite3_bind_double(statement, 6, Date().timeIntervalSince1970)
            try bindInt64(contactID, to: 7, in: statement)
            try stepDone(statement)
            try refreshContactDerivedFields(contactID: contactID)
        }
    }

    nonisolated func updateMergedContactSummary(contactID: Int64, resolution: ContactMergeResolution) throws {
        try queue.sync {
            let identity = resolution.identity.trimmed
            let statement = try prepare("""
            UPDATE contacts
            SET given_name = ?,
                family_name = ?,
                display_name = ?,
                organization_name = ?,
                is_company = ?,
                job_title = ?,
                primary_email = ?,
                primary_phone = ?,
                last_synced_at = ?
            WHERE id = ?;
            """)
            defer { sqlite3_finalize(statement) }
            try bindText(identity.givenName, to: 1, in: statement)
            try bindText(identity.familyName, to: 2, in: statement)
            try bindText(identity.displayName, to: 3, in: statement)
            try bindText(identity.organizationName, to: 4, in: statement)
            sqlite3_bind_int(statement, 5, identity.isCompany ? 1 : 0)
            try bindText(resolution.jobTitle, to: 6, in: statement)
            try bindText(resolution.primaryEmail, to: 7, in: statement)
            try bindText(resolution.primaryPhone, to: 8, in: statement)
            sqlite3_bind_double(statement, 9, Date().timeIntervalSince1970)
            try bindInt64(contactID, to: 10, in: statement)
            try stepDone(statement)
            try refreshContactDerivedFields(contactID: contactID)
        }
    }

    nonisolated func updateReverseEnrichmentDump(
        contactID: Int64,
        rawJSON: String,
        statusCode: Int,
        dumpedAt: Date
    ) throws {
        try queue.sync {
            let statement = try prepare("""
            UPDATE contacts
            SET reverse_enrichment_dump_json = ?,
                reverse_enrichment_dump_status = ?,
                reverse_enrichment_dumped_at = ?
            WHERE id = ?;
            """)
            defer { sqlite3_finalize(statement) }
            try bindText(rawJSON, to: 1, in: statement)
            sqlite3_bind_int(statement, 2, Int32(statusCode))
            sqlite3_bind_double(statement, 3, dumpedAt.timeIntervalSince1970)
            try bindInt64(contactID, to: 4, in: statement)
            try stepDone(statement)
        }
    }

    nonisolated func mergeLocalContactData(sourceContactIDs: [Int64], targetContactID: Int64) throws {
        guard !sourceContactIDs.isEmpty else { return }
        try queue.sync {
            try execute("BEGIN IMMEDIATE TRANSACTION;")
            do {
                for sourceContactID in sourceContactIDs where sourceContactID != targetContactID {
                    try reassignContactRows(table: "notes", sourceContactID: sourceContactID, targetContactID: targetContactID)
                    try reassignContactRows(table: "insights", sourceContactID: sourceContactID, targetContactID: targetContactID)
                    try reassignContactRows(table: "follow_ups", sourceContactID: sourceContactID, targetContactID: targetContactID)

                    let statement = try prepare("""
                    UPDATE contacts
                    SET is_archived = 1,
                        archived_at = ?
                    WHERE id = ?;
                    """)
                    defer { sqlite3_finalize(statement) }
                    sqlite3_bind_double(statement, 1, Date().timeIntervalSince1970)
                    try bindInt64(sourceContactID, to: 2, in: statement)
                    try stepDone(statement)
                    try refreshContactDerivedFields(contactID: sourceContactID)
                }
                try refreshContactDerivedFields(contactID: targetContactID)
                try execute("COMMIT;")
            } catch {
                try? execute("ROLLBACK;")
                throw error
            }
        }
    }

    private func reassignContactRows(table: String, sourceContactID: Int64, targetContactID: Int64) throws {
        let statement = try prepare("""
        UPDATE \(table)
        SET contact_id = ?
        WHERE contact_id = ?;
        """)
        defer { sqlite3_finalize(statement) }
        try bindInt64(targetContactID, to: 1, in: statement)
        try bindInt64(sourceContactID, to: 2, in: statement)
        try stepDone(statement)
    }

    nonisolated func updateEnrichedImage(contactID: Int64, imageData: Data, source: String) throws {
        try queue.sync {
            let statement = try prepare("""
            UPDATE contacts
            SET enriched_image_data = ?,
                enriched_image_source = ?,
                verification_status = CASE
                    WHEN verification_status = 'unverified' THEN 'pending_review'
                    ELSE verification_status
                END
            WHERE id = ?;
            """)
            defer { sqlite3_finalize(statement) }
            _ = imageData.withUnsafeBytes { rawBuffer in
                sqlite3_bind_blob(statement, 1, rawBuffer.baseAddress, Int32(rawBuffer.count), SQLITE_TRANSIENT)
            }
            try bindText(source, to: 2, in: statement)
            try bindInt64(contactID, to: 3, in: statement)
            try stepDone(statement)
            try refreshContactDerivedFields(contactID: contactID)
        }
    }

    nonisolated func setContactArchived(contactID: Int64, isArchived: Bool) throws {
        try queue.sync {
            let statement = try prepare("""
            UPDATE contacts
            SET is_archived = ?,
                archived_at = ?
            WHERE id = ?;
            """)
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int(statement, 1, isArchived ? 1 : 0)
            if isArchived {
                sqlite3_bind_double(statement, 2, Date().timeIntervalSince1970)
            } else {
                sqlite3_bind_null(statement, 2)
            }
            try bindInt64(contactID, to: 3, in: statement)
            try stepDone(statement)
            try refreshContactDerivedFields(contactID: contactID)
        }
    }

    private func migrate() throws {
        let schemaVersion = try currentSchemaVersion()
        if schemaVersion > 0 && schemaVersion < Self.currentSchemaVersion {
            try resetDatabaseForLatestSchema()
        }

        try execute("""
        CREATE TABLE IF NOT EXISTS contacts (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            apple_identifier TEXT NOT NULL UNIQUE,
            given_name TEXT NOT NULL DEFAULT '',
            family_name TEXT NOT NULL DEFAULT '',
            display_name TEXT NOT NULL DEFAULT '',
            organization_name TEXT NOT NULL DEFAULT '',
            is_company INTEGER NOT NULL DEFAULT 0,
            job_title TEXT NOT NULL DEFAULT '',
            primary_email TEXT,
            primary_phone TEXT,
            city TEXT,
            country TEXT,
            birthday_year INTEGER,
            birthday_month INTEGER,
            birthday_day INTEGER,
            image_data BLOB,
            enriched_image_data BLOB,
            enriched_image_source TEXT,
            verified_display_name TEXT,
            verified_phone_e164 TEXT,
            reverse_enrichment_dump_json TEXT,
            reverse_enrichment_dump_status INTEGER,
            reverse_enrichment_dumped_at REAL,
            verification_status TEXT NOT NULL DEFAULT 'unverified',
            verification_note TEXT NOT NULL DEFAULT '',
            verified_at REAL,
            is_archived INTEGER NOT NULL DEFAULT 0,
            archived_at REAL,
            search_text TEXT NOT NULL DEFAULT '',
            email_key TEXT NOT NULL DEFAULT '',
            phone_key TEXT NOT NULL DEFAULT '',
            name_key TEXT NOT NULL DEFAULT '',
            last_activity_at REAL NOT NULL DEFAULT 0,
            next_follow_up_at REAL,
            open_follow_up_count INTEGER NOT NULL DEFAULT 0,
            last_synced_at REAL NOT NULL
        );
        """)

        try execute("""
        CREATE TABLE IF NOT EXISTS notes (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            contact_id INTEGER NOT NULL REFERENCES contacts(id) ON DELETE CASCADE,
            body TEXT NOT NULL,
            source TEXT NOT NULL,
            created_at REAL NOT NULL
        );
        """)

        try execute("""
        CREATE TABLE IF NOT EXISTS insights (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            contact_id INTEGER NOT NULL REFERENCES contacts(id) ON DELETE CASCADE,
            body TEXT NOT NULL,
            kind TEXT NOT NULL,
            source TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        """)

        try execute("""
        CREATE TABLE IF NOT EXISTS follow_ups (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            contact_id INTEGER NOT NULL REFERENCES contacts(id) ON DELETE CASCADE,
            title TEXT NOT NULL,
            note TEXT,
            due_at REAL,
            source TEXT NOT NULL,
            created_at REAL NOT NULL,
            completed_at REAL
        );
        """)

        for indexSQL in Self.indexMigrations {
            try execute(indexSQL)
        }

        try execute("PRAGMA user_version = \(Self.currentSchemaVersion);")
    }

    private func resetDatabaseForLatestSchema() throws {
        try execute("DROP TABLE IF EXISTS notes;")
        try execute("DROP TABLE IF EXISTS insights;")
        try execute("DROP TABLE IF EXISTS follow_ups;")
        try execute("DROP TABLE IF EXISTS contacts;")
        try execute("DROP TABLE IF EXISTS derived_facts;")
        try execute("DROP TABLE IF EXISTS context_entries;")
        try execute("PRAGMA user_version = 0;")
    }

    private func rebuildContactDerivedFields() throws {
        let statement = try prepare("SELECT id FROM contacts;")
        defer { sqlite3_finalize(statement) }
        var contactIDs: [Int64] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            contactIDs.append(sqlite3_column_int64(statement, 0))
        }
        for contactID in contactIDs {
            try refreshContactDerivedFields(contactID: contactID)
        }
    }

    private func refreshContactDerivedFields(contactID: Int64) throws {
        let statement = try prepare("""
        UPDATE contacts
        SET
            email_key = LOWER(TRIM(COALESCE(primary_email, ''))),
            phone_key = REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(LOWER(COALESCE(primary_phone, '')), ' ', ''), '-', ''), '.', ''), '(', ''), ')', ''), '+', ''),
            name_key = LOWER(TRIM(COALESCE(NULLIF(TRIM(given_name || ' ' || family_name), ''), display_name, ''))),
            search_text = LOWER(TRIM(
                COALESCE(display_name, '') || ' ' ||
                COALESCE(given_name, '') || ' ' ||
                COALESCE(family_name, '') || ' ' ||
                COALESCE(organization_name, '') || ' ' ||
                COALESCE(job_title, '') || ' ' ||
                COALESCE(primary_email, '') || ' ' ||
                COALESCE(primary_phone, '') || ' ' ||
                COALESCE(city, '') || ' ' ||
                COALESCE(country, '') || ' ' ||
                COALESCE((SELECT GROUP_CONCAT(body, ' ') FROM notes WHERE contact_id = contacts.id), '') || ' ' ||
                COALESCE((SELECT GROUP_CONCAT(body, ' ') FROM insights WHERE contact_id = contacts.id), '')
            )),
            last_activity_at = MAX(
                COALESCE((SELECT MAX(created_at) FROM notes WHERE contact_id = contacts.id), 0),
                COALESCE((SELECT MAX(updated_at) FROM insights WHERE contact_id = contacts.id), 0),
                COALESCE((SELECT MAX(created_at) FROM follow_ups WHERE contact_id = contacts.id), 0)
            ),
            next_follow_up_at = (
                SELECT MIN(due_at)
                FROM follow_ups
                WHERE contact_id = contacts.id AND completed_at IS NULL
            ),
            open_follow_up_count = (
                SELECT COUNT(*)
                FROM follow_ups
                WHERE contact_id = contacts.id AND completed_at IS NULL
            )
        WHERE id = ?;
        """)
        defer { sqlite3_finalize(statement) }
        try bindInt64(contactID, to: 1, in: statement)
        try stepDone(statement)
    }

    private func contactID(forRowID rowID: Int64, in table: String) throws -> Int64? {
        let statement = try prepare("SELECT contact_id FROM \(table) WHERE id = ?;")
        defer { sqlite3_finalize(statement) }
        try bindInt64(rowID, to: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(statement, 0)
    }

    private func currentSchemaVersion() throws -> Int {
        let statement = try prepare("PRAGMA user_version;")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(statement, 0))
    }

    private func execute(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<Int8>?
        if sqlite3_exec(db, sql, nil, nil, &errorMessage) != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? "SQLite execution failed"
            sqlite3_free(errorMessage)
            throw OrbitDatabaseError.stepFailed(message)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) != SQLITE_OK {
            throw OrbitDatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        return statement
    }

    private func stepDone(_ statement: OpaquePointer?) throws {
        if sqlite3_step(statement) != SQLITE_DONE {
            throw OrbitDatabaseError.stepFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func bindText(_ value: String?, to index: Int32, in statement: OpaquePointer?) throws {
        guard let value else {
            sqlite3_bind_null(statement, index)
            return
        }
        if sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT) != SQLITE_OK {
            throw OrbitDatabaseError.bindFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func bindInt64(_ value: Int64, to index: Int32, in statement: OpaquePointer?) throws {
        if sqlite3_bind_int64(statement, index, value) != SQLITE_OK {
            throw OrbitDatabaseError.bindFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func string(at index: Int32, in statement: OpaquePointer?) -> String {
        guard let pointer = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: pointer)
    }

    private func optionalString(at index: Int32, in statement: OpaquePointer?) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return string(at: index, in: statement)
    }

    private func optionalInt(at index: Int32, in statement: OpaquePointer?) -> Int? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int(statement, index))
    }

    private func optionalDate(at index: Int32, in statement: OpaquePointer?) -> Date? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(statement, index))
    }

    private func optionalData(at index: Int32, in statement: OpaquePointer?) -> Data? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let bytes = sqlite3_column_blob(statement, index) else {
            return nil
        }
        let length = Int(sqlite3_column_bytes(statement, index))
        return Data(bytes: bytes, count: length)
    }

    private func jsonValue(_ value: Any?) -> Any {
        value ?? NSNull()
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
