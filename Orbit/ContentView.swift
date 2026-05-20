import AppKit
import Contacts
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: OrbitAppModel

    var body: some View {
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
                model.scheduleReloadList()
            }
        }
        .onChange(of: model.selectedContactID) { _, _ in
            Task { @MainActor in
                model.scheduleReloadSelection()
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

private struct SidebarView: View {
    @EnvironmentObject private var model: OrbitAppModel

    var body: some View {
        List(SidebarFilter.allCases, selection: $model.selectedFilter) { filter in
            Label(filter.title, systemImage: filter.systemImage)
                .tag(filter)
        }
        .listStyle(.sidebar)
        .onChange(of: model.selectedFilter) { _, _ in
            Task { @MainActor in
                model.scheduleReloadList()
            }
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
                ContentUnavailableView("No Contacts", systemImage: "person.crop.circle.badge.exclamationmark")
            } else {
                List(model.contacts, selection: Binding(
                    get: { model.selectedContactID },
                    set: { newValue in
                        Task { @MainActor in
                            model.setSelection(newValue)
                        }
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

                if contact.verificationStatus != .verified && !contact.hasAnyImage {
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
                    description: Text("Orbit mirrors Apple Contacts and lets you enrich them with context and follow-ups.")
                )
            }
        }
    }
}

private struct ContactDetailView: View {
    @EnvironmentObject private var model: OrbitAppModel
    let bundle: OrbitContactBundle

    @State private var noteBody = ""
    @State private var saveAsFact = false
    @State private var followUpTitle = ""
    @State private var followUpNote = ""
    @State private var followUpDate = Date()
    @State private var shouldSetDueDate = true
    @State private var appleDisplayName = ""

    var body: some View {
        VStack(spacing: 0) {
            ContactIdentityHeader(
                appleDisplayName: $appleDisplayName,
                core: bundle.core,
                pinnedFacts: bundle.pinnedFacts,
                openWhatsApp: {
                    model.openWhatsAppChat(contactID: bundle.id)
                },
                confirmVerification: {
                    model.confirmVerification(
                        contactID: bundle.id,
                        appleDisplayName: appleDisplayName
                    )
                },
                unverify: {
                    model.unverifyContact(contactID: bundle.id)
                }
            )
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 10)

            Form {
                Section("Orbit Context") {
                    TextField(
                        "Add professional context, background, preferences, or anything Apple Contacts does not capture well",
                        text: $noteBody,
                        axis: .vertical
                    )
                    .lineLimit(4...8)

                    Toggle("Pin this as an important fact", isOn: $saveAsFact)

                    HStack {
                        Spacer()
                        Button("Add to Orbit") {
                            let body = noteBody.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !body.isEmpty else { return }
                            model.addContextEntry(
                                kind: saveAsFact ? .fact : .note,
                                title: "",
                                body: body
                            )
                            noteBody = ""
                            saveAsFact = false
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }

                Section("Follow-Up") {
                    TextField("What needs to happen?", text: $followUpTitle)
                    TextField("Optional note", text: $followUpNote, axis: .vertical)
                        .lineLimit(2...4)
                    Toggle("Set due date", isOn: $shouldSetDueDate)
                    if shouldSetDueDate {
                        DatePicker("Due", selection: $followUpDate, displayedComponents: [.date, .hourAndMinute])
                    }
                    HStack {
                        Spacer()
                        Button("Create Follow-Up") {
                            let title = followUpTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !title.isEmpty else { return }
                            model.addFollowUp(
                                title: title,
                                note: followUpNote,
                                dueAt: shouldSetDueDate ? followUpDate : nil
                            )
                            followUpTitle = ""
                            followUpNote = ""
                        }
                        .buttonStyle(.bordered)
                    }
                }

                Section("Open Follow-Ups") {
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
                                    Button("Done") {
                                        model.completeFollowUp(id: followUp.id)
                                    }
                                }
                                if !followUp.note.isEmpty {
                                    Text(followUp.note)
                                        .foregroundStyle(.secondary)
                                }
                                if let dueAt = followUp.dueAt {
                                    Text(DateFormatter.orbitTimeline.string(from: dueAt))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                Section("Timeline") {
                    if bundle.timeline.isEmpty {
                        Text("No Orbit context yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(bundle.timeline) { entry in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(entry.kind == .fact ? "Fact" : "Note")
                                        .font(.headline)
                                    Spacer()
                                    Text(entry.provenance.label)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(DateFormatter.orbitTimeline.string(from: entry.createdAt))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Text(entry.body)
                                    .textSelection(.enabled)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
        .onAppear {
            hydrateVerificationFields()
        }
        .onChange(of: bundle.id) { _, _ in
            hydrateVerificationFields()
        }
        .onChange(of: bundle.core.verifiedAt) { _, _ in
            hydrateVerificationFields()
        }
    }

    private func hydrateVerificationFields() {
        appleDisplayName = bundle.core.displayName
    }
}

private struct ContactIdentityHeader: View {
    @Binding var appleDisplayName: String
    let core: ContactCore
    let pinnedFacts: [String]
    let openWhatsApp: () -> Void
    let confirmVerification: () -> Void
    let unverify: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            ContactAvatar(core: core)

            VStack(alignment: .leading, spacing: 8) {
                TextField("Contact name", text: $appleDisplayName)
                    .font(.largeTitle)
                    .textFieldStyle(.plain)

                if !core.roleLine.isEmpty {
                    Text(core.roleLine)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 14) {
                    if let email = core.primaryEmail {
                        CopyableContactValue(
                            systemImage: "envelope",
                            displayValue: email,
                            copyValue: email
                        )
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

                if !core.locationLine.isEmpty {
                    Label(core.locationLine, systemImage: "mappin.and.ellipse")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 10) {
                    VerificationStatusBadge(status: core.verificationStatus)
                    if let verifiedAt = core.verifiedAt {
                        Text(DateFormatter.orbitTimeline.string(from: verifiedAt))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(action: openWhatsApp) {
                        WhatsAppIcon()
                    }
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
                }

                if !pinnedFacts.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Pinned Facts")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(pinnedFacts, id: \.self) { fact in
                            Text("• \(fact)")
                                .font(.subheadline)
                        }
                    }
                }
            }
        }
    }
}

private struct ContactAvatar: View {
    let core: ContactCore

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
        ZStack {
            Circle()
                .fill(.regularMaterial)

            if let data = core.resolvedImageData,
               let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Text(initials)
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
            }
        }
        .frame(width: 96, height: 96)
        .clipShape(Circle())
        .overlay {
            Circle()
                .strokeBorder(.white.opacity(0.35), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
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
                await MainActor.run {
                    didCopy = false
                }
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
        .onHover { hovering in
            isHovered = hovering
        }
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
        case .unverified:
            .secondary
        case .pendingReview:
            .blue
        case .verified:
            .green
        }
    }
}

private struct WhatsAppIcon: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(Color(red: 0.145, green: 0.8, blue: 0.427))

            Image(systemName: "phone.fill")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: 34, height: 34)
        .overlay {
            Circle()
                .strokeBorder(.white.opacity(0.3), lineWidth: 1)
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
            Text("Orbit mirrors your Apple contact identities, then lets you add richer professional context on top.")
        } actions: {
            Button("Grant Access") {
                model.requestContactsAccess()
            }
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
