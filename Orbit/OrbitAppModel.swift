import Combine
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

    private let database: OrbitDatabase
    private let contactsBridge = ContactsBridge()
    private(set) var mcpServer: OrbitMCPServer?
    private var contactsDidChangeObserver: NSObjectProtocol?
    private var pendingAutoRefreshTask: Task<Void, Never>?

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
            reloadList()
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    func reloadList() {
        do {
            contacts = try database.fetchContacts(filter: selectedFilter, search: searchText)
            if selectedContactID == nil || !contacts.contains(where: { $0.id == selectedContactID }) {
                selectedContactID = contacts.first?.id
            }
            reloadSelection()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func reloadSelection() {
        guard let selectedContactID else {
            selectedBundle = nil
            return
        }
        do {
            selectedBundle = try database.fetchContactBundle(contactID: selectedContactID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func addContextEntry(kind: ContextEntryKind, title: String, body: String) {
        guard let selectedContactID else { return }
        do {
            try database.addContextEntry(
                contactID: selectedContactID,
                kind: kind,
                title: title,
                body: body,
                provenance: .manual
            )
            reloadList()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func addFollowUp(title: String, note: String, dueAt: Date?) {
        guard let selectedContactID else { return }
        do {
            try database.addFollowUp(contactID: selectedContactID, title: title, note: note, dueAt: dueAt)
            reloadList()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func completeFollowUp(id: Int64) {
        do {
            try database.completeFollowUp(id: id)
            reloadList()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setSelection(_ id: Int64?) {
        selectedContactID = id
    }

    func scheduleReloadList() {
        DispatchQueue.main.async { [weak self] in
            self?.reloadList()
        }
    }

    func scheduleReloadSelection() {
        DispatchQueue.main.async { [weak self] in
            self?.reloadSelection()
        }
    }

    func startMCPServerIfNeeded() async {
        guard mcpServer == nil else { return }
        let server = OrbitMCPServer(database: database)
        do {
            try await server.start()
            mcpServer = server
        } catch {
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
            self?.scheduleAutomaticContactsRefresh()
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
