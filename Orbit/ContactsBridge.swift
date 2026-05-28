import Contacts
import Foundation

enum ContactsBridgeError: LocalizedError {
    case accessDenied

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            "Orbit needs access to your contacts to mirror Apple identity data."
        }
    }
}

nonisolated final class ContactsBridge {
    private let store = CNContactStore()

    nonisolated var authorizationStatus: CNAuthorizationStatus {
        CNContactStore.authorizationStatus(for: .contacts)
    }

    nonisolated func requestAccess() async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            store.requestAccess(for: .contacts) { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    nonisolated func fetchSnapshots() throws -> [ContactSyncSnapshot] {
        guard authorizationStatus == .authorized else {
            throw ContactsBridgeError.accessDenied
        }

        let keys: [CNKeyDescriptor] = [
            CNContactIdentifierKey as CNKeyDescriptor,
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactTypeKey as CNKeyDescriptor,
            CNContactJobTitleKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactPostalAddressesKey as CNKeyDescriptor,
            CNContactBirthdayKey as CNKeyDescriptor,
            CNContactThumbnailImageDataKey as CNKeyDescriptor
        ]

        var snapshots: [ContactSyncSnapshot] = []
        let request = CNContactFetchRequest(keysToFetch: keys)
        request.sortOrder = .userDefault
        try store.enumerateContacts(with: request) { contact, _ in
            snapshots.append(ContactSyncSnapshot(contact: contact))
        }
        return snapshots
    }

    nonisolated func fetchSnapshotsAsync() async throws -> [ContactSyncSnapshot] {
        try await Task.detached(priority: .userInitiated) {
            try ContactsBridge.fetchSnapshots()
        }.value
    }

    nonisolated func updateIdentity(contactIdentifier: String, identity: AppleContactIdentityDraft) async throws {
        try await Task.detached(priority: .userInitiated) {
            try ContactsBridge.updateIdentity(
                contactIdentifier: contactIdentifier,
                identity: identity
            )
        }.value
    }

    nonisolated func mergeContacts(
        targetIdentifier: String,
        sourceIdentifiers: [String],
        resolution: ContactMergeResolution
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            try ContactsBridge.mergeContacts(
                targetIdentifier: targetIdentifier,
                sourceIdentifiers: sourceIdentifiers,
                resolution: resolution
            )
        }.value
    }

    nonisolated func updateResolvedContactSummary(
        contactIdentifier: String,
        resolution: ContactMergeResolution
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            try ContactsBridge.updateResolvedContactSummary(
                contactIdentifier: contactIdentifier,
                resolution: resolution
            )
        }.value
    }

    nonisolated private static func fetchSnapshots() throws -> [ContactSyncSnapshot] {
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else {
            throw ContactsBridgeError.accessDenied
        }

        let store = CNContactStore()
        let keys: [CNKeyDescriptor] = [
            CNContactIdentifierKey as CNKeyDescriptor,
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactTypeKey as CNKeyDescriptor,
            CNContactJobTitleKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactPostalAddressesKey as CNKeyDescriptor,
            CNContactBirthdayKey as CNKeyDescriptor,
            CNContactThumbnailImageDataKey as CNKeyDescriptor
        ]

        var snapshots: [ContactSyncSnapshot] = []
        let request = CNContactFetchRequest(keysToFetch: keys)
        request.sortOrder = .userDefault
        try store.enumerateContacts(with: request) { contact, _ in
            snapshots.append(ContactSyncSnapshot(contact: contact))
        }
        return snapshots
    }

    nonisolated private static func updateIdentity(
        contactIdentifier: String,
        identity: AppleContactIdentityDraft
    ) throws {
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else {
            throw ContactsBridgeError.accessDenied
        }

        let store = CNContactStore()
        let keys: [CNKeyDescriptor] = [
            CNContactIdentifierKey as CNKeyDescriptor,
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactTypeKey as CNKeyDescriptor
        ]

        let contact = try store.unifiedContact(
            withIdentifier: contactIdentifier,
            keysToFetch: keys
        )
        guard let mutableContact = contact.mutableCopy() as? CNMutableContact else { return }

        let identity = identity.trimmed
        mutableContact.givenName = identity.givenName
        mutableContact.familyName = identity.familyName
        mutableContact.organizationName = identity.organizationName
        mutableContact.contactType = identity.isCompany ? .organization : .person

        let request = CNSaveRequest()
        request.update(mutableContact)
        try store.execute(request)
    }

    nonisolated private static func mergeContacts(
        targetIdentifier: String,
        sourceIdentifiers: [String],
        resolution: ContactMergeResolution
    ) throws {
        let sourceIdentifiers = sourceIdentifiers.filter { $0 != targetIdentifier }
        guard !sourceIdentifiers.isEmpty else { return }
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else {
            throw ContactsBridgeError.accessDenied
        }

        let store = CNContactStore()
        let keys = mergeKeys()
        let target = try store.unifiedContact(withIdentifier: targetIdentifier, keysToFetch: keys)
        guard let mutableTarget = target.mutableCopy() as? CNMutableContact else { return }
        var mutableSources: [CNMutableContact] = []

        for sourceIdentifier in sourceIdentifiers {
            let source = try store.unifiedContact(withIdentifier: sourceIdentifier, keysToFetch: keys)
            guard let mutableSource = source.mutableCopy() as? CNMutableContact else { continue }
            merge(source: source, into: mutableTarget)
            mutableSources.append(mutableSource)
        }
        apply(resolution: resolution, to: mutableTarget)

        let request = CNSaveRequest()
        request.update(mutableTarget)
        for source in mutableSources {
            request.delete(source)
        }
        try store.execute(request)
    }

    nonisolated private static func updateResolvedContactSummary(
        contactIdentifier: String,
        resolution: ContactMergeResolution
    ) throws {
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else {
            throw ContactsBridgeError.accessDenied
        }

        let store = CNContactStore()
        let contact = try store.unifiedContact(
            withIdentifier: contactIdentifier,
            keysToFetch: mergeKeys()
        )
        guard let mutableContact = contact.mutableCopy() as? CNMutableContact else { return }
        apply(resolution: resolution, to: mutableContact)

        let request = CNSaveRequest()
        request.update(mutableContact)
        try store.execute(request)
    }

    nonisolated private static func apply(
        resolution: ContactMergeResolution,
        to contact: CNMutableContact
    ) {
        let identity = resolution.identity.trimmed
        contact.givenName = identity.givenName
        contact.familyName = identity.familyName
        contact.organizationName = identity.organizationName
        contact.contactType = identity.isCompany ? .organization : .person
        contact.jobTitle = resolution.jobTitle.trimmingCharacters(in: .whitespacesAndNewlines)

        if let primaryEmail = resolution.primaryEmail?.nonEmpty {
            let didMove = moveMatchingLabeledValueToFront(&contact.emailAddresses) {
                ($0.value as String).caseInsensitiveCompare(primaryEmail) == .orderedSame
            }
            if !didMove {
                contact.emailAddresses.insert(
                    CNLabeledValue(label: CNLabelWork, value: primaryEmail as NSString),
                    at: contact.emailAddresses.startIndex
                )
            }
        }
        if let primaryPhone = resolution.primaryPhone?.nonEmpty {
            let selectedDigits = primaryPhone.filter(\.isNumber)
            let didMove = moveMatchingLabeledValueToFront(&contact.phoneNumbers) {
                $0.value.stringValue.filter(\.isNumber) == selectedDigits
            }
            if !didMove {
                contact.phoneNumbers.insert(
                    CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: primaryPhone)),
                    at: contact.phoneNumbers.startIndex
                )
            }
        }
    }

    nonisolated private static func mergeKeys() -> [CNKeyDescriptor] {
        [
            CNContactIdentifierKey as CNKeyDescriptor,
            CNContactTypeKey as CNKeyDescriptor,
            CNContactNamePrefixKey as CNKeyDescriptor,
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactMiddleNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactPreviousFamilyNameKey as CNKeyDescriptor,
            CNContactNameSuffixKey as CNKeyDescriptor,
            CNContactNicknameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactDepartmentNameKey as CNKeyDescriptor,
            CNContactJobTitleKey as CNKeyDescriptor,
            CNContactPhoneticGivenNameKey as CNKeyDescriptor,
            CNContactPhoneticMiddleNameKey as CNKeyDescriptor,
            CNContactPhoneticFamilyNameKey as CNKeyDescriptor,
            CNContactPhoneticOrganizationNameKey as CNKeyDescriptor,
            CNContactBirthdayKey as CNKeyDescriptor,
            CNContactNonGregorianBirthdayKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactPostalAddressesKey as CNKeyDescriptor,
            CNContactUrlAddressesKey as CNKeyDescriptor,
            CNContactDatesKey as CNKeyDescriptor,
            CNContactRelationsKey as CNKeyDescriptor,
            CNContactSocialProfilesKey as CNKeyDescriptor,
            CNContactInstantMessageAddressesKey as CNKeyDescriptor,
            CNContactImageDataKey as CNKeyDescriptor
        ]
    }

    nonisolated private static func merge(source: CNContact, into target: CNMutableContact) {
        fill(&target.namePrefix, with: source.namePrefix)
        fill(&target.givenName, with: source.givenName)
        fill(&target.middleName, with: source.middleName)
        fill(&target.familyName, with: source.familyName)
        fill(&target.previousFamilyName, with: source.previousFamilyName)
        fill(&target.nameSuffix, with: source.nameSuffix)
        fill(&target.nickname, with: source.nickname)
        fill(&target.organizationName, with: source.organizationName)
        fill(&target.departmentName, with: source.departmentName)
        fill(&target.jobTitle, with: source.jobTitle)
        fill(&target.phoneticGivenName, with: source.phoneticGivenName)
        fill(&target.phoneticMiddleName, with: source.phoneticMiddleName)
        fill(&target.phoneticFamilyName, with: source.phoneticFamilyName)
        fill(&target.phoneticOrganizationName, with: source.phoneticOrganizationName)

        if target.birthday == nil {
            target.birthday = source.birthday
        }
        if target.nonGregorianBirthday == nil {
            target.nonGregorianBirthday = source.nonGregorianBirthday
        }
        if target.imageData == nil {
            target.imageData = source.imageData
        }

        appendUnique(&target.emailAddresses, values: source.emailAddresses) {
            ($0.value as String).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        appendUnique(&target.phoneNumbers, values: source.phoneNumbers) {
            $0.value.stringValue.filter(\.isNumber)
        }
        appendUnique(&target.postalAddresses, values: source.postalAddresses) {
            [
                $0.value.street,
                $0.value.city,
                $0.value.state,
                $0.value.postalCode,
                $0.value.country
            ].joined(separator: "|").lowercased()
        }
        appendUnique(&target.urlAddresses, values: source.urlAddresses) {
            ($0.value as String).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        appendUnique(&target.dates, values: source.dates) {
            "\($0.value.year)-\($0.value.month)-\($0.value.day)"
        }
        appendUnique(&target.contactRelations, values: source.contactRelations) {
            $0.value.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        appendUnique(&target.socialProfiles, values: source.socialProfiles) {
            [$0.value.service, $0.value.username, $0.value.urlString].joined(separator: "|").lowercased()
        }
        appendUnique(&target.instantMessageAddresses, values: source.instantMessageAddresses) {
            [$0.value.service, $0.value.username].joined(separator: "|").lowercased()
        }
    }

    nonisolated private static func fill(_ target: inout String, with source: String) {
        if target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            target = source
        }
    }

    nonisolated private static func appendUnique<Value>(
        _ target: inout [CNLabeledValue<Value>],
        values source: [CNLabeledValue<Value>],
        key: (CNLabeledValue<Value>) -> String
    ) {
        var existing = Set(target.map(key).filter { !$0.isEmpty })
        for value in source {
            let normalizedKey = key(value)
            guard !normalizedKey.isEmpty, !existing.contains(normalizedKey) else { continue }
            target.append(value)
            existing.insert(normalizedKey)
        }
    }

    @discardableResult
    nonisolated private static func moveMatchingLabeledValueToFront<Value>(
        _ values: inout [CNLabeledValue<Value>],
        matches: (CNLabeledValue<Value>) -> Bool
    ) -> Bool {
        guard let index = values.firstIndex(where: matches) else { return false }
        guard index != values.startIndex else { return true }
        let value = values.remove(at: index)
        values.insert(value, at: values.startIndex)
        return true
    }
}
