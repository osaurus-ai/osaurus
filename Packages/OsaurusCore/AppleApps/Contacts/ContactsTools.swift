//
//  ContactsTools.swift
//  osaurus
//
//  Built-in `contacts_*` tools (per-agent opt-in via `AppleApp.contacts`).
//

import AppKit
import Foundation

enum ContactsToolFactory {
    static func makeTools(service: ContactsServicing = CNContactsService()) -> [OsaurusTool] {
        [
            ContactsMeTool(service: service),
            ContactsSearchTool(service: service),
            ContactsListTool(service: service),
            ContactsGetTool(service: service),
            ContactsCreateTool(service: service),
            ContactsUpdateTool(service: service),
            ContactsOpenTool(service: service),
        ]
    }

    static let labeledValueSchema = AppleSchema.object([:])

    /// Parse `[{label, value}]` or `["value", …]` into labeled values.
    static func labeledValues(_ args: [String: Any], _ key: String) throws -> [LabeledValue]? {
        guard let raw = args[key], !(raw is NSNull) else { return nil }
        if let s = raw as? String {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [LabeledValue(label: nil, value: trimmed)]
        }
        guard let arr = raw as? [Any] else {
            throw AppleToolError.invalidArgs(
                "`\(key)` must be an array of strings or of {label, value} objects.", field: key
            )
        }
        return try arr.map { item -> LabeledValue in
            if let s = item as? String { return LabeledValue(label: nil, value: s) }
            if let d = item as? [String: Any], let v = (d["value"] as? String) ?? (d["number"] as? String) ?? (d["email"] as? String) {
                return LabeledValue(label: d["label"] as? String, value: v)
            }
            throw AppleToolError.invalidArgs(
                "`\(key)` entries must be strings or {label, value} objects.", field: key
            )
        }
    }

    static func postalAddresses(_ args: [String: Any]) throws -> [PostalAddressInfo]? {
        guard let raw = args["postal_addresses"], !(raw is NSNull) else { return nil }
        guard let arr = raw as? [Any] else {
            throw AppleToolError.invalidArgs("`postal_addresses` must be an array of address objects.", field: "postal_addresses")
        }
        return try arr.map { item in
            guard let d = item as? [String: Any] else {
                throw AppleToolError.invalidArgs("`postal_addresses` entries must be objects.", field: "postal_addresses")
            }
            let street = (d["street"] as? String) ?? ""
            let city = (d["city"] as? String) ?? ""
            let state = (d["state"] as? String) ?? ""
            let postal = (d["postal_code"] as? String) ?? (d["zip"] as? String) ?? ""
            let country = (d["country"] as? String) ?? ""
            return PostalAddressInfo(
                label: d["label"] as? String, street: street, city: city, state: state, postalCode: postal,
                country: country,
                formatted: [street, city, state, postal, country].filter { !$0.isEmpty }.joined(separator: ", ")
            )
        }
    }

    static func birthday(_ args: [String: Any]) throws -> DateComponents? {
        guard let raw = try AppleArgs.string(args, "birthday") else { return nil }
        let parts = raw.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        var comps = DateComponents()
        if parts.count == 3, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) {
            comps.year = y
            comps.month = m
            comps.day = d
            return comps
        }
        if parts.count == 4, parts[0].isEmpty, parts[1].isEmpty, let m = Int(parts[2]), let d = Int(parts[3]) {
            comps.month = m
            comps.day = d
            return comps
        }
        throw AppleToolError.invalidArgs("`birthday` must be YYYY-MM-DD or --MM-DD.", field: "birthday")
    }

    static func draft(from args: [String: Any]) throws -> ContactDraft {
        ContactDraft(
            givenName: try AppleArgs.string(args, "given_name"),
            familyName: try AppleArgs.string(args, "family_name"),
            middleName: try AppleArgs.string(args, "middle_name"),
            nickname: try AppleArgs.string(args, "nickname"),
            organization: try AppleArgs.string(args, "organization"),
            jobTitle: try AppleArgs.string(args, "job_title"),
            department: try AppleArgs.string(args, "department"),
            phones: try labeledValues(args, "phones"),
            emails: try labeledValues(args, "emails"),
            urls: try labeledValues(args, "urls"),
            postalAddresses: try postalAddresses(args),
            birthday: try birthday(args)
        )
    }

    /// Array whose items are either a bare string or a labeled object —
    /// the two shapes `labeledValues` parses. Declared with `anyOf` so the
    /// schema validator accepts both instead of rejecting strings.
    static func labeledArraySchema(_ description: String, valueKeys: [String]) -> JSONValue {
        var props: [String: JSONValue] = ["label": AppleSchema.string("Label (e.g. mobile, home, work).")]
        for key in valueKeys { props[key] = AppleSchema.string("The value.") }
        return .object([
            "type": .string("array"),
            "description": .string(description),
            "items": .object([
                "anyOf": .array([
                    AppleSchema.string("A bare value."),
                    AppleSchema.nested("A labeled value.", props),
                ])
            ]),
        ])
    }

    static var draftProperties: [String: JSONValue] {
        [
            "given_name": AppleSchema.string("First name."),
            "family_name": AppleSchema.string("Last name."),
            "middle_name": AppleSchema.string("Middle name."),
            "nickname": AppleSchema.string("Nickname."),
            "organization": AppleSchema.string("Company / organization."),
            "job_title": AppleSchema.string("Job title."),
            "department": AppleSchema.string("Department."),
            "phones": labeledArraySchema(
                "Phone numbers: strings or {label, value} objects (label: mobile | home | work | main | other | custom text).",
                valueKeys: ["value", "number"]
            ),
            "emails": labeledArraySchema(
                "Email addresses: strings or {label, value} objects (label: home | work | other | custom text).",
                valueKeys: ["value", "email"]
            ),
            "urls": labeledArraySchema("URLs: strings or {label, value} objects.", valueKeys: ["value"]),
            "postal_addresses": .object([
                "type": .string("array"),
                "description": .string("Addresses: {label, street, city, state, postal_code, country} objects."),
                "items": AppleSchema.nested(
                    "One postal address.",
                    [
                        "label": AppleSchema.string("home | work | other | custom text."),
                        "street": AppleSchema.string("Street address (may span lines)."),
                        "city": AppleSchema.string("City."),
                        "state": AppleSchema.string("State / region."),
                        "postal_code": AppleSchema.string("Postal / ZIP code."),
                        "zip": AppleSchema.string("Alias for postal_code."),
                        "country": AppleSchema.string("Country."),
                    ]
                ),
            ]),
            "birthday": AppleSchema.string("Birthday as YYYY-MM-DD, or --MM-DD without a year."),
        ]
    }
}

// MARK: - contacts_me

final class ContactsMeTool: AppleToolBase, @unchecked Sendable {
    private let service: ContactsServicing

    init(service: ContactsServicing) {
        self.service = service
        super.init(
            app: .contacts,
            name: "contacts_me",
            description: "Return the user's own contact card (name, phones, emails, addresses, birthday) when one is set in Contacts.",
            parameters: AppleSchema.object([:]),
            isWrite: false
        )
    }

    override func run(args: [String: Any]) async throws -> AppleToolPayload {
        guard let me = try await service.me() else {
            return AppleToolPayload(["contact": NSNull(), "found": false], warnings: ["No \"My Card\" is set in Contacts."])
        }
        return AppleToolPayload(["contact": me, "found": true])
    }
}

// MARK: - contacts_search

final class ContactsSearchTool: AppleToolBase, @unchecked Sendable {
    private let service: ContactsServicing
    static let defaultLimit = 25

    init(service: ContactsServicing) {
        self.service = service
        super.init(
            app: .contacts,
            name: "contacts_search",
            description:
                "Search contacts by name, nickname, phone number, email, or organization. `field: any` (default) infers phone/email from the query. Returns compact cards with a stable `id` for contacts_get / contacts_update / contacts_open.",
            parameters: AppleSchema.object(
                [
                    "query": AppleSchema.string("Text, phone number, or email to find."),
                    "field": AppleSchema.string("Which field to match (default any).", enum: ["any", "name", "phone", "email", "organization"]),
                    "limit": AppleSchema.limit(default: Self.defaultLimit, max: 200),
                ],
                required: ["query"]
            ),
            isWrite: false
        )
    }

    override func run(args: [String: Any]) async throws -> AppleToolPayload {
        let query = try AppleArgs.requiredString(args, "query", expected: "text, a phone number, or an email")
        let fieldRaw = try AppleArgs.enumeration(args, "field", allowed: ["any", "name", "phone", "email", "organization"], default: "any")
        let field = ContactSearchField(rawValue: fieldRaw ?? "any") ?? .any
        let limit = try AppleArgs.limit(args, default: Self.defaultLimit, max: 200)
        let results = try await service.search(query: query, field: field)
        let page = AppleServiceSupport.page(results, limit: limit)
        return AppleToolPayload([
            "contacts": page.items,
            "count": page.items.count,
            "total": page.total,
            "truncated": page.truncated,
            "query": query,
            "field": field.rawValue,
        ])
    }
}

// MARK: - contacts_list

final class ContactsListTool: AppleToolBase, @unchecked Sendable {
    private let service: ContactsServicing
    static let defaultLimit = 50

    init(service: ContactsServicing) {
        self.service = service
        super.init(
            app: .contacts,
            name: "contacts_list",
            description: "Page through all contacts sorted by name (compact cards). Use `offset` + `limit`; the result reports `total` and `next_offset`.",
            parameters: AppleSchema.object([
                "offset": AppleSchema.integer("Skip this many contacts (default 0)."),
                "limit": AppleSchema.limit(default: Self.defaultLimit, max: 200),
            ]),
            isWrite: false
        )
    }

    override func run(args: [String: Any]) async throws -> AppleToolPayload {
        let offset = max(0, try AppleArgs.int(args, "offset") ?? 0)
        let limit = try AppleArgs.limit(args, default: Self.defaultLimit, max: 200)
        let (contacts, total) = try await service.list(offset: offset, limit: limit)
        var payload: [String: Any] = [
            "contacts": contacts,
            "count": contacts.count,
            "total": total,
            "offset": offset,
        ]
        if offset + contacts.count < total { payload["next_offset"] = offset + contacts.count }
        return AppleToolPayload(payload)
    }
}

// MARK: - contacts_get

final class ContactsGetTool: AppleToolBase, @unchecked Sendable {
    private let service: ContactsServicing

    init(service: ContactsServicing) {
        self.service = service
        super.init(
            app: .contacts,
            name: "contacts_get",
            description: "Fetch one contact's full card by `id` (from contacts_search): all phones, emails, URLs, postal addresses, birthday, relations, social profiles.",
            parameters: AppleSchema.object(
                ["id": AppleSchema.string("Contact identifier from contacts_search / contacts_list.")],
                required: ["id"]
            ),
            isWrite: false
        )
    }

    override func run(args: [String: Any]) async throws -> AppleToolPayload {
        let id = try AppleArgs.requiredString(args, "id", expected: "a contact identifier")
        return AppleToolPayload(["contact": try await service.contact(id: id)])
    }
}

// MARK: - contacts_create

final class ContactsCreateTool: AppleToolBase, @unchecked Sendable {
    private let service: ContactsServicing

    init(service: ContactsServicing) {
        self.service = service
        super.init(
            app: .contacts,
            name: "contacts_create",
            description: "Create a contact. Provide at least a name or an organization; phones/emails accept plain strings or {label, value} objects. Returns the created card with its id.",
            parameters: AppleSchema.object(ContactsToolFactory.draftProperties),
            isWrite: true
        )
    }

    override func run(args: [String: Any]) async throws -> AppleToolPayload {
        let draft = try ContactsToolFactory.draft(from: args)
        let hasName = !(draft.givenName ?? "").isEmpty || !(draft.familyName ?? "").isEmpty
            || !(draft.organization ?? "").isEmpty || !(draft.nickname ?? "").isEmpty
        guard hasName else {
            throw AppleToolError.invalidArgs(
                "Provide at least `given_name`, `family_name`, `nickname`, or `organization`.", field: "given_name"
            )
        }
        let created = try await service.create(draft)
        return AppleToolPayload(["contact": created, "created": true])
    }
}

// MARK: - contacts_update

final class ContactsUpdateTool: AppleToolBase, @unchecked Sendable {
    private let service: ContactsServicing

    init(service: ContactsServicing) {
        self.service = service
        super.init(
            app: .contacts,
            name: "contacts_update",
            description:
                "Update a contact by `id`. Only supplied fields change. Phones/emails/urls/addresses are ADDED to the existing ones unless `replace: true` (then the supplied list replaces that field; [] clears it).",
            parameters: AppleSchema.object(
                ContactsToolFactory.draftProperties.merging([
                    "id": AppleSchema.string("Contact identifier from contacts_search."),
                    "replace": AppleSchema.boolean("Replace phones/emails/urls/addresses instead of merging (default false)."),
                ]) { _, new in new },
                required: ["id"]
            ),
            isWrite: true
        )
    }

    override func run(args: [String: Any]) async throws -> AppleToolPayload {
        let id = try AppleArgs.requiredString(args, "id", expected: "a contact identifier")
        let draft = try ContactsToolFactory.draft(from: args)
        let replace = try AppleArgs.bool(args, "replace") ?? false
        let hasChange =
            draft.givenName != nil || draft.familyName != nil || draft.middleName != nil || draft.nickname != nil
            || draft.organization != nil || draft.jobTitle != nil || draft.department != nil || draft.phones != nil
            || draft.emails != nil || draft.urls != nil || draft.postalAddresses != nil || draft.birthday != nil
        guard hasChange else {
            throw AppleToolError.invalidArgs("Nothing to update: pass at least one field besides `id`.")
        }
        let updated = try await service.update(id: id, draft: draft, replaceLabeledValues: replace)
        return AppleToolPayload(["contact": updated, "updated": true])
    }
}

// MARK: - contacts_open

final class ContactsOpenTool: AppleToolBase, @unchecked Sendable {
    private let service: ContactsServicing

    init(service: ContactsServicing) {
        self.service = service
        super.init(
            app: .contacts,
            name: "contacts_open",
            description: "Open a contact in the Contacts app by `id`.",
            parameters: AppleSchema.object(
                ["id": AppleSchema.string("Contact identifier from contacts_search.")],
                required: ["id"]
            ),
            isWrite: false
        )
    }

    override func run(args: [String: Any]) async throws -> AppleToolPayload {
        let id = try AppleArgs.requiredString(args, "id", expected: "a contact identifier")
        let contact = try await service.contact(id: id)
        guard let url = URL(string: contact.openURL) else {
            throw AppleToolError.execution("Could not build a Contacts link for `\(id)`.")
        }
        let opened = await MainActor.run { NSWorkspace.shared.open(url) }
        guard opened else {
            throw AppleToolError.unavailable("Contacts could not be opened for `\(contact.displayName)`.", retryable: true)
        }
        return AppleToolPayload(["opened": true, "contact": contact])
    }
}
