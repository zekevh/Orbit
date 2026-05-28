import Contacts
import Foundation
import SwiftUI

enum SidebarFilter: String, CaseIterable, Identifiable {
    case allContacts
    case needsVerification
    case duplicates
    case needsFollowUp
    case recentActivity
    case archived

    var id: String { rawValue }

    var title: String {
        switch self {
        case .allContacts: "All Contacts"
        case .needsVerification: "Needs Verification"
        case .duplicates: "Duplicates"
        case .needsFollowUp: "Needs Follow-Up"
        case .recentActivity: "Recent Activity"
        case .archived: "Archived"
        }
    }

    var systemImage: String {
        switch self {
        case .allContacts: "person.crop.rectangle.stack"
        case .needsVerification: "person.crop.circle.badge.questionmark"
        case .duplicates: "person.2.badge.gearshape"
        case .needsFollowUp: "clock.badge.exclamationmark"
        case .recentActivity: "sparkles"
        case .archived: "archivebox"
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

enum DuplicateMatchKind: String, CaseIterable {
    case phone
    case email
    case name

    var title: String {
        switch self {
        case .phone: "Same Phone"
        case .email: "Same Email"
        case .name: "Same Name"
        }
    }

    var systemImage: String {
        switch self {
        case .phone: "phone"
        case .email: "envelope"
        case .name: "person.text.rectangle"
        }
    }
}

struct ContactDuplicateGroup: Identifiable, Hashable {
    let kind: DuplicateMatchKind
    let value: String
    let contacts: [ContactListItem]

    nonisolated var id: String {
        "\(kind.rawValue):\(value)"
    }

    nonisolated var title: String {
        "\(kind.title): \(value)"
    }
}

struct ContactMergeCandidate: Identifiable, Hashable, Sendable {
    let id: Int64
    let appleIdentifier: String
    let displayName: String
    let givenName: String
    let familyName: String
    let organizationName: String
    let isCompany: Bool
    let jobTitle: String
    let primaryEmail: String?
    let primaryPhone: String?
}

struct ContactMergeDraft: Identifiable, Hashable {
    let group: ContactDuplicateGroup
    let targetID: Int64
    let candidates: [ContactMergeCandidate]

    var id: String {
        "\(group.id):\(targetID)"
    }

    var target: ContactMergeCandidate? {
        candidates.first { $0.id == targetID }
    }
}

struct ContactMergeResolution: Sendable {
    var identity: AppleContactIdentityDraft
    var jobTitle: String
    var primaryEmail: String?
    var primaryPhone: String?
}

struct ReverseEnrichmentSuggestion: Identifiable, Sendable {
    let id = UUID()
    let source: String
    let confidence: String?
    let identity: AppleContactIdentityDraft
    let jobTitle: String
    let companyWebsite: String?
    let linkedinURL: String?
    let workEmail: String?
    let phoneNumber: String?
    let rawResponseJSON: String
}

struct PeopleDataLabsLookupResult: Sendable {
    let suggestion: ReverseEnrichmentSuggestion?
    let rawResponseJSON: String
    let statusCode: Int
    let message: String?
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
    let lastActivityAt: Date?
    let nextFollowUpAt: Date?
    let openFollowUpCount: Int
    let verificationStatus: ContactVerificationStatus
    let hasAnyImage: Bool
    let isArchived: Bool

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
    let notes: [OrbitNote]
    let insights: [Insight]
    let followUps: [FollowUpItem]

    nonisolated var openFollowUps: [FollowUpItem] {
        followUps.filter { !$0.isCompleted }
    }

    nonisolated var completedFollowUps: [FollowUpItem] {
        followUps.filter(\.isCompleted)
    }
}

nonisolated struct AppleContactIdentityDraft: Sendable {
    var givenName: String
    var familyName: String
    var organizationName: String
    var isCompany: Bool

    nonisolated init(
        givenName: String = "",
        familyName: String = "",
        organizationName: String = "",
        isCompany: Bool = false
    ) {
        self.givenName = givenName
        self.familyName = familyName
        self.organizationName = organizationName
        self.isCompany = isCompany
    }

    nonisolated init(core: ContactCore) {
        givenName = core.givenName
        familyName = core.familyName
        organizationName = core.organizationName
        isCompany = core.isCompany
    }

    nonisolated var trimmed: AppleContactIdentityDraft {
        AppleContactIdentityDraft(
            givenName: givenName.trimmingCharacters(in: .whitespacesAndNewlines),
            familyName: familyName.trimmingCharacters(in: .whitespacesAndNewlines),
            organizationName: organizationName.trimmingCharacters(in: .whitespacesAndNewlines),
            isCompany: isCompany
        )
    }

    nonisolated var displayName: String {
        let identity = trimmed
        if identity.isCompany, let organization = identity.organizationName.nonEmpty {
            return organization
        }
        return [identity.givenName, identity.familyName]
            .compactMap(\.nonEmpty)
            .joined(separator: " ")
            .nonEmpty ?? identity.organizationName.nonEmpty ?? "Unknown Contact"
    }
}

struct ContactCore: Identifiable {
    let id: Int64
    let appleIdentifier: String
    let givenName: String
    let familyName: String
    let displayName: String
    let organizationName: String
    let isCompany: Bool
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
    let isArchived: Bool
    let archivedAt: Date?

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
}

enum NoteSource: String, CaseIterable, Codable {
    case manual
    case agent
    case imported
    case system

    var label: String {
        switch self {
        case .manual: "Manual"
        case .agent: "Agent"
        case .imported: "Imported"
        case .system: "System"
        }
    }
}

struct OrbitNote: Identifiable, Hashable {
    let id: Int64
    let contactID: Int64
    let body: String
    let source: NoteSource
    let createdAt: Date
}

enum InsightKind: String, CaseIterable, Codable {
    case general
    case summary
    case fact
    case preference
    case relationship
    case priority

    var title: String {
        switch self {
        case .general: "General"
        case .summary: "Summary"
        case .fact: "Fact"
        case .preference: "Preference"
        case .relationship: "Relationship"
        case .priority: "Priority"
        }
    }
}

enum InsightSource: String, CaseIterable, Codable {
    case human
    case agent
    case imported
    case system

    var label: String {
        switch self {
        case .human: "Human"
        case .agent: "Agent"
        case .imported: "Imported"
        case .system: "System"
        }
    }
}

struct Insight: Identifiable, Hashable {
    let id: Int64
    let contactID: Int64
    let body: String
    let kind: InsightKind
    let source: InsightSource
    let createdAt: Date
    let updatedAt: Date
}

enum FollowUpSource: String, CaseIterable, Codable {
    case agent
    case imported
    case system

    var label: String {
        switch self {
        case .agent: "Agent"
        case .imported: "Imported"
        case .system: "System"
        }
    }
}

struct FollowUpItem: Identifiable, Hashable {
    let id: Int64
    let contactID: Int64
    let title: String
    let note: String
    let dueAt: Date?
    let source: FollowUpSource
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
    let isCompany: Bool
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
        isCompany = contact.contactType == .organization
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
    nonisolated var nonEmpty: String? {
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
