import Foundation
import Contacts
import SwiftUI

enum SidebarFilter: String, CaseIterable, Identifiable {
    case allContacts
    case needsVerification
    case needsFollowUp
    case recentActivity

    var id: String { rawValue }

    var title: String {
        switch self {
        case .allContacts: "All Contacts"
        case .needsVerification: "Needs Verification"
        case .needsFollowUp: "Needs Follow-Up"
        case .recentActivity: "Recent Activity"
        }
    }

    var systemImage: String {
        switch self {
        case .allContacts: "person.crop.rectangle.stack"
        case .needsVerification: "person.crop.circle.badge.questionmark"
        case .needsFollowUp: "clock.badge.exclamationmark"
        case .recentActivity: "sparkles"
        }
    }
}

enum ContactVerificationStatus: String, CaseIterable, Codable {
    case unverified
    case pendingReview = "pending_review"
    case verified

    var title: String {
        switch self {
        case .unverified: "Unverified"
        case .pendingReview: "Pending Review"
        case .verified: "Verified"
        }
    }
}

struct ContactListItem: Identifiable, Hashable {
    let id: Int64
    let appleIdentifier: String
    let displayName: String
    let subtitle: String
    let primaryEmail: String?
    let primaryPhone: String?
    let city: String?
    let country: String?
    let lastContextAt: Date?
    let nextFollowUpAt: Date?
    let openFollowUpCount: Int
    let verificationStatus: ContactVerificationStatus
    let hasAnyImage: Bool

    nonisolated var monogram: String {
        let parts = displayName.split(separator: " ")
        let initials = parts.prefix(2).compactMap(\.first)
        return initials.isEmpty ? "?" : String(initials)
    }

    nonisolated var secondaryLine: String {
        if !subtitle.isEmpty { return subtitle }
        if let city, let country { return "\(city), \(country)" }
        if let city { return city }
        if let primaryEmail { return primaryEmail }
        if let primaryPhone { return primaryPhone }
        return "No additional context"
    }
}

struct OrbitContactBundle: Identifiable {
    let id: Int64
    let core: ContactCore
    let timeline: [ContextEntry]
    let followUps: [FollowUpItem]
    let pinnedFacts: [String]

    nonisolated var openFollowUps: [FollowUpItem] {
        followUps.filter { !$0.isCompleted }
    }
}

struct ContactCore: Identifiable {
    let id: Int64
    let appleIdentifier: String
    let givenName: String
    let familyName: String
    let displayName: String
    let organizationName: String
    let jobTitle: String
    let primaryEmail: String?
    let primaryPhone: String?
    let city: String?
    let country: String?
    let birthday: DateComponents?
    let contactImageData: Data?
    let enrichedImageData: Data?
    let enrichedImageSource: String?
    let verifiedDisplayName: String?
    let verifiedPhoneE164: String?
    let verificationStatus: ContactVerificationStatus
    let verificationNote: String
    let verifiedAt: Date?
    let lastSyncedAt: Date

    nonisolated var roleLine: String {
        let pieces = [jobTitle, organizationName].filter { !$0.isEmpty }
        return pieces.joined(separator: " at ")
    }

    nonisolated var locationLine: String {
        [city, country].compactMap { $0 }.joined(separator: ", ")
    }

    nonisolated var resolvedImageData: Data? {
        enrichedImageData ?? contactImageData
    }

    nonisolated var effectiveDisplayName: String {
        displayName
    }
}

enum ContextEntryKind: String, CaseIterable, Codable {
    case note
    case fact
    case meeting
    case preference
    case imported

    static let captureKinds: [ContextEntryKind] = [.note, .fact]

    var title: String {
        switch self {
        case .note: "Note"
        case .fact: "Fact"
        case .meeting: "Meeting"
        case .preference: "Preference"
        case .imported: "Imported"
        }
    }
}

enum ContextEntryProvenance: String, CaseIterable, Codable {
    case manual
    case agentWritten = "agent_written"
    case imported
    case systemDerived = "system_derived"

    var label: String {
        switch self {
        case .manual: "Manual"
        case .agentWritten: "Agent"
        case .imported: "Imported"
        case .systemDerived: "Derived"
        }
    }
}

struct ContextEntry: Identifiable, Hashable {
    let id: Int64
    let contactID: Int64
    let kind: ContextEntryKind
    let title: String
    let body: String
    let provenance: ContextEntryProvenance
    let createdAt: Date
}

struct FollowUpItem: Identifiable, Hashable {
    let id: Int64
    let contactID: Int64
    let title: String
    let note: String
    let dueAt: Date?
    let createdAt: Date
    let completedAt: Date?

    var isCompleted: Bool {
        completedAt != nil
    }
}

struct ContactSyncSnapshot {
    let identifier: String
    let givenName: String
    let familyName: String
    let displayName: String
    let organizationName: String
    let jobTitle: String
    let primaryEmail: String?
    let primaryPhone: String?
    let city: String?
    let country: String?
    let birthday: DateComponents?
    let imageData: Data?

    init(contact: CNContact) {
        identifier = contact.identifier
        givenName = contact.givenName
        familyName = contact.familyName
        displayName = CNContactFormatter.string(from: contact, style: .fullName)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty ?? [contact.givenName, contact.familyName].joined(separator: " ").trimmingCharacters(in: .whitespaces)
        organizationName = contact.organizationName
        jobTitle = contact.jobTitle
        primaryEmail = contact.emailAddresses.first?.value as String?
        primaryPhone = contact.phoneNumbers.first?.value.stringValue
        city = contact.postalAddresses.first?.value.city.nonEmpty
        country = contact.postalAddresses.first?.value.country.nonEmpty
        birthday = contact.birthday
        imageData = contact.thumbnailImageData
    }
}

extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension DateFormatter {
    static let orbitTimeline: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    static let orbitDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}
