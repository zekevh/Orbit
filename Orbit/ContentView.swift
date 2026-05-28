import AppKit
import Contacts
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var model: OrbitAppModel

    var body: some View {
        Group {
            if model.isPreparingInitialContacts {
                InitialContactsLoadingView()
            } else {
                NavigationSplitView(columnVisibility: $model.sidebarVisibility) {
                    SidebarView()
                        .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 250)
                } content: {
                    ContactListView()
                        .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 420)
                } detail: {
                    ContactDetailHost()
                }
                .navigationSplitViewStyle(.balanced)
                .toolbarBackground(.hidden, for: .windowToolbar)
                .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search Contacts")
                .onChange(of: model.searchText) { _, _ in
                    Task { @MainActor in
                        model.scheduleReloadList(immediate: model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .onChange(of: model.selectedContactID) { _, _ in
                    Task { @MainActor in model.scheduleReloadSelection() }
                }
            }
        }
        .alert("Orbit", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

private struct InitialContactsLoadingView: View {
    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text("Loading Contacts...")
                .font(.headline)
            Text("Orbit is preparing your Apple Contacts before opening the workspace.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 720, minHeight: 480)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SidebarView: View {
    @EnvironmentObject private var model: OrbitAppModel

    var body: some View {
        List(SidebarFilter.allCases, selection: $model.selectedFilter) { filter in
            Label(filter.title, systemImage: filter.systemImage)
                .tag(filter)
        }
        .listStyle(.sidebar)
        .onChange(of: model.selectedFilter) { _, _ in
            Task { @MainActor in model.scheduleReloadList() }
        }
    }
}

private struct ContactListView: View {
    @EnvironmentObject private var model: OrbitAppModel

    var body: some View {
        Group {
            if model.authorizationStatus == .notDetermined {
                RequestAccessView()
            } else if model.authorizationStatus == .denied || model.authorizationStatus == .restricted {
                AccessDeniedView()
            } else if model.contacts.isEmpty && model.isLoading {
                ProgressView("Loading Contacts…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.contacts.isEmpty {
                ContentUnavailableView(
                    model.selectedFilter == .archived ? "No Archived Contacts" : "No Contacts",
                    systemImage: model.selectedFilter == .archived ? "archivebox" : "person.crop.circle.badge.exclamationmark"
                )
            } else {
                List(model.contacts, selection: Binding(
                    get: { model.selectedContactID },
                    set: { newValue in
                        Task { @MainActor in model.setSelection(newValue) }
                    }
                )) { contact in
                    ContactRow(contact: contact)
                        .tag(contact.id)
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle(model.contactListTitle)
    }
}

private struct ContactRow: View {
    let contact: ContactListItem

    var body: some View {
        HStack(spacing: 12) {
            Text(contact.monogram)
                .font(.headline)
                .frame(width: 34, height: 34)
                .background(.tertiary, in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(contact.displayName)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    if let dueAt = contact.nextFollowUpAt {
                        Text(DateFormatter.orbitDay.string(from: dueAt))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Text(contact.secondaryLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if contact.isArchived {
                    Label("Archived", systemImage: "archivebox")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if contact.verificationStatus != .verified && !contact.hasAnyImage {
                    Label(contact.verificationStatus.title, systemImage: "checkmark.shield")
                        .font(.caption)
                        .foregroundStyle(.blue)
                } else if contact.openFollowUpCount > 0 {
                    Label("\(contact.openFollowUpCount) open follow-up\(contact.openFollowUpCount == 1 ? "" : "s")", systemImage: "clock.badge.exclamationmark")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct ContactDetailHost: View {
    @EnvironmentObject private var model: OrbitAppModel

    var body: some View {
        Group {
            if let bundle = model.selectedBundle {
                ContactDetailView(bundle: bundle)
            } else {
                ContentUnavailableView(
                    "Select a Contact",
                    systemImage: "person.text.rectangle",
                    description: Text("Orbit mirrors Apple Contacts and layers raw notes, insights, and follow-ups on top.")
                )
            }
        }
    }
}

private enum ContactTab: String, CaseIterable, Identifiable {
    case derived
    case rawNotes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .derived: "Derived"
        case .rawNotes: "Raw Notes"
        }
    }
}

private struct ContactDetailView: View {
    @EnvironmentObject private var model: OrbitAppModel
    let bundle: OrbitContactBundle

    @State private var noteBody = ""
    @State private var appleDisplayName = ""
    @State private var isImportingProfileImage = false
    @State private var selectedTab: ContactTab = .derived
    @State private var editingInsightID: Int64?
    @State private var insightDraft = ""
    @State private var insightKind: InsightKind = .general
    @State private var isConfirmingArchive = false

    var body: some View {
        VStack(spacing: 0) {
            ContactIdentityHeader(
                appleDisplayName: $appleDisplayName,
                core: bundle.core,
                beginImageImport: { isImportingProfileImage = true },
                openWhatsApp: { model.openWhatsAppChat(contactID: bundle.id) },
                confirmVerification: {
                    model.confirmVerification(contactID: bundle.id, appleDisplayName: appleDisplayName)
                },
                unverify: { model.unverifyContact(contactID: bundle.id) },
                archive: { isConfirmingArchive = true },
                restore: { model.restoreContact(contactID: bundle.id) }
            )
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 10)

            VStack(spacing: 12) {
                Picker("View", selection: $selectedTab) {
                    ForEach(ContactTab.allCases) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 20)

                Group {
                    switch selectedTab {
                    case .derived:
                        DerivedContactView(
                            bundle: bundle,
                            editingInsightID: $editingInsightID,
                            insightDraft: $insightDraft,
                            insightKind: $insightKind,
                            saveInsight: saveInsight,
                            startEditingInsight: startEditingInsight,
                            cancelEditingInsight: cancelEditingInsight,
                            deleteInsight: deleteInsight,
                            completeFollowUp: { model.completeFollowUp(id: $0) }
                        )
                    case .rawNotes:
                        RawNotesView(
                            bundle: bundle,
                            noteBody: $noteBody,
                            addNote: addNote
                        )
                    }
                }
            }
        }
        .onAppear {
            hydrateVerificationFields()
            seedInsightEditorIfNeeded()
        }
        .fileImporter(
            isPresented: $isImportingProfileImage,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            handleImportedProfileImage(result)
        }
        .onChange(of: bundle.id) { _, _ in
            hydrateVerificationFields()
            resetEditors()
        }
        .onChange(of: bundle.core.verifiedAt) { _, _ in
            hydrateVerificationFields()
        }
        .confirmationDialog(
            "Archive Contact",
            isPresented: $isConfirmingArchive
        ) {
            Button("Archive Contact", role: .destructive) {
                model.archiveContact(contactID: bundle.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This hides the contact from normal lists but keeps Orbit notes, insights, and follow-ups available in Archived.")
        }
    }

    private func addNote() {
        let body = noteBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        model.addNote(body)
        noteBody = ""
    }

    private func saveInsight() {
        let body = insightDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        model.upsertInsight(id: editingInsightID, body: body, kind: insightKind)
        resetInsightEditor()
    }

    private func startEditingInsight(_ insight: Insight) {
        editingInsightID = insight.id
        insightDraft = insight.body
        insightKind = insight.kind
    }

    private func cancelEditingInsight() {
        resetInsightEditor()
    }

    private func deleteInsight(_ insightID: Int64) {
        model.deleteInsight(id: insightID)
        if editingInsightID == insightID {
            resetInsightEditor()
        }
    }

    private func resetInsightEditor() {
        editingInsightID = nil
        insightDraft = ""
        insightKind = .general
    }

    private func resetEditors() {
        noteBody = ""
        resetInsightEditor()
    }

    private func seedInsightEditorIfNeeded() {
        if editingInsightID == nil && insightDraft.isEmpty {
            insightKind = .general
        }
    }

    private func hydrateVerificationFields() {
        appleDisplayName = bundle.core.displayName
    }

    private func handleImportedProfileImage(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let accessedSecurityScopedResource = url.startAccessingSecurityScopedResource()
            defer {
                if accessedSecurityScopedResource {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            let imageData = try Data(contentsOf: url, options: [.mappedIfSafe])
            model.importVerificationImage(contactID: bundle.id, imageData: imageData, source: "manual_upload")
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }
}

private struct DerivedContactView: View {
    let bundle: OrbitContactBundle
    @Binding var editingInsightID: Int64?
    @Binding var insightDraft: String
    @Binding var insightKind: InsightKind
    let saveInsight: () -> Void
    let startEditingInsight: (Insight) -> Void
    let cancelEditingInsight: () -> Void
    let deleteInsight: (Int64) -> Void
    let completeFollowUp: (Int64) -> Void

    var body: some View {
        Form {
            Section(editingInsightID == nil ? "New Insight" : "Edit Insight") {
                Picker("Type", selection: $insightKind) {
                    ForEach(InsightKind.allCases, id: \.self) { kind in
                        Text(kind.title).tag(kind)
                    }
                }

                TextField(
                    "Add an interpreted insight, summary, fact, preference, relationship note, or priority",
                    text: $insightDraft,
                    axis: .vertical
                )
                .lineLimit(3...6)

                HStack {
                    if editingInsightID != nil {
                        Button("Cancel", action: cancelEditingInsight)
                    }
                    Spacer()
                    Button(editingInsightID == nil ? "Save Insight" : "Update Insight", action: saveInsight)
                        .buttonStyle(.borderedProminent)
                }
            }

            Section("Insights") {
                if bundle.insights.isEmpty {
                    Text("No insights yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(bundle.insights) { insight in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(insight.kind.title)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(insight.source.label)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(DateFormatter.orbitTimeline.string(from: insight.updatedAt))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(insight.body)
                                .textSelection(.enabled)
                            HStack {
                                Button("Edit") { startEditingInsight(insight) }
                                Button("Delete", role: .destructive) { deleteInsight(insight.id) }
                            }
                            .controlSize(.small)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            Section("Follow-Ups") {
                if bundle.openFollowUps.isEmpty {
                    Text("No pending follow-ups.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(bundle.openFollowUps) { followUp in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(followUp.title)
                                    .font(.headline)
                                Spacer()
                                Button("Done") { completeFollowUp(followUp.id) }
                            }
                            if !followUp.note.isEmpty {
                                Text(followUp.note)
                                    .foregroundStyle(.secondary)
                            }
                            HStack(spacing: 8) {
                                Text(followUp.source.label)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if let dueAt = followUp.dueAt {
                                    Text(DateFormatter.orbitTimeline.string(from: dueAt))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            if !bundle.completedFollowUps.isEmpty {
                Section("Completed Follow-Ups") {
                    ForEach(bundle.completedFollowUps) { followUp in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(followUp.title)
                                .font(.headline)
                            if !followUp.note.isEmpty {
                                Text(followUp.note)
                                    .foregroundStyle(.secondary)
                            }
                            HStack(spacing: 8) {
                                Text(followUp.source.label)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if let completedAt = followUp.completedAt {
                                    Text("Completed \(DateFormatter.orbitTimeline.string(from: completedAt))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct RawNotesView: View {
    let bundle: OrbitContactBundle
    @Binding var noteBody: String
    let addNote: () -> Void

    var body: some View {
        Form {
            Section {
                HStack(alignment: .bottom, spacing: 8) {
                    TextEditor(text: $noteBody)
                        .font(.body)
                        .frame(minHeight: 110)

                    Button("Add", systemImage: "plus", action: addNote)
                        .labelStyle(.iconOnly)
                        .controlSize(.regular)
                    .disabled(noteBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Add note")
                }
            }

            Section("Raw Notes") {
                if bundle.notes.isEmpty {
                    Text("No notes yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(bundle.notes) { note in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(note.source.label)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(DateFormatter.orbitTimeline.string(from: note.createdAt))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(note.body)
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ContactIdentityHeader: View {
    @Binding var appleDisplayName: String
    let core: ContactCore
    let beginImageImport: () -> Void
    let openWhatsApp: () -> Void
    let confirmVerification: () -> Void
    let unverify: () -> Void
    let archive: () -> Void
    let restore: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            ContactAvatar(core: core, uploadImage: beginImageImport)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    TextField("Contact name", text: $appleDisplayName)
                        .font(.largeTitle)
                        .textFieldStyle(.plain)

                    VerificationStatusBadge(status: core.verificationStatus)

                    if core.isArchived {
                        Label("Archived", systemImage: "archivebox")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }

                    if let verifiedAt = core.verifiedAt {
                        Text(DateFormatter.orbitTimeline.string(from: verifiedAt))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if !core.roleLine.isEmpty {
                    Text(core.roleLine)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    if let email = core.primaryEmail {
                        CopyableContactValue(systemImage: "envelope", displayValue: email, copyValue: email)
                    }
                    if let phone = core.primaryPhone {
                        CopyableContactValue(
                            systemImage: "phone",
                            displayValue: PhoneNumberDisplayFormatter.format(phone) ?? phone,
                            copyValue: phone
                        )
                    }
                }
                .font(.subheadline)

                HStack(spacing: 10) {
                    Button(action: openWhatsApp) { WhatsAppIcon() }
                        .buttonStyle(.plain)
                        .help("Open this contact in WhatsApp")
                    if core.verificationStatus == .verified {
                        Button("Mark Unverified", action: unverify)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    } else {
                        Button("Mark Verified", action: confirmVerification)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                    if let source = core.enrichedImageSource?.nonEmpty {
                        Label(source.replacingOccurrences(of: "_", with: " ").capitalized, systemImage: "photo.badge.checkmark")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if core.isArchived {
                        Button("Restore", systemImage: "arrow.uturn.backward", action: restore)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    } else {
                        Button("Archive", systemImage: "archivebox", action: archive)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }

                if !core.locationLine.isEmpty {
                    Label(core.locationLine, systemImage: "mappin.and.ellipse")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct ContactAvatar: View {
    let core: ContactCore
    let uploadImage: () -> Void
    @State private var isHovered = false

    private var initials: String {
        let fullName = [core.givenName, core.familyName]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .nonEmpty ?? core.displayName
        let parts = fullName.split(separator: " ")
        let letters = parts.prefix(2).compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }

    var body: some View {
        Button(action: uploadImage) {
            ZStack {
                Circle().fill(.regularMaterial)

                if let data = core.resolvedImageData, let image = NSImage(data: data) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Text(initials)
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                }

                Circle().fill(.black.opacity(isHovered ? 0.28 : 0))

                Image(systemName: "camera.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .opacity(isHovered ? 1 : 0)
                    .scaleEffect(isHovered ? 1 : 0.92)
                    .animation(.easeOut(duration: 0.16), value: isHovered)
            }
        }
        .frame(width: 96, height: 96)
        .clipShape(Circle())
        .overlay {
            Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
        .buttonStyle(.plain)
        .help("Upload profile image")
        .onHover { isHovered = $0 }
    }
}

private struct CopyableContactValue: View {
    let systemImage: String
    let displayValue: String
    let copyValue: String
    @State private var isHovered = false
    @State private var didCopy = false

    var body: some View {
        Button {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(copyValue, forType: .string)
            didCopy = true
            Task {
                try? await Task.sleep(for: .milliseconds(1200))
                await MainActor.run { didCopy = false }
            }
        } label: {
            HStack(spacing: 6) {
                Label(displayValue, systemImage: systemImage)
                Image(systemName: didCopy ? "checkmark.circle.fill" : "doc.on.doc")
                    .font(.caption)
                    .foregroundStyle(didCopy ? Color.green : (isHovered ? Color.accentColor : Color.secondary))
                    .opacity(isHovered || didCopy ? 1 : 0.45)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(isHovered ? Color.accentColor.opacity(0.08) : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .help(didCopy ? "Copied" : "Click to copy")
        .onHover { isHovered = $0 }
    }
}

private struct VerificationStatusBadge: View {
    let status: ContactVerificationStatus

    var body: some View {
        Text(status.title)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(backgroundColor.opacity(0.16), in: Capsule())
            .foregroundStyle(backgroundColor)
    }

    private var backgroundColor: Color {
        switch status {
        case .unverified: .secondary
        case .pendingReview: .blue
        case .verified: .green
        }
    }
}

private struct WhatsAppIcon: View {
    var body: some View {
        ZStack {
            Circle().fill(Color(red: 0.145, green: 0.8, blue: 0.427))
            Image(systemName: "phone.fill")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: 34, height: 34)
        .overlay {
            Circle().strokeBorder(.white.opacity(0.3), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
    }
}

private struct RequestAccessView: View {
    @EnvironmentObject private var model: OrbitAppModel

    var body: some View {
        ContentUnavailableView {
            Label("Connect Apple Contacts", systemImage: "person.crop.circle.badge.plus")
        } description: {
            Text("Orbit mirrors your Apple contact identities, then lets you add raw notes and derived insights on top.")
        } actions: {
            Button("Grant Access") { model.requestContactsAccess() }
                .buttonStyle(.borderedProminent)
        }
    }
}

private struct AccessDeniedView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Contacts Access Disabled", systemImage: "hand.raised")
        } description: {
            Text("Enable Contacts access for Orbit in System Settings to use Apple contact sync.")
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(OrbitAppModel())
}
