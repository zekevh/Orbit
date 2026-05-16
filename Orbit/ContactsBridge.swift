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

final class ContactsBridge {
    private let store = CNContactStore()

    nonisolated var authorizationStatus: CNAuthorizationStatus {
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
        try await Task.detached(priority: .userInitiated) { [self] in
            try fetchSnapshots()
        }.value
    }
}
