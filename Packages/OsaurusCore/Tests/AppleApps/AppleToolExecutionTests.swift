//
//  AppleToolExecutionTests.swift
//  OsaurusCoreTests — AppleApps
//
//  Executes representative Apple tools against fake services to pin the
//  `AppleToolBase` contract: argument validation → `invalid_args` with a
//  field, limit clamping, `Encodable` payloads → JSON envelopes, and the
//  typed error kinds (`not_found`, `permission_denied`, `unavailable`,
//  `timeout`) the model branches on. No TCC or app access is touched.
//

import Foundation
import Testing

@testable import OsaurusCore

// MARK: - Envelope helpers

private func envelope(_ raw: String) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
}

private func result(_ raw: String) throws -> [String: Any] {
    let env = try envelope(raw)
    #expect(env["ok"] as? Bool == true, "expected success: \(raw)")
    return try #require(env["result"] as? [String: Any])
}

// MARK: - Fakes

private final class FakeCalendarService: CalendarServicing, @unchecked Sendable {
    var calendars: [CalendarInfo] = [
        CalendarInfo(id: "cal-1", title: "Work", account: "iCloud", color: "#FF0000", isEditable: true, isDefault: true, isSubscribed: false, type: "calDAV"),
        CalendarInfo(id: "cal-2", title: "Holidays", account: "Subscribed", color: nil, isEditable: false, isDefault: false, isSubscribed: true, type: "subscription"),
    ]
    var events: [CalendarEventInfo] = []
    var error: AppleToolError?
    private(set) var lastQuery: CalendarEventQuery?
    private(set) var lastDraft: CalendarEventDraft?
    private(set) var deleted: [(String, Date?, CalendarEditSpan)] = []

    func calendars() async throws -> [CalendarInfo] {
        if let error { throw error }
        return calendars
    }
    var clampEnd = false
    func events(_ query: CalendarEventQuery) async throws -> CalendarEventsResult {
        if let error { throw error }
        lastQuery = query
        let effectiveEnd = clampEnd ? (Calendar.current.date(byAdding: .year, value: 4, to: query.start) ?? query.end) : query.end
        return CalendarEventsResult(events: events, effectiveEnd: effectiveEnd, endWasClamped: clampEnd && effectiveEnd < query.end)
    }
    func event(id: String, occurrenceStart: Date?) async throws -> CalendarEventInfo {
        if let error { throw error }
        guard let e = events.first(where: { $0.id == id }) else { throw AppleToolError.notFound("No event `\(id)`.") }
        return e
    }
    func create(_ draft: CalendarEventDraft) async throws -> CalendarEventInfo {
        if let error { throw error }
        lastDraft = draft
        return Self.event(id: "new-1", title: draft.title, start: draft.start, end: draft.end, allDay: draft.isAllDay)
    }
    func update(id: String, occurrenceStart: Date?, span: CalendarEditSpan, patch: CalendarEventPatch) async throws -> CalendarEventInfo {
        if let error { throw error }
        return try await event(id: id, occurrenceStart: occurrenceStart)
    }
    func delete(id: String, occurrenceStart: Date?, span: CalendarEditSpan) async throws -> CalendarEventInfo {
        if let error { throw error }
        let e = try await event(id: id, occurrenceStart: occurrenceStart)
        deleted.append((id, occurrenceStart, span))
        return e
    }

    static func event(id: String, title: String, start: Date, end: Date, allDay: Bool = false, recurring: Bool = false) -> CalendarEventInfo {
        CalendarEventInfo(
            id: id, calendarId: "cal-1", calendarTitle: "Work", title: title, start: start, end: end, isAllDay: allDay,
            allDayDates: allDay ? CalendarArgs.allDayRange(start: start, end: end) : nil,
            location: nil, notes: nil, url: nil, status: "confirmed", availability: "busy", organizer: nil,
            attendees: [], alarms: [], recurrence: nil, isRecurring: recurring, isDetached: false, lastModified: nil,
            openURL: "ical://ekevent/\(id)"
        )
    }
}

private final class FakeShortcutsService: ShortcutsServicing, @unchecked Sendable {
    var shortcuts = [ShortcutInfo(name: "Morning Brief", identifier: "0F0F0F0F-0000-4000-8000-000000000001", folder: nil), ShortcutInfo(name: "Log Water", identifier: nil, folder: nil)]
    var runError: AppleToolError?
    private(set) var lastRun: (name: String, input: String?, timeout: TimeInterval)?

    func list() async throws -> [ShortcutInfo] { shortcuts }
    func run(name: String, input: String?, timeout: TimeInterval) async throws -> ShortcutRunResult {
        lastRun = (name, input, timeout)
        if let runError { throw runError }
        return ShortcutRunResult(name: name, output: "ran \(name) with \(input ?? "-")", outputIsEmpty: false, outputIsBinary: false, outputBytes: 10, outputTruncated: false, durationSeconds: 0.5)
    }
}

// MARK: - Calendar

@Suite("Apple tools: Calendar over a fake service")
struct CalendarToolExecutionTests {

    @Test("calendar_list returns typed calendars with ids")
    func listCalendars() async throws {
        let service = FakeCalendarService()
        let tool = CalendarListTool(service: service)
        let payload = try result(await tool.execute(argumentsJSON: "{}"))
        let calendars = try #require(payload["calendars"] as? [[String: Any]])
        #expect(calendars.count == 2)
        #expect(calendars.first?["id"] as? String == "cal-1")
        #expect(calendars.first?["isDefault"] as? Bool == true)
        #expect(payload["count"] as? Int == 2)
    }

    @Test("calendar_events defaults to now → +7d, parses dates, and clamps the limit")
    func eventsDefaultsAndClamp() async throws {
        let service = FakeCalendarService()
        let tool = CalendarEventsTool(service: service)
        _ = try result(await tool.execute(argumentsJSON: "{}"))
        let q = try #require(service.lastQuery)
        let span = q.end.timeIntervalSince(q.start)
        #expect(span > 6.9 * 86_400 && span < 7.1 * 86_400)
        #expect(q.includeAllDay)

        _ = try result(await tool.execute(argumentsJSON: #"{"start":"2026-09-19","end":"2026-09-19","limit":99999,"calendars":["cal-1"],"query":"standup"}"#))
        let q2 = try #require(service.lastQuery)
        // Date-only end is inclusive → exclusive bound is the next day.
        #expect(q2.end.timeIntervalSince(q2.start) >= 23 * 3600)
        #expect(q2.calendarIds == ["cal-1"])
        #expect(q2.query == "standup")
    }

    @Test("calendar_events emits ISO 8601 with local offset and total/truncated")
    func eventsOutputShape() async throws {
        let service = FakeCalendarService()
        let start = Date(timeIntervalSince1970: 1_789_000_000)
        service.events = (0 ..< 3).map { i in
            FakeCalendarService.event(id: "e\(i)", title: "Event \(i)", start: start.addingTimeInterval(Double(i) * 3600), end: start.addingTimeInterval(Double(i + 1) * 3600))
        }
        let tool = CalendarEventsTool(service: service)
        let payload = try result(await tool.execute(argumentsJSON: #"{"limit":2}"#))
        let events = try #require(payload["events"] as? [[String: Any]])
        #expect(events.count == 2)
        #expect(payload["total_in_range"] as? Int == 3)
        #expect(payload["truncated"] as? Bool == true)
        let startText = try #require(events.first?["start"] as? String)
        #expect(startText == AppleDateParsing.format(start))
        #expect(!startText.hasSuffix("Z"))
        #expect(events.first?["openURL"] as? String == "ical://ekevent/e0")
    }

    @Test("bad dates and missing required args produce invalid_args with the field named")
    func invalidArgs() async throws {
        let tool = CalendarEventsTool(service: FakeCalendarService())
        let env = try envelope(await tool.execute(argumentsJSON: #"{"start":"tomorrow-ish"}"#))
        #expect(env["ok"] as? Bool == false)
        #expect(env["kind"] as? String == "invalid_args")
        #expect(env["field"] as? String == "start")
        #expect((env["expected"] as? String)?.contains("ISO 8601") == true)

        let create = CalendarCreateEventTool(service: FakeCalendarService())
        let env2 = try envelope(await create.execute(argumentsJSON: #"{"start":"2026-09-19T10:00"}"#))
        #expect(env2["kind"] as? String == "invalid_args")
        #expect(env2["field"] as? String == "title")

        let env3 = try envelope(await create.execute(argumentsJSON: "not json"))
        #expect(env3["ok"] as? Bool == false)
        #expect(env3["kind"] as? String == "invalid_args")
    }

    @Test("calendar_create_event: bare start makes an all-day event; timed start defaults end to +1h")
    func createDefaults() async throws {
        let service = FakeCalendarService()
        let tool = CalendarCreateEventTool(service: service)
        _ = try result(await tool.execute(argumentsJSON: #"{"title":"Offsite","start":"2026-10-02"}"#))
        let allDay = try #require(service.lastDraft)
        #expect(allDay.isAllDay)
        #expect(allDay.title == "Offsite")

        _ = try result(await tool.execute(argumentsJSON: #"{"title":"Standup","start":"2026-10-02T09:00:00-07:00"}"#))
        let timed = try #require(service.lastDraft)
        #expect(!timed.isAllDay)
        #expect(timed.end.timeIntervalSince(timed.start) == 3600)
    }

    @Test("typed service errors map to their envelope kinds with retryable/permission metadata")
    func errorKinds() async throws {
        let service = FakeCalendarService()
        let tool = CalendarListTool(service: service)

        service.error = .permissionDenied(.calendar)
        var env = try envelope(await tool.execute(argumentsJSON: "{}"))
        #expect(env["kind"] as? String == "permission_denied")
        #expect(env["retryable"] as? Bool == false)
        // Metadata is flattened onto the envelope root.
        #expect(env["permission"] as? String == SystemPermission.calendar.rawValue)
        #expect((env["system_settings_url"] as? String)?.isEmpty == false)
        #expect((env["message"] as? String)?.contains("System Settings") == true)

        service.error = .unavailable("EventKit is unavailable", retryable: true)
        env = try envelope(await tool.execute(argumentsJSON: "{}"))
        #expect(env["kind"] as? String == "unavailable")
        #expect(env["retryable"] as? Bool == true)

        service.error = .timeout("took too long")
        env = try envelope(await tool.execute(argumentsJSON: "{}"))
        #expect(env["kind"] as? String == "timeout")

        service.error = nil
        let open = CalendarOpenEventTool(service: service)
        env = try envelope(await open.execute(argumentsJSON: #"{"id":"nope"}"#))
        #expect(env["kind"] as? String == "not_found")
    }

    @Test("calendar_delete_event is per-call approval and forwards span + occurrence")
    func deleteContract() async throws {
        let service = FakeCalendarService()
        let start = Date(timeIntervalSince1970: 1_789_000_000)
        service.events = [FakeCalendarService.event(id: "e1", title: "Weekly", start: start, end: start.addingTimeInterval(1800))]
        let tool = CalendarDeleteEventTool(service: service)
        #expect(tool is PerCallApprovalTool)
        #expect(tool.defaultPermissionPolicy == .ask)
        let payload = try result(await tool.execute(argumentsJSON: #"{"id":"e1","occurrence_start":"2026-09-19T10:00:00-07:00","span":"future_events"}"#))
        #expect(payload["deleted"] as? Bool == true)
        #expect(payload["span"] as? String == "future_events")
        #expect(service.deleted.count == 1)
        #expect(service.deleted.first?.2 == .futureEvents)
        #expect(service.deleted.first?.1 != nil)
    }
}

// MARK: - Shortcuts

@Suite("Apple tools: Shortcuts over a fake service")
struct ShortcutsToolExecutionTests {

    @Test("shortcuts_list filters by query and pages")
    func listFilters() async throws {
        let tool = ShortcutsListTool(service: FakeShortcutsService())
        let all = try result(await tool.execute(argumentsJSON: "{}"))
        #expect(all["count"] as? Int == 2)
        let filtered = try result(await tool.execute(argumentsJSON: #"{"query":"water"}"#))
        let items = try #require(filtered["shortcuts"] as? [[String: Any]])
        #expect(items.count == 1)
        #expect(items.first?["name"] as? String == "Log Water")
        let paged = try result(await tool.execute(argumentsJSON: #"{"limit":1}"#))
        #expect(paged["truncated"] as? Bool == true)
        #expect(paged["total"] as? Int == 2)
    }

    @Test("shortcuts_run requires a name, clamps the timeout, and is a write")
    func runContract() async throws {
        let service = FakeShortcutsService()
        let tool = ShortcutsRunTool(service: service)
        #expect(tool.defaultPermissionPolicy == .ask)
        let missing = try envelope(await tool.execute(argumentsJSON: #"{"input":"x"}"#))
        #expect(missing["kind"] as? String == "invalid_args")
        #expect(missing["field"] as? String == "name")

        let payload = try result(await tool.execute(argumentsJSON: #"{"name":"Morning Brief","input":"hello","timeout_seconds":99999}"#))
        let run = try #require(payload["result"] as? [String: Any])
        #expect(run["output"] as? String == "ran Morning Brief with hello")
        #expect(service.lastRun?.timeout == 600)

        _ = try result(await tool.execute(argumentsJSON: #"{"name":"Morning Brief"}"#))
        #expect(service.lastRun?.timeout == ShortcutsRunTool.defaultTimeout)
        #expect(service.lastRun?.input == nil)

        service.runError = .notFound("No shortcut named `Nope`.")
        let nf = try envelope(await tool.execute(argumentsJSON: #"{"name":"Nope"}"#))
        #expect(nf["kind"] as? String == "not_found")
    }
}

// MARK: - Messages (pure helpers)

@Suite("Apple tools: Messages chat.db helpers")
struct MessagesServiceHelperTests {

    @Test("Apple epoch conversion handles nanosecond and second precision")
    func appleTime() {
        let date = Date(timeIntervalSinceReferenceDate: 800_000_000)
        #expect(ChatDBMessagesService.date(fromAppleTime: 800_000_000) == date)
        #expect(ChatDBMessagesService.date(fromAppleTime: 800_000_000_000_000_000) == date)
        #expect(ChatDBMessagesService.date(fromAppleTime: 0) == nil)
        #expect(ChatDBMessagesService.date(fromAppleTime: ChatDBMessagesService.appleTime(from: date)) == date)
    }

    @Test("attributedBody typedstream text is recovered for short and long payloads")
    func attributedBody() {
        func blob(_ text: String) -> Data {
            var data = Data([0x04, 0x0B, 0x73, 0x74, 0x72, 0x65, 0x61, 0x6D, 0x74, 0x79, 0x70, 0x65, 0x64])
            data.append(contentsOf: Array("NSString".utf8))
            data.append(contentsOf: [0x01, 0x94, 0x84, 0x01, 0x2B])  // 5-byte preamble
            let bytes = Array(text.utf8)
            if bytes.count < 0x80 {
                data.append(UInt8(bytes.count))
            } else {
                data.append(0x81)
                data.append(UInt8(bytes.count & 0xFF))
                data.append(UInt8((bytes.count >> 8) & 0xFF))
            }
            data.append(contentsOf: bytes)
            data.append(contentsOf: [0x86, 0x84, 0x02, 0x69, 0x49])  // trailing attributes
            return data
        }
        #expect(ChatDBMessagesService.decodeAttributedBody(blob("hello there")) == "hello there")
        let long = String(repeating: "x", count: 300)
        #expect(ChatDBMessagesService.decodeAttributedBody(blob(long)) == long)
        #expect(ChatDBMessagesService.decodeAttributedBody(nil) == nil)
        #expect(ChatDBMessagesService.decodeAttributedBody(Data([0x01, 0x02])) == nil)
    }

    @Test("messages_send requires a target and validates the service enum")
    func sendValidation() async throws {
        final class Fake: MessagesServicing, @unchecked Sendable {
            var sent: (String?, String?, String, MessagesSendService)?
            func conversations(limit: Int) async throws -> [MessagesConversation] { [] }
            func read(_ query: MessagesReadQuery) async throws -> [MessagesMessage] { [] }
            func unread(limit: Int) async throws -> [MessagesMessage] { [] }
            func search(_ text: String, limit: Int) async throws -> [MessagesMessage] { [] }
            func send(to recipient: String?, chatId: String?, text: String, service: MessagesSendService) async throws -> MessagesSendResult {
                sent = (recipient, chatId, text, service)
                return MessagesSendResult(service: "iMessage", target: recipient ?? chatId ?? "", delivered: true)
            }
        }
        let fake = Fake()
        let tool = MessagesSendTool(service: fake)
        #expect(tool.defaultPermissionPolicy == .ask)
        #expect(tool.requirements == [SystemPermission.automationMessages.rawValue])

        let noTarget = try envelope(await tool.execute(argumentsJSON: #"{"text":"hi"}"#))
        #expect(noTarget["kind"] as? String == "invalid_args")

        let badService = try envelope(await tool.execute(argumentsJSON: #"{"text":"hi","to":"+14155551234","service":"carrier-pigeon"}"#))
        #expect(badService["kind"] as? String == "invalid_args")
        #expect(badService["field"] as? String == "service")

        let ok = try result(await tool.execute(argumentsJSON: #"{"text":"hi","to":"+14155551234","service":"sms"}"#))
        #expect(ok["sent"] as? Bool == true)
        #expect(fake.sent?.3 == .sms)
        #expect(fake.sent?.0 == "+14155551234")

        let read = MessagesReadTool(service: fake)
        #expect(read.requirements == [SystemPermission.disk.rawValue])
        #expect(read.defaultPermissionPolicy == .auto)
    }
}

// MARK: - Maps argument contracts (from live proof)

private final class FakeMapsService: MapsServicing, @unchecked Sendable {
    var lastSearch: (query: String, near: MapsSearchRegion?)?
    var lastETA: (from: MapsPlaceReference, to: MapsPlaceReference, transport: MapsTransportType)?
    var lastDirections: (from: MapsPlaceReference, to: MapsPlaceReference, transport: MapsTransportType)?

    func currentLocation() async throws -> CurrentLocationInfo { throw AppleToolError.unavailable("no location in tests") }
    func geocode(_ address: String, limit: Int) async throws -> [PlaceInfo] { [] }
    func reverseGeocode(_ coordinate: GeoCoordinate) async throws -> [PlaceInfo] { [] }
    func search(_ query: String, near: MapsSearchRegion?, limit: Int) async throws -> [PlaceInfo] {
        lastSearch = (query, near)
        return []
    }
    func explore(category: String, near: MapsSearchRegion, limit: Int) async throws -> [PlaceInfo] { [] }
    func directions(from: MapsPlaceReference, to: MapsPlaceReference, transport: MapsTransportType, alternatives: Bool) async throws -> [RouteInfo] {
        lastDirections = (from, to, transport)
        return []
    }
    func eta(from: MapsPlaceReference, to: MapsPlaceReference, transport: MapsTransportType) async throws -> ETAInfo {
        lastETA = (from, to, transport)
        return ETAInfo(expectedTravelSeconds: 800, distanceMeters: 14_000, transportType: transport.rawValue, expectedDeparture: nil, expectedArrival: nil)
    }
}

/// Run a tool the way the registry does: schema validation first, then the body.
private func validated(_ tool: OsaurusTool, _ argsJSON: String) async throws -> String {
    let args = try #require(JSONSerialization.jsonObject(with: Data(argsJSON.utf8)) as? [String: Any])
    let schema = try #require(tool.parameters)
    let res = SchemaValidator.validate(arguments: args, against: schema)
    if !res.isValid {
        let body: [String: Any] = ["ok": false, "kind": "invalid_args", "message": res.errorMessage ?? "invalid"]
        return String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
    }
    return try await tool.execute(argumentsJSON: argsJSON)
}

@Suite("Apple tools: Maps argument contracts")
struct MapsToolArgumentContractTests {

    @Test("maps_eta / maps_directions accept `driving` and place objects at the schema layer")
    func drivingAliasAndPlaceObjects() async throws {
        let fake = FakeMapsService()
        let eta = MapsETATool(service: fake)

        // The word models actually use for `automobile`.
        _ = try result(await validated(eta, #"{"from":"37.33,-122.0","to":"San Jose, CA","mode":"driving"}"#))
        #expect(fake.lastETA?.transport == .automobile)
        #expect(fake.lastETA?.from == .coordinate(GeoCoordinate(latitude: 37.33, longitude: -122.0)))
        #expect(fake.lastETA?.to == .query("San Jose, CA"))

        // `{latitude, longitude}` objects pass validation and parse to coordinates.
        _ = try result(await validated(eta, #"{"from":{"latitude":37.3349,"longitude":-122.009},"to":{"latitude":37.3377,"longitude":-121.8875}}"#))
        #expect(fake.lastETA?.to == .coordinate(GeoCoordinate(latitude: 37.3377, longitude: -121.8875)))

        // A place echoed back from a previous result: `{name, coordinate: {…}}`.
        let echoed = try result(await validated(eta, #"{"from":{"name":"Espresso Bar","coordinate":{"latitude":37.3361,"longitude":-122.0105}},"to":"San Jose, CA"}"#))
        #expect(fake.lastETA?.from == .coordinate(GeoCoordinate(latitude: 37.3361, longitude: -122.0105)))
        let etaPayload = try #require(echoed["eta"] as? [String: Any])
        #expect(etaPayload["expectedTravelText"] as? String == "13 min")
        #expect(etaPayload["distanceText"] as? String == "14.0 km (8.7 mi)")
        #expect(MapsFormatting.duration(20) == "under a minute")
        #expect(MapsFormatting.duration(7_500) == "2 h 5 min")
        #expect(MapsFormatting.distance(420) == "420 m")

        // Missing `from` → current location; `transit` only where MapKit supports it.
        _ = try result(await validated(eta, #"{"to":"Cupertino","mode":"transit"}"#))
        #expect(fake.lastETA?.from == .currentLocation)
        #expect(fake.lastETA?.transport == .transit)

        let directions = MapsDirectionsTool(service: fake)
        let rejected = try envelope(await validated(directions, #"{"to":"Cupertino","mode":"transit"}"#))
        #expect(rejected["ok"] as? Bool == false)
        _ = try result(await validated(directions, #"{"to":"Cupertino","mode":"driving"}"#))
        #expect(fake.lastDirections?.transport == .automobile)
    }

    @Test("maps_search forwards the `near` region with a clamped radius")
    func nearRegion() async throws {
        let fake = FakeMapsService()
        let tool = MapsSearchTool(service: fake)
        _ = try result(await validated(tool, #"{"query":"coffee","near":{"latitude":37.3349,"longitude":-122.009,"radius_meters":2000}}"#))
        #expect(fake.lastSearch?.near == MapsSearchRegion(center: GeoCoordinate(latitude: 37.3349, longitude: -122.009), radiusMeters: 2000))
        _ = try result(await validated(tool, #"{"query":"coffee","near":{"latitude":0,"longitude":0,"radius_meters":999999}}"#))
        #expect(fake.lastSearch?.near?.radiusMeters == 50_000)
        _ = try result(await validated(tool, #"{"query":"coffee"}"#))
        #expect(fake.lastSearch?.near == nil)
    }

    @Test("out-of-range \"lat,lng\" strings and objects are invalid_args, never a MapKit region crash")
    func coordinateRangeValidation() async throws {
        let fake = FakeMapsService()
        let eta = MapsETATool(service: fake)
        let bad = try envelope(await validated(eta, #"{"from":"500,900","to":"San Jose, CA"}"#))
        #expect(bad["ok"] as? Bool == false)
        #expect(bad["kind"] as? String == "invalid_args")
        #expect(bad["field"] as? String == "from")
        #expect(fake.lastETA == nil)

        let badObject = try envelope(await validated(eta, #"{"from":{"latitude":91,"longitude":0},"to":"San Jose, CA"}"#))
        #expect(badObject["kind"] as? String == "invalid_args")

        let search = MapsSearchTool(service: fake)
        let badNear = try envelope(await validated(search, #"{"query":"coffee","near":{"latitude":37,"longitude":-181}}"#))
        #expect(badNear["kind"] as? String == "invalid_args")
        #expect(fake.lastSearch == nil)
    }

    @Test("maps_open uses dirflg=c for cycling and d/w/r for the others")
    func dirflg() throws {
        for (mode, flag) in [("cycling", "c"), ("driving", "d"), ("walking", "w"), ("transit", "r"), ("automobile", "d")] {
            let url = try MapsOpenTool.buildURL(["directions_to": "Cupertino", "mode": mode]).absoluteString
            #expect(url.contains("dirflg=\(flag)"), "\(mode) → \(url)")
            #expect(url.contains("daddr=Cupertino"))
        }
        let pin = try MapsOpenTool.buildURL(["latitude": 37.33, "longitude": -122.0]).absoluteString
        #expect(pin.contains("ll=37.33,-122.0"))
    }
}

// MARK: - Contacts argument contracts

private final class FakeContactsService: ContactsServicing, @unchecked Sendable {
    var lastDraft: ContactDraft?
    private func card(_ d: ContactDraft) -> ContactInfo {
        ContactInfo(
            id: "c-1", displayName: "\(d.givenName ?? "") \(d.familyName ?? "")", givenName: d.givenName ?? "",
            familyName: d.familyName ?? "", middleName: nil, nickname: nil, organization: nil, jobTitle: nil,
            department: nil, phones: d.phones ?? [], emails: d.emails ?? [], urls: d.urls ?? [],
            postalAddresses: d.postalAddresses ?? [], birthday: nil, relations: [], socialProfiles: [],
            hasImage: false, openURL: "addressbook://c-1"
        )
    }
    func me() async throws -> ContactInfo? { nil }
    func search(query: String, field: ContactSearchField) async throws -> [ContactSummary] { [] }
    func list(offset: Int, limit: Int) async throws -> (contacts: [ContactSummary], total: Int) { ([], 0) }
    func contact(id: String) async throws -> ContactInfo { throw AppleToolError.notFound("no contact \(id)") }
    func create(_ draft: ContactDraft) async throws -> ContactInfo { lastDraft = draft; return card(draft) }
    func update(id: String, draft: ContactDraft, replaceLabeledValues: Bool) async throws -> ContactInfo { lastDraft = draft; return card(draft) }
}

@Suite("Apple tools: Contacts argument contracts")
struct ContactsToolArgumentContractTests {

    @Test("contacts_create accepts bare strings and {label, value} objects for phones/emails and typed postal addresses")
    func labeledArrays() async throws {
        let fake = FakeContactsService()
        let tool = ContactsCreateTool(service: fake)
        _ = try result(await validated(tool, #"""
            {"given_name":"Ada","family_name":"Lovelace",
             "phones":["+15555550100",{"label":"work","value":"+15555550101"},{"label":"home","number":"+15555550102"}],
             "emails":[{"label":"work","email":"ada@example.com"}],
             "postal_addresses":[{"label":"home","street":"1 Analytical Way","city":"London","postal_code":"N1","country":"UK"}]}
            """#))
        let draft = try #require(fake.lastDraft)
        #expect(draft.phones?.map(\.value) == ["+15555550100", "+15555550101", "+15555550102"])
        #expect(draft.phones?.map(\.label) == [nil, "work", "home"])
        #expect(draft.emails == [LabeledValue(label: "work", value: "ada@example.com")])
        #expect(draft.postalAddresses?.first?.postalCode == "N1")
        #expect(draft.postalAddresses?.first?.formatted == "1 Analytical Way, London, N1, UK")

        // Unknown keys inside a nested object are still rejected (closed schemas).
        let rejected = try envelope(await validated(tool, #"{"given_name":"Ada","postal_addresses":[{"street":"x","planet":"Mars"}]}"#))
        #expect(rejected["ok"] as? Bool == false)
    }
}
