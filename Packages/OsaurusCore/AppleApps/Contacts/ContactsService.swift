//
//  ContactsService.swift
//  osaurus
//
//  Contacts.framework-backed access for the built-in `contacts_*` tools.
//  Uses `CNContactFormatter` for display names, `CNPhoneNumber` predicates
//  for phone matching (no suffix hacks), and returns stable identifiers so
//  follow-up calls address a card directly.
//

@preconcurrency import Contacts
import Foundation

// MARK: - Models

struct LabeledValue: Codable, Equatable, Sendable {
    let label: String?
    let value: String
}

struct PostalAddressInfo: Codable, Equatable, Sendable {
    let label: String?
    let street: String
    let city: String
    let state: String
    let postalCode: String
    let country: String
    let formatted: String
}

struct ContactInfo: Codable, Equatable, Sendable {
    let id: String
    let displayName: String
    let givenName: String
    let familyName: String
    let middleName: String?
    let nickname: String?
    let organization: String?
    let jobTitle: String?
    let department: String?
    let phones: [LabeledValue]
    let emails: [LabeledValue]
    let urls: [LabeledValue]
    let postalAddresses: [PostalAddressInfo]
    let birthday: String?
    let relations: [LabeledValue]
    let socialProfiles: [LabeledValue]
    let hasImage: Bool
    let openURL: String
}

/// Compact card used in search/list results.
struct ContactSummary: Codable, Equatable, Sendable {
    let id: String
    let displayName: String
    let organization: String?
    let phones: [LabeledValue]
    let emails: [LabeledValue]
}

struct ContactDraft: Sendable {
    var givenName: String?
    var familyName: String?
    var middleName: String?
    var nickname: String?
    var organization: String?
    var jobTitle: String?
    var department: String?
    var phones: [LabeledValue]?
    var emails: [LabeledValue]?
    var urls: [LabeledValue]?
    var postalAddresses: [PostalAddressInfo]?
    var birthday: DateComponents?
}

enum ContactSearchField: String, Sendable {
    case any
    case name
    case phone
    case email
    case organization
}

// MARK: - Protocol

protocol ContactsServicing: Sendable {
    func me() async throws -> ContactInfo?
    func search(query: String, field: ContactSearchField) async throws -> [ContactSummary]
    func list(offset: Int, limit: Int) async throws -> (contacts: [ContactSummary], total: Int)
    func contact(id: String) async throws -> ContactInfo
    func create(_ draft: ContactDraft) async throws -> ContactInfo
    func update(id: String, draft: ContactDraft, replaceLabeledValues: Bool) async throws -> ContactInfo
}

// MARK: - Contacts.framework implementation

final class CNContactsService: ContactsServicing, @unchecked Sendable {
    /// Confined to `AppleServiceQueue`; created on first use so registering
    /// the tools never touches contactsd.
    nonisolated(unsafe) private lazy var store = CNContactStore()

    /// Keys needed to render a full card (and `CNContactFormatter`).
    nonisolated(unsafe) private static let fullKeys: [CNKeyDescriptor] = [
        CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
        CNContactIdentifierKey as CNKeyDescriptor,
        CNContactGivenNameKey as CNKeyDescriptor,
        CNContactFamilyNameKey as CNKeyDescriptor,
        CNContactMiddleNameKey as CNKeyDescriptor,
        CNContactNicknameKey as CNKeyDescriptor,
        CNContactOrganizationNameKey as CNKeyDescriptor,
        CNContactJobTitleKey as CNKeyDescriptor,
        CNContactDepartmentNameKey as CNKeyDescriptor,
        CNContactPhoneNumbersKey as CNKeyDescriptor,
        CNContactEmailAddressesKey as CNKeyDescriptor,
        CNContactUrlAddressesKey as CNKeyDescriptor,
        CNContactPostalAddressesKey as CNKeyDescriptor,
        CNContactBirthdayKey as CNKeyDescriptor,
        CNContactRelationsKey as CNKeyDescriptor,
        CNContactSocialProfilesKey as CNKeyDescriptor,
        CNContactImageDataAvailableKey as CNKeyDescriptor,
    ]

    /// Lighter key set for search/list rows.
    nonisolated(unsafe) private static let summaryKeys: [CNKeyDescriptor] = [
        CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
        CNContactIdentifierKey as CNKeyDescriptor,
        CNContactNicknameKey as CNKeyDescriptor,
        CNContactOrganizationNameKey as CNKeyDescriptor,
        CNContactPhoneNumbersKey as CNKeyDescriptor,
        CNContactEmailAddressesKey as CNKeyDescriptor,
    ]

    private func requireAccess() throws {
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else {
            throw AppleToolError.permissionDenied(.contacts)
        }
    }

    func me() async throws -> ContactInfo? {
        try await AppleServiceQueue.run { [self] in
            try self.requireAccess()
            do {
                let contact = try self.store.unifiedMeContactWithKeys(toFetch: Self.fullKeys)
                return Self.info(contact)
            } catch let error as NSError where error.domain == CNErrorDomain && error.code == CNError.recordDoesNotExist.rawValue {
                return nil
            } catch {
                throw AppleToolError.execution("Contacts could not load your card: \(error.localizedDescription)")
            }
        }
    }

    func search(query: String, field: ContactSearchField) async throws -> [ContactSummary] {
        try await AppleServiceQueue.run { [self] in
            try self.requireAccess()
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            var results: [CNContact] = []
            var seen = Set<String>()
            func add(_ contacts: [CNContact]) {
                for c in contacts where !seen.contains(c.identifier) {
                    seen.insert(c.identifier)
                    results.append(c)
                }
            }
            let looksLikePhone = Self.looksLikePhoneNumber(trimmed)
            let looksLikeEmail = trimmed.contains("@")
            if field == .name || (field == .any && !looksLikePhone && !looksLikeEmail) {
                add(try self.fetch(matching: CNContact.predicateForContacts(matchingName: trimmed), keys: Self.summaryKeys))
            }
            if field == .phone || (field == .any && looksLikePhone) {
                add(try self.fetch(
                    matching: CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: trimmed)),
                    keys: Self.summaryKeys
                ))
            }
            if field == .email || (field == .any && looksLikeEmail) {
                add(try self.fetch(
                    matching: CNContact.predicateForContacts(matchingEmailAddress: trimmed), keys: Self.summaryKeys
                ))
            }
            // Organization + nickname + partial phone/email fall back to a
            // scan of the unified contacts (the predicates above are exact
            // or prefix matches only).
            if results.isEmpty || field == .organization || field == .any {
                let all = try self.allContacts(keys: Self.summaryKeys)
                let digits = Self.digits(trimmed)
                add(all.filter { c in
                    switch field {
                    case .organization:
                        return AppleServiceSupport.matches(c.organizationName, query: trimmed)
                    case .name:
                        return AppleServiceSupport.matches(c.nickname, query: trimmed)
                            || AppleServiceSupport.matches(CNContactFormatter.string(from: c, style: .fullName), query: trimmed)
                    case .phone:
                        return !digits.isEmpty && c.phoneNumbers.contains { Self.digits($0.value.stringValue).contains(digits) }
                    case .email:
                        return c.emailAddresses.contains { AppleServiceSupport.matches($0.value as String, query: trimmed) }
                    case .any:
                        if AppleServiceSupport.matches(c.organizationName, query: trimmed) { return true }
                        if AppleServiceSupport.matches(c.nickname, query: trimmed) { return true }
                        if AppleServiceSupport.matches(CNContactFormatter.string(from: c, style: .fullName), query: trimmed) { return true }
                        if looksLikeEmail, c.emailAddresses.contains(where: { AppleServiceSupport.matches($0.value as String, query: trimmed) }) { return true }
                        if !digits.isEmpty, digits.count >= 4,
                            c.phoneNumbers.contains(where: { Self.digits($0.value.stringValue).contains(digits) })
                        { return true }
                        return false
                    }
                })
            }
            return results.map(Self.summary).sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        }
    }

    func list(offset: Int, limit: Int) async throws -> (contacts: [ContactSummary], total: Int) {
        try await AppleServiceQueue.run { [self] in
            try self.requireAccess()
            let all = try self.allContacts(keys: Self.summaryKeys)
                .map(Self.summary)
                .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            let start = min(max(0, offset), all.count)
            let end = min(start + limit, all.count)
            return (Array(all[start ..< end]), all.count)
        }
    }

    func contact(id: String) async throws -> ContactInfo {
        try await AppleServiceQueue.run { [self] in
            try self.requireAccess()
            return Self.info(try self.fetchOne(id: id, keys: Self.fullKeys))
        }
    }

    func create(_ draft: ContactDraft) async throws -> ContactInfo {
        try await AppleServiceQueue.run { [self] in
            try self.requireAccess()
            let contact = CNMutableContact()
            Self.apply(draft, to: contact, replaceLabeledValues: true)
            let request = CNSaveRequest()
            request.add(contact, toContainerWithIdentifier: nil)
            do {
                try self.store.execute(request)
            } catch {
                throw AppleToolError.execution("Contacts refused to create the contact: \(error.localizedDescription)")
            }
            return Self.info(try self.fetchOne(id: contact.identifier, keys: Self.fullKeys))
        }
    }

    func update(id: String, draft: ContactDraft, replaceLabeledValues: Bool) async throws -> ContactInfo {
        try await AppleServiceQueue.run { [self] in
            try self.requireAccess()
            guard let mutable = try self.fetchOne(id: id, keys: Self.fullKeys).mutableCopy() as? CNMutableContact else {
                throw AppleToolError.execution("Contact `\(id)` could not be edited.")
            }
            Self.apply(draft, to: mutable, replaceLabeledValues: replaceLabeledValues)
            let request = CNSaveRequest()
            request.update(mutable)
            do {
                try self.store.execute(request)
            } catch {
                throw AppleToolError.execution("Contacts refused to update the contact: \(error.localizedDescription)")
            }
            return Self.info(try self.fetchOne(id: id, keys: Self.fullKeys))
        }
    }

    // MARK: Helpers

    private func fetch(matching predicate: NSPredicate, keys: [CNKeyDescriptor]) throws -> [CNContact] {
        do {
            return try store.unifiedContacts(matching: predicate, keysToFetch: keys)
        } catch {
            throw AppleToolError.execution("Contacts search failed: \(error.localizedDescription)")
        }
    }

    private func fetchOne(id: String, keys: [CNKeyDescriptor]) throws -> CNContact {
        do {
            return try store.unifiedContact(withIdentifier: id, keysToFetch: keys)
        } catch {
            throw AppleToolError.notFound(
                "No contact with identifier `\(id)`. Call `contacts_search` and pass one of its `id` values."
            )
        }
    }

    private func allContacts(keys: [CNKeyDescriptor]) throws -> [CNContact] {
        let request = CNContactFetchRequest(keysToFetch: keys)
        request.unifyResults = true
        request.sortOrder = .userDefault
        var out: [CNContact] = []
        do {
            try store.enumerateContacts(with: request) { contact, _ in out.append(contact) }
        } catch {
            throw AppleToolError.execution("Contacts enumeration failed: \(error.localizedDescription)")
        }
        return out
    }

    static func looksLikePhoneNumber(_ s: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "+0123456789 ()-.")
        return s.count >= 3 && s.unicodeScalars.allSatisfy { allowed.contains($0) } && digits(s).count >= 3
    }

    static func digits(_ s: String) -> String {
        s.filter(\.isNumber)
    }

    private static func apply(_ draft: ContactDraft, to contact: CNMutableContact, replaceLabeledValues: Bool) {
        if let v = draft.givenName { contact.givenName = v }
        if let v = draft.familyName { contact.familyName = v }
        if let v = draft.middleName { contact.middleName = v }
        if let v = draft.nickname { contact.nickname = v }
        if let v = draft.organization { contact.organizationName = v }
        if let v = draft.jobTitle { contact.jobTitle = v }
        if let v = draft.department { contact.departmentName = v }
        if let v = draft.birthday { contact.birthday = v }
        if let phones = draft.phones {
            let new = phones.map { CNLabeledValue(label: label($0.label), value: CNPhoneNumber(stringValue: $0.value)) }
            contact.phoneNumbers = replaceLabeledValues ? new : merge(contact.phoneNumbers, new) { $0.value.stringValue == $1.value.stringValue }
        }
        if let emails = draft.emails {
            let new = emails.map { CNLabeledValue(label: label($0.label), value: $0.value as NSString) }
            contact.emailAddresses = replaceLabeledValues ? new : merge(contact.emailAddresses, new) { ($0.value as String).caseInsensitiveCompare($1.value as String) == .orderedSame }
        }
        if let urls = draft.urls {
            let new = urls.map { CNLabeledValue(label: label($0.label), value: $0.value as NSString) }
            contact.urlAddresses = replaceLabeledValues ? new : merge(contact.urlAddresses, new) { ($0.value as String) == ($1.value as String) }
        }
        if let addresses = draft.postalAddresses {
            let new = addresses.map { a -> CNLabeledValue<CNPostalAddress> in
                let p = CNMutablePostalAddress()
                p.street = a.street
                p.city = a.city
                p.state = a.state
                p.postalCode = a.postalCode
                p.country = a.country
                return CNLabeledValue(label: label(a.label), value: p)
            }
            contact.postalAddresses = replaceLabeledValues ? new : merge(contact.postalAddresses, new) { $0.value == $1.value }
        }
    }

    private static func merge<T: NSCopying & NSSecureCoding>(
        _ existing: [CNLabeledValue<T>], _ new: [CNLabeledValue<T>], same: (CNLabeledValue<T>, CNLabeledValue<T>) -> Bool
    ) -> [CNLabeledValue<T>] {
        var out = existing
        for n in new where !out.contains(where: { same($0, n) }) { out.append(n) }
        return out
    }

    /// Map friendly labels (home / work / mobile / main / other / custom) to
    /// the CN constants; anything else is kept as a custom label.
    static func label(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty else { return nil }
        switch raw {
        case "home": return CNLabelHome
        case "work": return CNLabelWork
        case "other": return CNLabelOther
        case "mobile", "cell": return CNLabelPhoneNumberMobile
        case "iphone": return CNLabelPhoneNumberiPhone
        case "main": return CNLabelPhoneNumberMain
        case "home fax": return CNLabelPhoneNumberHomeFax
        case "work fax": return CNLabelPhoneNumberWorkFax
        case "pager": return CNLabelPhoneNumberPager
        case "homepage": return CNLabelURLAddressHomePage
        case "school": return CNLabelSchool
        default: return raw
        }
    }

    static func localizedLabel(_ label: String?) -> String? {
        guard let label, !label.isEmpty else { return nil }
        return CNLabeledValue<NSString>.localizedString(forLabel: label)
    }

    private static func summary(_ c: CNContact) -> ContactSummary {
        ContactSummary(
            id: c.identifier,
            displayName: displayName(c),
            organization: c.organizationName.isEmpty ? nil : c.organizationName,
            phones: c.phoneNumbers.map { LabeledValue(label: localizedLabel($0.label), value: $0.value.stringValue) },
            emails: c.emailAddresses.map { LabeledValue(label: localizedLabel($0.label), value: $0.value as String) }
        )
    }

    private static func displayName(_ c: CNContact) -> String {
        if let name = CNContactFormatter.string(from: c, style: .fullName), !name.isEmpty { return name }
        if c.isKeyAvailable(CNContactNicknameKey), !c.nickname.isEmpty { return c.nickname }
        if c.isKeyAvailable(CNContactOrganizationNameKey), !c.organizationName.isEmpty { return c.organizationName }
        if let email = c.emailAddresses.first?.value as String? { return email }
        if let phone = c.phoneNumbers.first?.value.stringValue { return phone }
        return L("Unnamed contact")
    }

    private static func info(_ c: CNContact) -> ContactInfo {
        let postal = CNPostalAddressFormatter()
        var birthday: String?
        if let b = c.birthday {
            if let y = b.year, let m = b.month, let d = b.day {
                birthday = String(format: "%04d-%02d-%02d", y, m, d)
            } else if let m = b.month, let d = b.day {
                birthday = String(format: "--%02d-%02d", m, d)
            }
        }
        return ContactInfo(
            id: c.identifier,
            displayName: displayName(c),
            givenName: c.givenName,
            familyName: c.familyName,
            middleName: c.middleName.isEmpty ? nil : c.middleName,
            nickname: c.nickname.isEmpty ? nil : c.nickname,
            organization: c.organizationName.isEmpty ? nil : c.organizationName,
            jobTitle: c.jobTitle.isEmpty ? nil : c.jobTitle,
            department: c.departmentName.isEmpty ? nil : c.departmentName,
            phones: c.phoneNumbers.map { LabeledValue(label: localizedLabel($0.label), value: $0.value.stringValue) },
            emails: c.emailAddresses.map { LabeledValue(label: localizedLabel($0.label), value: $0.value as String) },
            urls: c.urlAddresses.map { LabeledValue(label: localizedLabel($0.label), value: $0.value as String) },
            postalAddresses: c.postalAddresses.map {
                PostalAddressInfo(
                    label: localizedLabel($0.label),
                    street: $0.value.street,
                    city: $0.value.city,
                    state: $0.value.state,
                    postalCode: $0.value.postalCode,
                    country: $0.value.country,
                    formatted: postal.string(from: $0.value).replacingOccurrences(of: "\n", with: ", ")
                )
            },
            birthday: birthday,
            relations: c.contactRelations.map { LabeledValue(label: localizedLabel($0.label), value: $0.value.name) },
            socialProfiles: c.socialProfiles.map {
                LabeledValue(label: $0.value.service, value: $0.value.username.isEmpty ? $0.value.urlString : $0.value.username)
            },
            hasImage: c.imageDataAvailable,
            openURL: "addressbook://\(c.identifier)"
        )
    }
}
