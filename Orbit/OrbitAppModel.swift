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
    @Published var errorMessage: String?
    @Published var pendingVerificationPhoneE164: String?

    var contactListTitle: String {
        "\(contacts.count) Contact\(contacts.count == 1 ? "" : "s")"
    }

    private let database: OrbitDatabase
    private let contactsBridge = ContactsBridge()
    private(set) var mcpServer: OrbitMCPServer?
    private var contactsDidChangeObserver: NSObjectProtocol?
    private var pendingAutoRefreshTask: Task<Void, Never>?
    private var pendingListReloadTask: Task<Void, Never>?
    private var pendingSelectionReloadTask: Task<Void, Never>?

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
                let snapshots = try await contactsBridge.fetchSnapshotsAsync()
                try database.syncContacts(snapshots)
            }
            scheduleReloadList(immediate: true)
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
            scheduleReloadList(immediate: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteInsight(id: Int64) {
        do {
            try database.deleteInsight(id: id)
            scheduleReloadList(immediate: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func completeFollowUp(id: Int64) {
        do {
            try database.completeFollowUp(id: id)
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
                    try await Task.detached(priority: .userInitiated) { [contactsBridge] in
                        try contactsBridge.updateDisplayName(
                            contactIdentifier: bundle.core.appleIdentifier,
                            displayName: newName
                        )
                    }.value
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
            scheduleReloadList(immediate: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func scheduleReloadList(immediate: Bool = false) {
        let filter = selectedFilter
        let search = searchText
        let currentSelection = selectedContactID

        pendingListReloadTask?.cancel()
        pendingListReloadTask = Task { [weak self, database] in
            let delay: Duration = immediate ? .zero : .milliseconds(180)
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled else { return }

            do {
                let items = try await Task.detached(priority: .userInitiated) {
                    try database.fetchContacts(filter: filter, search: search)
                }.value
                guard !Task.isCancelled, let self else { return }

                self.contacts = items
                if let currentSelection, items.contains(where: { $0.id == currentSelection }) {
                    self.selectedContactID = currentSelection
                } else {
                    self.selectedContactID = items.first?.id
                }
                self.scheduleReloadSelection()
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
}
