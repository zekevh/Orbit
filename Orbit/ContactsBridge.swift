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

@MainActor
final class ContactsBridge {
    private let store = CNContactStore()

    var authorizationStatus: CNAuthorizationStatus {
        CNContactStore.authorizationStatus(for: .contacts)
    }

    func requestAccess() async throws -> Bool {
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

    func fetchSnapshots() throws -> [ContactSyncSnapshot] {
        guard authorizationStatus == .authorized else {
            throw ContactsBridgeError.accessDenied
        }

        let keys: [CNKeyDescriptor] = [
            CNContactIdentifierKey as CNKeyDescriptor,
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
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

    func fetchSnapshotsAsync() async throws -> [ContactSyncSnapshot] {
        try fetchSnapshots()
    }

    func updateDisplayName(contactIdentifier: String, displayName: String) throws {
        guard authorizationStatus == .authorized else {
            throw ContactsBridgeError.accessDenied
        }

        let keys: [CNKeyDescriptor] = [
            CNContactIdentifierKey as CNKeyDescriptor,
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactMiddleNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactNamePrefixKey as CNKeyDescriptor,
            CNContactNameSuffixKey as CNKeyDescriptor
        ]

        let contact = try store.unifiedContact(withIdentifier: contactIdentifier, keysToFetch: keys)
        guard let mutableContact = contact.mutableCopy() as? CNMutableContact else { return }

        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let formatter = PersonNameComponentsFormatter()
        if let components = formatter.personNameComponents(from: trimmed) {
            mutableContact.namePrefix = components.namePrefix ?? ""
            mutableContact.givenName = components.givenName ?? ""
            mutableContact.middleName = components.middleName ?? ""
            mutableContact.familyName = components.familyName ?? ""
            mutableContact.nameSuffix = components.nameSuffix ?? ""
        } else {
            mutableContact.namePrefix = ""
            mutableContact.givenName = trimmed
            mutableContact.middleName = ""
            mutableContact.familyName = ""
            mutableContact.nameSuffix = ""
        }

        let request = CNSaveRequest()
        request.update(mutableContact)
        try store.execute(request)
    }
}
