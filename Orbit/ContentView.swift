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
        .navigationTitle("Orbit")
        .navigationSplitViewStyle(.balanced)
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search Contacts")
        .onChange(of: model.searchText) { _, _ in model.scheduleReloadList() }
        .onChange(of: model.selectedContactID) { _, _ in model.scheduleReloadSelection() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await model.refreshContactsFromStore() }
                } label: {
                    Label("Refresh Contacts", systemImage: "arrow.clockwise")
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

private struct SidebarView: View {
    @EnvironmentObject private var model: OrbitAppModel

    var body: some View {
        List(SidebarFilter.allCases, selection: $model.selectedFilter) { filter in
            Label(filter.title, systemImage: filter.systemImage)
                .tag(filter)
        }
        .listStyle(.sidebar)
        .onChange(of: model.selectedFilter) { _, _ in model.scheduleReloadList() }
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
                    set: { model.setSelection($0) }
                )) { contact in
                    ContactRow(contact: contact)
                        .tag(contact.id)
                }
                .listStyle(.inset)
            }
        }
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

                if contact.openFollowUpCount > 0 {
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

    @State private var noteKind: ContextEntryKind = .note
    @State private var noteTitle = ""
    @State private var noteBody = ""
    @State private var followUpTitle = ""
    @State private var followUpNote = ""
    @State private var followUpDate = Date()
    @State private var shouldSetDueDate = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ContactIdentityHeader(core: bundle.core, pinnedFacts: bundle.pinnedFacts)

                GroupBox("Quick Capture") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Entry Type", selection: $noteKind) {
                            ForEach(ContextEntryKind.allCases, id: \.self) { kind in
                                Text(kind.title).tag(kind)
                            }
                        }
                        .pickerStyle(.segmented)

                        TextField("Optional title", text: $noteTitle)

                        TextEditor(text: $noteBody)
                            .font(.body)
                            .frame(minHeight: 120)

                        HStack {
                            Spacer()
                            Button("Add Entry") {
                                let body = noteBody.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !body.isEmpty else { return }
                                model.addContextEntry(kind: noteKind, title: noteTitle, body: body)
                                noteTitle = ""
                                noteBody = ""
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }

                GroupBox("Follow-Up") {
                    VStack(alignment: .leading, spacing: 12) {
                        TextField("What needs to happen?", text: $followUpTitle)
                        TextField("Optional note", text: $followUpNote)
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
                }

                GroupBox("Open Follow-Ups") {
                    if bundle.openFollowUps.isEmpty {
                        Text("No pending follow-ups.")
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(bundle.openFollowUps) { followUp in
                                HStack(alignment: .top) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(followUp.title)
                                            .font(.headline)
                                        if !followUp.note.isEmpty {
                                            Text(followUp.note)
                                                .foregroundStyle(.secondary)
                                        }
                                        if let dueAt = followUp.dueAt {
                                            Label(DateFormatter.orbitTimeline.string(from: dueAt), systemImage: "calendar")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    Button("Done") {
                                        model.completeFollowUp(id: followUp.id)
                                    }
                                }
                                Divider()
                            }
                        }
                    }
                }

                GroupBox("Context Timeline") {
                    if bundle.timeline.isEmpty {
                        Text("No Orbit context yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(bundle.timeline) { entry in
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text(entry.title.nonEmpty ?? entry.kind.title)
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
                                    Divider()
                                }
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
    }
}

private struct ContactIdentityHeader: View {
    let core: ContactCore
    let pinnedFacts: [String]

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            Group {
                if let data = core.contactImageData,
                   let image = NSImage(data: data) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "person.crop.circle.fill")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(.secondary)
                        .padding(14)
                }
            }
            .frame(width: 84, height: 84)
            .background(.tertiary, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            VStack(alignment: .leading, spacing: 8) {
                Text(core.displayName)
                    .font(.largeTitle)

                if !core.roleLine.isEmpty {
                    Text(core.roleLine)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 14) {
                    if let email = core.primaryEmail {
                        Label(email, systemImage: "envelope")
                    }
                    if let phone = core.primaryPhone {
                        Label(phone, systemImage: "phone")
                    }
                }
                .font(.subheadline)

                if !core.locationLine.isEmpty {
                    Label(core.locationLine, systemImage: "mappin.and.ellipse")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
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
