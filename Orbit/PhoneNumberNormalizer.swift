import Foundation

enum PhoneNormalizationError: LocalizedError {
    case missingNumber
    case invalidNumber

    var errorDescription: String? {
        switch self {
        case .missingNumber:
            "This contact does not have a phone number to verify in WhatsApp."
        case .invalidNumber:
            "Orbit could not normalize this phone number for WhatsApp verification."
        }
    }
}

struct NormalizedPhoneNumber {
    let e164: String

    var waPathComponent: String {
        e164.filter(\.isNumber)
    }
}

enum PhoneNumberNormalizer {
    static func normalize(_ rawValue: String?, defaultRegion: String = "IT") throws -> NormalizedPhoneNumber {
        guard let rawValue = rawValue?.nonEmpty else {
            throw PhoneNormalizationError.missingNumber
        }

        let digits = sanitizedDigits(from: rawValue)
        guard !digits.isEmpty else {
            throw PhoneNormalizationError.invalidNumber
        }

        let e164: String
        if rawValue.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("+") {
            e164 = "+\(digits)"
        } else if rawValue.hasPrefix("00") {
            e164 = "+\(String(digits.dropFirst(2)))"
        } else if defaultRegion.uppercased() == "IT" {
            if digits.hasPrefix("39"), digits.count >= 9 {
                e164 = "+\(digits)"
            } else if digits.hasPrefix("0") || digits.hasPrefix("3") {
                e164 = "+39\(digits)"
            } else {
                throw PhoneNormalizationError.invalidNumber
            }
        } else {
            throw PhoneNormalizationError.invalidNumber
        }

        let normalizedDigits = e164.filter(\.isNumber)
        guard (8...15).contains(normalizedDigits.count) else {
            throw PhoneNormalizationError.invalidNumber
        }

        return NormalizedPhoneNumber(e164: e164)
    }

    private static func sanitizedDigits(from value: String) -> String {
        value.unicodeScalars
            .filter { CharacterSet.decimalDigits.contains($0) }
            .map(String.init)
            .joined()
    }
}

enum PhoneNumberDisplayFormatter {
    static func format(_ rawValue: String?) -> String? {
        guard let rawValue = rawValue?.nonEmpty else { return nil }

        let digits = rawValue.unicodeScalars
            .filter { CharacterSet.decimalDigits.contains($0) }
            .map(String.init)
            .joined()
        guard !digits.isEmpty else { return rawValue }

        if digits.hasPrefix("1"), digits.count == 11 {
            let area = String(digits.dropFirst().prefix(3))
            let prefix = String(digits.dropFirst(4).prefix(3))
            let line = String(digits.suffix(4))
            return "+1 (\(area)) \(prefix)-\(line)"
        }

        if digits.hasPrefix("39") {
            let national = String(digits.dropFirst(2))
            if national.count == 10 {
                let first = String(national.prefix(3))
                let second = String(national.dropFirst(3).prefix(3))
                let third = String(national.suffix(4))
                return "+39 \(first) \(second) \(third)"
            }
            if national.count == 9 {
                let first = String(national.prefix(2))
                let second = String(national.dropFirst(2).prefix(3))
                let third = String(national.suffix(4))
                return "+39 \(first) \(second) \(third)"
            }
        }

        if rawValue.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("+"), digits.count > 2 {
            let countryCodeLength = digits.hasPrefix("1") ? 1 : (digits.hasPrefix("39") ? 2 : min(3, max(1, digits.count - 8)))
            let countryCode = String(digits.prefix(countryCodeLength))
            let remainder = String(digits.dropFirst(countryCodeLength))
            return "+\(countryCode) \(groupRemainder(remainder))"
        }

        return groupRemainder(digits)
    }

    private static func groupRemainder(_ digits: String) -> String {
        var groups: [String] = []
        var current = digits[...]

        while current.count > 4 {
            groups.append(String(current.prefix(3)))
            current = current.dropFirst(3)
        }

        if !current.isEmpty {
            groups.append(String(current))
        }

        return groups.joined(separator: " ")
    }
}
