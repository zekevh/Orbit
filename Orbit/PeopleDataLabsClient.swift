import Foundation

enum PeopleDataLabsClientError: LocalizedError {
    case missingAPIKey
    case missingLookupInput
    case notFound
    case requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "Set PDL_API_KEY in the launch environment or PeopleDataLabsAPIKey in UserDefaults to use reverse enrichment."
        case .missingLookupInput:
            "This contact needs an email or phone number for reverse enrichment."
        case .notFound:
            "People Data Labs did not find a matching profile."
        case .requestFailed(let message):
            message
        }
    }
}

nonisolated struct PeopleDataLabsClient: Sendable {
    private let session: URLSession
    private let apiKey: String?

    nonisolated init(
        session: URLSession = .shared,
        apiKey: String? = ProcessInfo.processInfo.environment["PDL_API_KEY"]
            ?? UserDefaults.standard.string(forKey: "PeopleDataLabsAPIKey")
    ) {
        self.session = session
        self.apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    }

    nonisolated func enrich(core: ContactCore) async throws -> PeopleDataLabsLookupResult {
        guard let apiKey else { throw PeopleDataLabsClientError.missingAPIKey }
        var components = URLComponents(string: "https://api.peopledatalabs.com/v5/person/enrich")
        var queryItems = [
            URLQueryItem(name: "pretty", value: "false"),
            URLQueryItem(name: "min_likelihood", value: "4"),
            URLQueryItem(name: "titlecase", value: "true")
        ]
        if let email = core.primaryEmail?.nonEmpty {
            queryItems.append(URLQueryItem(name: "email", value: email))
        }
        if let phone = core.primaryPhone?.nonEmpty {
            queryItems.append(URLQueryItem(name: "phone", value: phone))
        }
        if !core.organizationName.isEmpty {
            queryItems.append(URLQueryItem(name: "company", value: core.organizationName))
        }
        if !core.displayName.isEmpty {
            queryItems.append(URLQueryItem(name: "name", value: core.displayName))
        }
        guard queryItems.contains(where: { $0.name == "email" || $0.name == "phone" }) else {
            throw PeopleDataLabsClientError.missingLookupInput
        }
        components?.queryItems = queryItems
        guard let url = components?.url else {
            throw PeopleDataLabsClientError.requestFailed("Could not build People Data Labs request.")
        }

        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        let rawJSON = String(data: data, encoding: .utf8) ?? ""
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PeopleDataLabsClientError.requestFailed("People Data Labs returned an invalid response.")
        }
        let decoded = try? JSONDecoder().decode(PDLPersonEnrichmentResponse.self, from: data)
        let decodedStatus = decoded?.status
        guard (200..<300).contains(httpResponse.statusCode), decodedStatus == 200 else {
            if httpResponse.statusCode == 404 || decodedStatus == 404 {
                return PeopleDataLabsLookupResult(
                    suggestion: nil,
                    rawResponseJSON: rawJSON,
                    statusCode: httpResponse.statusCode,
                    message: decoded?.error?.message ?? "People Data Labs did not find a matching profile."
                )
            }
            return PeopleDataLabsLookupResult(
                suggestion: nil,
                rawResponseJSON: rawJSON,
                statusCode: httpResponse.statusCode,
                message: formattedFailureMessage(
                    httpStatus: httpResponse.statusCode,
                    decodedStatus: decodedStatus,
                    decodedError: decoded?.error,
                    rawJSON: rawJSON
                )
            )
        }
        guard let profile = decoded?.data else {
            return PeopleDataLabsLookupResult(
                suggestion: nil,
                rawResponseJSON: rawJSON,
                statusCode: httpResponse.statusCode,
                message: "People Data Labs did not return a person profile."
            )
        }
        return PeopleDataLabsLookupResult(
            suggestion: profile.suggestion(rawJSON: rawJSON),
            rawResponseJSON: rawJSON,
            statusCode: httpResponse.statusCode,
            message: nil
        )
    }

    private func formattedFailureMessage(
        httpStatus: Int,
        decodedStatus: Int?,
        decodedError: PDLError?,
        rawJSON: String
    ) -> String {
        let prefix = "People Data Labs request failed (\(httpStatus))"
        if let decodedError {
            let type = decodedError.type?.nonEmpty
            let message = decodedError.message?.nonEmpty
            if let type, let message {
                return "\(prefix): \(type) - \(message)"
            }
            if let message {
                return "\(prefix): \(message)"
            }
            if let type {
                return "\(prefix): \(type)"
            }
        }
        if let decodedStatus, decodedStatus != httpStatus {
            return "\(prefix). Response status \(decodedStatus). Body: \(rawJSON)"
        }
        if !rawJSON.isEmpty {
            return "\(prefix). Body: \(rawJSON)"
        }
        return prefix
    }
}

private struct PDLPersonEnrichmentResponse: Decodable {
    let status: Int
    let data: PDLPersonProfile?
    let error: PDLError?
}

private struct PDLError: Decodable {
    let type: String?
    let message: String?

    enum CodingKeys: String, CodingKey {
        case type
        case message
    }
}

private struct PDLPersonProfile: Decodable {
    let likelihood: Int?
    let firstName: String?
    let lastName: String?
    let fullName: String?
    let jobTitle: String?
    let jobCompanyName: String?
    let jobCompanyWebsite: String?
    let linkedinURL: String?
    let workEmail: String?
    let mobilePhone: String?
    let phoneNumbers: [String]?

    enum CodingKeys: String, CodingKey {
        case likelihood
        case firstName = "first_name"
        case lastName = "last_name"
        case fullName = "full_name"
        case jobTitle = "job_title"
        case jobCompanyName = "job_company_name"
        case jobCompanyWebsite = "job_company_website"
        case linkedinURL = "linkedin_url"
        case workEmail = "work_email"
        case mobilePhone = "mobile_phone"
        case phoneNumbers = "phone_numbers"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        likelihood = try container.decodeIfPresent(Int.self, forKey: .likelihood)
        firstName = Self.decodeFlexibleString(forKey: .firstName, in: container)
        lastName = Self.decodeFlexibleString(forKey: .lastName, in: container)
        fullName = Self.decodeFlexibleString(forKey: .fullName, in: container)
        jobTitle = Self.decodeFlexibleString(forKey: .jobTitle, in: container)
        jobCompanyName = Self.decodeFlexibleString(forKey: .jobCompanyName, in: container)
        jobCompanyWebsite = Self.decodeFlexibleString(forKey: .jobCompanyWebsite, in: container)
        linkedinURL = Self.decodeFlexibleString(forKey: .linkedinURL, in: container)
        workEmail = Self.decodeFlexibleString(forKey: .workEmail, in: container)
        mobilePhone = Self.decodeFlexibleString(forKey: .mobilePhone, in: container)
        phoneNumbers = Self.decodeFlexibleStringArray(forKey: .phoneNumbers, in: container)
    }

    func suggestion(rawJSON: String) -> ReverseEnrichmentSuggestion {
        ReverseEnrichmentSuggestion(
            source: "People Data Labs",
            confidence: likelihood.map { "Likelihood \($0)" },
            identity: AppleContactIdentityDraft(
                givenName: firstName?.nonEmpty ?? splitName.first,
                familyName: lastName?.nonEmpty ?? splitName.last,
                organizationName: jobCompanyName?.nonEmpty ?? "",
                isCompany: false
            ),
            jobTitle: jobTitle?.nonEmpty ?? "",
            companyWebsite: jobCompanyWebsite?.nonEmpty,
            linkedinURL: linkedinURL?.nonEmpty,
            workEmail: workEmail?.nonEmpty,
            phoneNumber: mobilePhone?.nonEmpty ?? phoneNumbers?.first?.nonEmpty,
            rawResponseJSON: rawJSON
        )
    }

    private var splitName: (first: String, last: String) {
        let parts = (fullName ?? "").split(separator: " ", omittingEmptySubsequences: true)
        guard !parts.isEmpty else { return ("", "") }
        return (
            String(parts.first ?? ""),
            parts.dropFirst().joined(separator: " ")
        )
    }

    private static func decodeFlexibleString(
        forKey key: CodingKeys,
        in container: KeyedDecodingContainer<CodingKeys>
    ) -> String? {
        if let string = try? container.decodeIfPresent(String.self, forKey: key)?.nonEmpty {
            return string
        }
        if let nested = try? container.decodeIfPresent(PDLFlexibleString.self, forKey: key)?.value {
            return nested
        }
        return nil
    }

    private static func decodeFlexibleStringArray(
        forKey key: CodingKeys,
        in container: KeyedDecodingContainer<CodingKeys>
    ) -> [String]? {
        if let strings = try? container.decodeIfPresent([String].self, forKey: key) {
            return strings.compactMap(\.nonEmpty)
        }
        if let nested = try? container.decodeIfPresent(PDLFlexibleStringArray.self, forKey: key)?.value {
            return nested
        }
        return nil
    }
}

private struct PDLFlexibleString: Decodable {
    let value: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = nil
            return
        }
        if let string = try? container.decode(String.self) {
            value = string.nonEmpty
            return
        }
        if let int = try? container.decode(Int.self) {
            value = String(int)
            return
        }
        if let double = try? container.decode(Double.self) {
            value = String(double)
            return
        }
        if let bool = try? container.decode(Bool.self) {
            value = bool ? "true" : nil
            return
        }
        value = nil
    }
}

private struct PDLFlexibleStringArray: Decodable {
    let value: [String]?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = nil
            return
        }
        if let strings = try? container.decode([String].self) {
            value = strings.compactMap(\.nonEmpty)
            return
        }
        if let string = try? container.decode(String.self), let nonEmpty = string.nonEmpty {
            value = [nonEmpty]
            return
        }
        if let bool = try? container.decode(Bool.self), bool == false {
            value = nil
            return
        }
        value = nil
    }
}
