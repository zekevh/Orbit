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
    private let db: OpaquePointer
    private let queue = DispatchQueue(label: "io.zvh.orbit.database")

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
                for snapshot in snapshots {
                    try upsert(snapshot: snapshot)
                }
                try execute("COMMIT;")
            } catch {
                try? execute("ROLLBACK;")
                throw error
            }
        }
    }

    nonisolated func fetchContacts(filter: SidebarFilter, search: String) throws -> [ContactListItem] {
        try queue.sync {
            let likeValue = search.nonEmpty.map { "%\($0)%" } ?? "%"
            let filterClause: String
            switch filter {
            case .allContacts:
                filterClause = ""
            case .needsFollowUp:
                filterClause = """
                AND EXISTS (
                    SELECT 1 FROM follow_ups f
                    WHERE f.contact_id = c.id AND f.completed_at IS NULL
                )
                """
            case .recentActivity:
                filterClause = """
                AND EXISTS (
                    SELECT 1 FROM context_entries e
                    WHERE e.contact_id = c.id
                      AND e.created_at >= strftime('%s','now') - 2592000
                )
                """
            }

            let sql = """
            SELECT
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
                (
                    SELECT MAX(e.created_at)
                    FROM context_entries e
                    WHERE e.contact_id = c.id
                ) AS last_context_at,
                (
                    SELECT MIN(f.due_at)
                    FROM follow_ups f
                    WHERE f.contact_id = c.id
                      AND f.completed_at IS NULL
                ) AS next_follow_up_at,
                (
                    SELECT COUNT(*)
                    FROM follow_ups f
                    WHERE f.contact_id = c.id
                      AND f.completed_at IS NULL
                ) AS open_follow_up_count
            FROM contacts c
            WHERE (
                c.display_name LIKE ? COLLATE NOCASE
                OR c.organization_name LIKE ? COLLATE NOCASE
                OR c.job_title LIKE ? COLLATE NOCASE
                OR c.primary_email LIKE ? COLLATE NOCASE
                OR EXISTS (
                    SELECT 1 FROM context_entries e
                    WHERE e.contact_id = c.id
                      AND e.body LIKE ? COLLATE NOCASE
                )
            )
            \(filterClause)
            ORDER BY
                CASE WHEN next_follow_up_at IS NULL THEN 1 ELSE 0 END,
                next_follow_up_at ASC,
                last_context_at DESC,
                c.display_name COLLATE NOCASE ASC;
            """

            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            for index in 1...5 {
                try bindText(likeValue, to: Int32(index), in: statement)
            }

            var items: [ContactListItem] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                items.append(
                    ContactListItem(
                        id: sqlite3_column_int64(statement, 0),
                        appleIdentifier: string(at: 1, in: statement),
                        displayName: string(at: 2, in: statement),
                        subtitle: string(at: 3, in: statement),
                        primaryEmail: optionalString(at: 4, in: statement),
                        primaryPhone: optionalString(at: 5, in: statement),
                        city: optionalString(at: 6, in: statement),
                        country: optionalString(at: 7, in: statement),
                        lastContextAt: optionalDate(at: 8, in: statement),
                        nextFollowUpAt: optionalDate(at: 9, in: statement),
                        openFollowUpCount: Int(sqlite3_column_int64(statement, 10))
                    )
                )
            }
            return items
        }
    }

    nonisolated func fetchContactBundle(contactID: Int64) throws -> OrbitContactBundle? {
        try queue.sync {
            guard let core = try fetchContactCore(contactID: contactID) else {
                return nil
            }
            let timeline = try fetchContextEntries(contactID: contactID)
            let followUps = try fetchFollowUps(contactID: contactID)
            let facts = timeline.filter { $0.kind == .fact }.prefix(3).map(\.body)
            return OrbitContactBundle(
                id: contactID,
                core: core,
                timeline: timeline,
                followUps: followUps,
                pinnedFacts: Array(facts)
            )
        }
    }

    nonisolated func addContextEntry(
        contactID: Int64,
        kind: ContextEntryKind,
        title: String,
        body: String,
        provenance: ContextEntryProvenance
    ) throws {
        try queue.sync {
            let sql = """
            INSERT INTO context_entries (contact_id, kind, title, body, provenance, created_at)
            VALUES (?, ?, ?, ?, ?, ?);
            """
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            try bindInt64(contactID, to: 1, in: statement)
            try bindText(kind.rawValue, to: 2, in: statement)
            try bindText(title.nonEmpty, to: 3, in: statement)
            try bindText(body, to: 4, in: statement)
            try bindText(provenance.rawValue, to: 5, in: statement)
            sqlite3_bind_double(statement, 6, Date().timeIntervalSince1970)
            try stepDone(statement)
        }
    }

    nonisolated func addFollowUp(contactID: Int64, title: String, note: String, dueAt: Date?) throws {
        try queue.sync {
            let sql = """
            INSERT INTO follow_ups (contact_id, title, note, due_at, created_at)
            VALUES (?, ?, ?, ?, ?);
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
            sqlite3_bind_double(statement, 5, Date().timeIntervalSince1970)
            try stepDone(statement)
        }
    }

    nonisolated func completeFollowUp(id: Int64) throws {
        try queue.sync {
            let sql = "UPDATE follow_ups SET completed_at = ? WHERE id = ?;"
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_double(statement, 1, Date().timeIntervalSince1970)
            try bindInt64(id, to: 2, in: statement)
            try stepDone(statement)
        }
    }

    nonisolated func contactPayload(contactID: Int64) throws -> [String: Any]? {
        try queue.sync {
            guard let core = try fetchContactCore(contactID: contactID) else { return nil }
            let timeline = try fetchContextEntries(contactID: contactID)
            let followUps = try fetchFollowUps(contactID: contactID)
            let formatter = ISO8601DateFormatter()

            return [
                "id": core.id,
                "display_name": core.displayName,
                "organization_name": core.organizationName,
                "job_title": core.jobTitle,
                "primary_email": core.primaryEmail as Any,
                "primary_phone": core.primaryPhone as Any,
                "city": core.city as Any,
                "country": core.country as Any,
                "timeline": timeline.map {
                    [
                        "id": $0.id,
                        "kind": $0.kind.rawValue,
                        "title": $0.title,
                        "body": $0.body,
                        "provenance": $0.provenance.rawValue,
                        "created_at": formatter.string(from: $0.createdAt)
                    ]
                },
                "follow_ups": followUps.map {
                    [
                        "id": $0.id,
                        "title": $0.title,
                        "note": $0.note,
                        "due_at": $0.dueAt.map { formatter.string(from: $0) } as Any,
                        "completed_at": $0.completedAt.map { formatter.string(from: $0) } as Any
                    ]
                }
            ]
        }
    }

    private func fetchContactCore(contactID: Int64) throws -> ContactCore? {
        let sql = """
        SELECT id, apple_identifier, given_name, family_name, display_name, organization_name,
               job_title, primary_email, primary_phone, city, country, birthday_year,
               birthday_month, birthday_day, image_data, last_synced_at
        FROM contacts
        WHERE id = ?;
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bindInt64(contactID, to: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        let year = optionalInt(at: 11, in: statement)
        let month = optionalInt(at: 12, in: statement)
        let day = optionalInt(at: 13, in: statement)
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
            jobTitle: string(at: 6, in: statement),
            primaryEmail: optionalString(at: 7, in: statement),
            primaryPhone: optionalString(at: 8, in: statement),
            city: optionalString(at: 9, in: statement),
            country: optionalString(at: 10, in: statement),
            birthday: birthday,
            contactImageData: optionalData(at: 14, in: statement),
            lastSyncedAt: optionalDate(at: 15, in: statement) ?? .now
        )
    }

    private func fetchContextEntries(contactID: Int64) throws -> [ContextEntry] {
        let sql = """
        SELECT id, contact_id, kind, title, body, provenance, created_at
        FROM context_entries
        WHERE contact_id = ?
        ORDER BY created_at DESC, id DESC;
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bindInt64(contactID, to: 1, in: statement)

        var entries: [ContextEntry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            entries.append(
                ContextEntry(
                    id: sqlite3_column_int64(statement, 0),
                    contactID: sqlite3_column_int64(statement, 1),
                    kind: ContextEntryKind(rawValue: string(at: 2, in: statement)) ?? .note,
                    title: optionalString(at: 3, in: statement) ?? "",
                    body: string(at: 4, in: statement),
                    provenance: ContextEntryProvenance(rawValue: string(at: 5, in: statement)) ?? .manual,
                    createdAt: optionalDate(at: 6, in: statement) ?? .now
                )
            )
        }
        return entries
    }

    private func fetchFollowUps(contactID: Int64) throws -> [FollowUpItem] {
        let sql = """
        SELECT id, contact_id, title, note, due_at, created_at, completed_at
        FROM follow_ups
        WHERE contact_id = ?
        ORDER BY
            CASE WHEN completed_at IS NULL THEN 0 ELSE 1 END,
            due_at ASC,
            created_at DESC;
        """
        let statement = try prepare(sql)
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
                    createdAt: optionalDate(at: 5, in: statement) ?? .now,
                    completedAt: optionalDate(at: 6, in: statement)
                )
            )
        }
        return items
    }

    private func upsert(snapshot: ContactSyncSnapshot) throws {
        let sql = """
        INSERT INTO contacts (
            apple_identifier, given_name, family_name, display_name,
            organization_name, job_title, primary_email, primary_phone,
            city, country, birthday_year, birthday_month, birthday_day,
            image_data, last_synced_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(apple_identifier) DO UPDATE SET
            given_name = excluded.given_name,
            family_name = excluded.family_name,
            display_name = excluded.display_name,
            organization_name = excluded.organization_name,
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

        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bindText(snapshot.identifier, to: 1, in: statement)
        try bindText(snapshot.givenName, to: 2, in: statement)
        try bindText(snapshot.familyName, to: 3, in: statement)
        try bindText(snapshot.displayName.nonEmpty ?? snapshot.organizationName.nonEmpty ?? "Unknown Contact", to: 4, in: statement)
        try bindText(snapshot.organizationName, to: 5, in: statement)
        try bindText(snapshot.jobTitle, to: 6, in: statement)
        try bindText(snapshot.primaryEmail, to: 7, in: statement)
        try bindText(snapshot.primaryPhone, to: 8, in: statement)
        try bindText(snapshot.city, to: 9, in: statement)
        try bindText(snapshot.country, to: 10, in: statement)
        if let birthday = snapshot.birthday?.year { sqlite3_bind_int(statement, 11, Int32(birthday)) } else { sqlite3_bind_null(statement, 11) }
        if let birthday = snapshot.birthday?.month { sqlite3_bind_int(statement, 12, Int32(birthday)) } else { sqlite3_bind_null(statement, 12) }
        if let birthday = snapshot.birthday?.day { sqlite3_bind_int(statement, 13, Int32(birthday)) } else { sqlite3_bind_null(statement, 13) }
        if let data = snapshot.imageData {
            _ = data.withUnsafeBytes { rawBuffer in
                sqlite3_bind_blob(statement, 14, rawBuffer.baseAddress, Int32(rawBuffer.count), SQLITE_TRANSIENT)
            }
        } else {
            sqlite3_bind_null(statement, 14)
        }
        sqlite3_bind_double(statement, 15, Date().timeIntervalSince1970)
        try stepDone(statement)
    }

    private func migrate() throws {
        try execute("""
        CREATE TABLE IF NOT EXISTS contacts (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            apple_identifier TEXT NOT NULL UNIQUE,
            given_name TEXT NOT NULL DEFAULT '',
            family_name TEXT NOT NULL DEFAULT '',
            display_name TEXT NOT NULL DEFAULT '',
            organization_name TEXT NOT NULL DEFAULT '',
            job_title TEXT NOT NULL DEFAULT '',
            primary_email TEXT,
            primary_phone TEXT,
            city TEXT,
            country TEXT,
            birthday_year INTEGER,
            birthday_month INTEGER,
            birthday_day INTEGER,
            image_data BLOB,
            last_synced_at REAL NOT NULL
        );
        """)

        try execute("""
        CREATE TABLE IF NOT EXISTS context_entries (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            contact_id INTEGER NOT NULL REFERENCES contacts(id) ON DELETE CASCADE,
            kind TEXT NOT NULL,
            title TEXT,
            body TEXT NOT NULL,
            provenance TEXT NOT NULL,
            created_at REAL NOT NULL
        );
        """)

        try execute("""
        CREATE TABLE IF NOT EXISTS follow_ups (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            contact_id INTEGER NOT NULL REFERENCES contacts(id) ON DELETE CASCADE,
            title TEXT NOT NULL,
            note TEXT,
            due_at REAL,
            created_at REAL NOT NULL,
            completed_at REAL
        );
        """)

        try execute("CREATE INDEX IF NOT EXISTS idx_contacts_display_name ON contacts(display_name);")
        try execute("CREATE INDEX IF NOT EXISTS idx_context_entries_contact_id_created_at ON context_entries(contact_id, created_at DESC);")
        try execute("CREATE INDEX IF NOT EXISTS idx_follow_ups_contact_id_due_at ON follow_ups(contact_id, due_at);")
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
        if let value {
            if sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT) != SQLITE_OK {
                throw OrbitDatabaseError.bindFailed(String(cString: sqlite3_errmsg(db)))
            }
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func bindInt64(_ value: Int64, to index: Int32, in statement: OpaquePointer?) throws {
        if sqlite3_bind_int64(statement, index, value) != SQLITE_OK {
            throw OrbitDatabaseError.bindFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func string(at index: Int32, in statement: OpaquePointer?) -> String {
        String(cString: sqlite3_column_text(statement, index))
    }

    private func optionalString(at index: Int32, in statement: OpaquePointer?) -> String? {
        guard let pointer = sqlite3_column_text(statement, index) else { return nil }
        let value = String(cString: pointer)
        return value.isEmpty ? nil : value
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
        let count = Int(sqlite3_column_bytes(statement, index))
        return Data(bytes: bytes, count: count)
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
