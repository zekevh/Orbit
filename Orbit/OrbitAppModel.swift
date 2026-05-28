import Combine
import AppKit
import Contacts
import Foundation
import SwiftUI

@MainActor
final class OrbitAppModel: ObservableObject {
    @Published var sidebarVisibility: NavigationSplitViewVisibility = .all
    @Published var selectedFilter: SidebarFilter = .allContacts
    @Published var searchText = ""
    @Published var contacts: [ContactListItem] = []
    @Published var selectedContactID: Int64?
    @Published var selectedBundle: OrbitContactBundle?
    @Published var authorizationStatus: CNAuthorizationStatus
    @Published var isLoading = false
    @Published var hasCompletedInitialContactsLoad = false
    @Published var errorMessage: String?
    @Published var pendingVerificationPhoneE164: String?

    var contactListTitle: String {
        "\(contacts.count) Contact\(contacts.count == 1 ? "" : "s")"
    }

    var isPreparingInitialContacts: Bool {
        authorizationStatus == .authorized && !hasCompletedInitialContactsLoad && errorMessage == nil
    }

    private let database: OrbitDatabase
    private let contactsBridge = ContactsBridge()
    private(set) var mcpServer: OrbitMCPServer?
    private var contactsDidChangeObserver: NSObjectProtocol?
    private var pendingAutoRefreshTask: Task<Void, Never>?
    private var pendingListReloadTask: Task<Void, Never>?
    private var pendingSelectionReloadTask: Task<Void, Never>?
    private var emptySearchContactCache: [SidebarFilter: [ContactListItem]] = [:]

    init() {
        do {
            database = try OrbitDatabase()
        } catch {
            fatalError("Could not initialize Orbit database: \(error.localizedDescription)")
        }
        authorizationStatus = contactsBridge.authorizationStatus
    }

    func start() {
        startObservingContactsChanges()
        Task {
            await refreshContactsFromStore()
            await startMCPServerIfNeeded()
        }
    }

    deinit {
        pendingAutoRefreshTask?.cancel()
        pendingListReloadTask?.cancel()
        pendingSelectionReloadTask?.cancel()
        if let contactsDidChangeObserver {
            NotificationCenter.default.removeObserver(contactsDidChangeObserver)
        }
    }

    func requestContactsAccess() {
        Task {
            do {
                let granted = try await contactsBridge.requestAccess()
                authorizationStatus = contactsBridge.authorizationStatus
                if granted {
                    hasCompletedInitialContactsLoad = false
                    await refreshContactsFromStore()
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func refreshContactsFromStore() async {
        isLoading = true
        authorizationStatus = contactsBridge.authorizationStatus

        do {
            if authorizationStatus == .authorized {
                let snapshots = try contactsBridge.fetchSnapshots()
                try database.syncContacts(snapshots)
                emptySearchContactCache.removeAll()
            }
            await reloadList(immediate: true)
            hasCompletedInitialContactsLoad = true
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    func addNote(_ body: String) {
        guard let selectedContactID else { return }
        do {
            try database.addNote(
                contactID: selectedContactID,
                body: body,
                source: .manual
            )
            emptySearchContactCache.removeAll()
            scheduleReloadList(immediate: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func upsertInsight(id: Int64?, body: String, kind: InsightKind) {
        guard let selectedContactID else { return }
        do {
            let source: InsightSource = id == nil ? .human : .human
            try database.upsertInsight(
                contactID: selectedContactID,
                insightID: id,
                body: body,
                kind: kind,
                source: source
            )
            emptySearchContactCache.removeAll()
            scheduleReloadList(immediate: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteInsight(id: Int64) {
        do {
            try database.deleteInsight(id: id)
            emptySearchContactCache.removeAll()
            scheduleReloadList(immediate: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func completeFollowUp(id: Int64) {
        do {
            try database.completeFollowUp(id: id)
            emptySearchContactCache.removeAll()
            scheduleReloadList(immediate: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setSelection(_ id: Int64?) {
        guard selectedContactID != id else { return }
        selectedContactID = id
    }

    func prepareWhatsAppVerification(contactID: Int64) -> String? {
        do {
            guard let bundle = try database.fetchContactBundle(contactID: contactID) else {
                return nil
            }
            let normalized = try PhoneNumberNormalizer.normalize(bundle.core.primaryPhone)
            pendingVerificationPhoneE164 = normalized.e164
            if bundle.core.verificationStatus == .unverified {
                try database.updateVerificationStatus(
                    contactID: contactID,
                    status: .pendingReview,
                    verifiedPhoneE164: normalized.e164,
                    note: bundle.core.verificationNote,
                    verifiedAt: bundle.core.verifiedAt
                )
                emptySearchContactCache.removeAll()
                scheduleReloadList(immediate: true)
            } else {
                scheduleReloadSelection()
            }
            return normalized.e164
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func openWhatsAppChat(contactID: Int64) {
        guard let e164 = prepareWhatsAppVerification(contactID: contactID) else { return }
        let digits = e164.filter(\.isNumber)
        let candidates = [
            "whatsapp://send?phone=\(digits)",
            "https://wa.me/\(digits)"
        ]

        for candidate in candidates {
            guard let url = URL(string: candidate) else { continue }
            if NSWorkspace.shared.open(url) {
                return
            }
        }

        errorMessage = "Orbit could not open WhatsApp for this contact."
    }

    func importVerificationImage(contactID: Int64, imageData: Data, source: String = "manual_upload") {
        do {
            try database.updateEnrichedImage(contactID: contactID, imageData: imageData, source: source)
            let importTitle: String
            let importBody: String
            switch source {
            case "manual_whatsapp":
                importTitle = "WhatsApp Photo Imported"
                importBody = "Imported a profile photo from WhatsApp for manual review."
            default:
                importTitle = "Profile Photo Imported"
                importBody = "Imported a profile photo for manual review."
            }
            try database.addNote(
                contactID: contactID,
                body: "\(importTitle). \(importBody)",
                source: .imported
            )
            emptySearchContactCache.removeAll()
            scheduleReloadList(immediate: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func confirmVerification(contactID: Int64, appleDisplayName: String) {
        Task {
            do {
                guard let bundle = try database.fetchContactBundle(contactID: contactID) else { return }
                let normalizedPhone = try PhoneNumberNormalizer.normalize(bundle.core.primaryPhone).e164
                let trimmedName = appleDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
                let didRenameAppleContact = trimmedName.nonEmpty != nil && trimmedName != bundle.core.displayName

                if let newName = trimmedName.nonEmpty, newName != bundle.core.displayName {
                    try contactsBridge.updateDisplayName(
                        contactIdentifier: bundle.core.appleIdentifier,
                        displayName: newName
                    )
                    emptySearchContactCache.removeAll()
                    await refreshContactsFromStore()
                }

                try database.updateVerificationStatus(
                    contactID: contactID,
                    status: .verified,
                    verifiedPhoneE164: normalizedPhone,
                    note: "",
                    verifiedAt: .now
                )

                let timelineNote = [
                    "Verified in WhatsApp on \(DateFormatter.orbitTimeline.string(from: .now)).",
                    didRenameAppleContact ? "Updated Apple contact name to \(trimmedName)." : nil
                ]
                    .compactMap { $0 }
                    .joined(separator: " ")

                try database.addNote(
                    contactID: contactID,
                    body: timelineNote,
                    source: .imported
                )
                emptySearchContactCache.removeAll()

                // Verification can invalidate the current filter/search immediately
                // (for example "Needs Verification" or the old display name), which
                // makes the list look empty even though the contact still exists.
                selectedFilter = .allContacts
                searchText = ""
                pendingVerificationPhoneE164 = normalizedPhone
                scheduleReloadList(immediate: true)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func unverifyContact(contactID: Int64) {
        do {
            try database.updateVerificationStatus(
                contactID: contactID,
                status: .unverified,
                verifiedPhoneE164: nil,
                note: "",
                verifiedAt: nil
            )
            try database.addNote(
                contactID: contactID,
                body: "Marked as unverified on \(DateFormatter.orbitTimeline.string(from: .now)).",
                source: .imported
            )
            pendingVerificationPhoneE164 = nil
            emptySearchContactCache.removeAll()
            scheduleReloadList(immediate: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func archiveContact(contactID: Int64) {
        do {
            try database.setContactArchived(contactID: contactID, isArchived: true)
            emptySearchContactCache.removeAll()
            scheduleReloadList(immediate: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func restoreContact(contactID: Int64) {
        do {
            try database.setContactArchived(contactID: contactID, isArchived: false)
            emptySearchContactCache.removeAll()
            scheduleReloadList(immediate: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func scheduleReloadList(immediate: Bool = false) {
        let filter = selectedFilter
        let search = searchText
        let currentSelection = selectedContactID

        if search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let cachedItems = emptySearchContactCache[filter] {
            applyContactList(cachedItems, currentSelection: currentSelection)
        } else if let cachedItems = emptySearchContactCache[filter] {
            let cachedSearchResults = contactFieldSearchResults(
                in: cachedItems,
                search: search
            )
            applyContactList(cachedSearchResults, currentSelection: currentSelection)
        }

        pendingListReloadTask?.cancel()
        pendingListReloadTask = Task { [weak self, database] in
            let delay: Duration = immediate ? .zero : .milliseconds(180)
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled else { return }

            do {
                try await self?.loadContactsList(
                    database: database,
                    filter: filter,
                    search: search,
                    currentSelection: currentSelection
                )
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func scheduleReloadSelection() {
        let contactID = selectedContactID

        pendingSelectionReloadTask?.cancel()
        guard let contactID else {
            Task { @MainActor [weak self] in
                self?.selectedBundle = nil
            }
            return
        }

        pendingSelectionReloadTask = Task { [weak self, database] in
            do {
                let bundle = try await Task.detached(priority: .userInitiated) {
                    try database.fetchContactBundle(contactID: contactID)
                }.value
                guard let self, !Task.isCancelled else { return }
                if self.selectedContactID == contactID {
                    self.selectedBundle = bundle
                }
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func startMCPServerIfNeeded() async {
        guard mcpServer == nil else { return }
        let server = OrbitMCPServer(database: database)
        do {
            try await server.start()
            mcpServer = server
        } catch {
            if let serverError = error as? OrbitMCPServerError {
                if serverError.isPortInUse {
                    return
                }
            }
            errorMessage = "Could not start MCP server: \(error.localizedDescription)"
        }
    }

    private func startObservingContactsChanges() {
        guard contactsDidChangeObserver == nil else { return }
        contactsDidChangeObserver = NotificationCenter.default.addObserver(
            forName: .CNContactStoreDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleAutomaticContactsRefresh()
            }
        }
    }

    private func scheduleAutomaticContactsRefresh() {
        guard authorizationStatus == .authorized else { return }
        pendingAutoRefreshTask?.cancel()
        pendingAutoRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self else { return }
            await self.refreshContactsFromStore()
        }
    }

    private func reloadList(immediate: Bool = false) async {
        pendingListReloadTask?.cancel()

        let filter = selectedFilter
        let search = searchText
        let currentSelection = selectedContactID
        let delay: Duration = immediate ? .zero : .milliseconds(180)

        if delay > .zero {
            try? await Task.sleep(for: delay)
        }
        guard !Task.isCancelled else { return }

        do {
            try await loadContactsList(
                database: database,
                filter: filter,
                search: search,
                currentSelection: currentSelection
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadContactsList(
        database: OrbitDatabase,
        filter: SidebarFilter,
        search: String,
        currentSelection: Int64?
    ) async throws {
        let isEmptySearch = search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let items = try await Task.detached(priority: .userInitiated) {
            try database.fetchContacts(filter: filter, search: search)
        }.value
        guard !Task.isCancelled else { return }

        if isEmptySearch {
            emptySearchContactCache[filter] = items
        }
        applyContactList(items, currentSelection: currentSelection)
    }

    private func applyContactList(_ items: [ContactListItem], currentSelection: Int64?) {
        let previousSelection = selectedContactID
        contacts = items
        let nextSelection: Int64?
        if let currentSelection, items.contains(where: { $0.id == currentSelection }) {
            nextSelection = currentSelection
        } else {
            nextSelection = items.first?.id
        }

        selectedContactID = nextSelection
        if previousSelection != nextSelection || selectedBundle == nil {
            scheduleReloadSelection()
        }
    }

    private func contactFieldSearchResults(in items: [ContactListItem], search: String) -> [ContactListItem] {
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !term.isEmpty else { return items }

        return items
            .filter { contact in
                searchableContactFields(contact).contains { $0.contains(term) }
            }
            .sorted { lhs, rhs in
                let lhsRank = contactSearchRank(lhs, term: term)
                let rhsRank = contactSearchRank(rhs, term: term)
                if lhsRank != rhsRank { return lhsRank < rhsRank }

                let lhsFollowUp = lhs.nextFollowUpAt
                let rhsFollowUp = rhs.nextFollowUpAt
                switch (lhsFollowUp, rhsFollowUp) {
                case let (lhsFollowUp?, rhsFollowUp?) where lhsFollowUp != rhsFollowUp:
                    return lhsFollowUp < rhsFollowUp
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                default:
                    break
                }

                if lhs.lastActivityAt != rhs.lastActivityAt {
                    return (lhs.lastActivityAt ?? .distantPast) > (rhs.lastActivityAt ?? .distantPast)
                }

                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
    }

    private func contactSearchRank(_ contact: ContactListItem, term: String) -> Int {
        let displayName = contact.displayName.lowercased()
        let organizationName = contact.subtitle.lowercased()
        let email = contact.primaryEmail?.lowercased() ?? ""
        let phone = contact.primaryPhone?.lowercased() ?? ""

        if displayName == term { return 0 }
        if displayName.hasPrefix(term) { return 1 }
        if displayName.contains(" \(term)") { return 2 }
        if organizationName.contains(term) { return 3 }
        if email.contains(term) { return 4 }
        if phone.contains(term) { return 5 }
        return 6
    }

    private func searchableContactFields(_ contact: ContactListItem) -> [String] {
        [
            contact.displayName,
            contact.subtitle,
            contact.primaryEmail ?? "",
            contact.primaryPhone ?? "",
            contact.city ?? "",
            contact.country ?? ""
        ].map { $0.lowercased() }
    }
}
