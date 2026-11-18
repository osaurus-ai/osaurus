//
//  AppleToolOutputSchemas.swift
//  osaurus
//
//  The `result` shape of every Apple app tool, keyed by tool name.
//

import Foundation

enum AppleToolOutputSchemas {
    private typealias S = ToolOutputSchema
    private typealias R = AppleToolOutputRecords

    static let byTool: [String: JSONValue] = calendar.merging(reminders) { a, _ in a }
        .merging(contacts) { a, _ in a }
        .merging(messages) { a, _ in a }
        .merging(notes) { a, _ in a }
        .merging(mail) { a, _ in a }
        .merging(maps) { a, _ in a }
        .merging(music) { a, _ in a }
        .merging(shortcuts) { a, _ in a }

    private static let span = S.string("`this_event` or `future_events`.")

    private static let calendar: [String: JSONValue] = [
        "calendar_list": S.object(["calendars": S.array(R.calendar, "The calendars."), "count": R.count]),
        "calendar_events": S.object([
            "events": S.array(R.event, "Events in the range, soonest first."),
            "count": R.count,
            "total_in_range": S.integer("Events in the range before `limit`."),
            "truncated": R.truncated,
            "range": S.object(
                [
                    "start": S.string("Range start."), "end": S.string("Range end searched."),
                    "end_clamped": S.boolean("True when the range was cut to four years."),
                ], "The range searched."),
        ]),
        "calendar_create_event": S.object(["event": R.event, "created": R.done]),
        "calendar_update_event": S.object(["event": R.event, "updated": R.done, "span": span]),
        "calendar_delete_event": S.object(["event": R.event, "deleted": R.done, "span": span]),
        "calendar_open_event": S.object(["opened": R.done, "event": R.event]),
    ]

    private static let reminders: [String: JSONValue] = [
        "reminders_lists": S.object(["lists": S.array(R.reminderList, "The reminder lists."), "count": R.count]),
        "reminders_fetch": S.object([
            "reminders": S.array(R.reminder, "The reminders."),
            "count": R.count, "total": R.total, "truncated": R.truncated,
            "status": S.string("`incomplete`, `completed`, or `all`."),
        ]),
        "reminders_create": S.object(["reminder": R.reminder, "created": R.done]),
        "reminders_update": S.object(["reminder": R.reminder, "updated": R.done]),
        "reminders_complete": S.object([
            "reminder": R.reminder, "completed": S.boolean("The new completed state."),
        ]),
        "reminders_delete": S.object(["reminder": R.reminder, "deleted": R.done]),
        "reminders_open": S.object(["opened": R.done, "reminder": R.reminder]),
    ]

    private static let contacts: [String: JSONValue] = [
        "contacts_me": S.object([
            "contact": S.nullable(R.contact), "found": S.boolean("False when no My Card is set."),
        ]),
        "contacts_search": S.object([
            "contacts": S.array(R.contactSummary, "Matching contacts."),
            "count": R.count, "total": R.total, "truncated": R.truncated,
            "query": S.string("The search text."), "field": S.string("The field searched."),
        ]),
        "contacts_list": S.object([
            "contacts": S.array(R.contactSummary, "This page of contacts."),
            "count": R.count, "total": S.integer("All contacts."),
            "offset": S.integer("Where this page starts."),
            "next_offset": S.integer("Present when more remain: pass as `offset`."),
        ]),
        "contacts_get": S.object(["contact": R.contact]),
        "contacts_create": S.object(["contact": R.contact, "created": R.done]),
        "contacts_update": S.object(["contact": R.contact, "updated": R.done]),
        "contacts_open": S.object(["opened": R.done, "contact": R.contact]),
    ]

    private static let messages: [String: JSONValue] = [
        "messages_conversations": S.object([
            "conversations": S.array(R.conversation, "Recent conversations."), "count": R.count,
        ]),
        "messages_read": S.object(["messages": S.array(R.textMessage, "The messages."), "count": R.count]),
        "messages_unread": S.object(["messages": S.array(R.textMessage, "Unread messages."), "count": R.count]),
        "messages_search": S.object([
            "messages": S.array(R.textMessage, "Matching messages."), "count": R.count,
            "query": S.string("The search text."),
        ]),
        "messages_send": S.object([
            "sent": R.done,
            "service": S.string("`iMessage`, `SMS`, or `chat`."),
            "target": S.string("The handle or chat it went to."),
            "text": S.string("The message sent."),
            "delivered": S.nullable(S.boolean("Whether Messages stored it without an error; null when unknown.")),
        ]),
    ]

    private static let notes: [String: JSONValue] = [
        "notes_folders": S.object(["folders": S.array(R.noteFolder, "The folders."), "count": R.count]),
        "notes_list": S.object([
            "notes": S.array(R.noteSummary, "Notes, newest-modified first."),
            "count": R.count, "total": R.total, "truncated": R.truncated,
        ]),
        "notes_search": S.object([
            "notes": S.array(R.noteSummary, "Matching notes, newest-modified first."),
            "count": R.count, "total": R.total, "truncated": R.truncated,
            "query": S.string("The search text."),
        ]),
        "notes_read": S.object(["note": R.note]),
        "notes_create": S.object(["note": R.note, "created": R.done]),
        "notes_append": S.object(["note": R.note, "appended": R.done]),
        "notes_open": S.object(["opened": R.done, "id": S.string("The note id.")]),
    ]

    private static let mail: [String: JSONValue] = [
        "mail_mailboxes": S.object(["mailboxes": S.array(R.mailbox, "The mailboxes."), "count": R.count]),
        "mail_list": S.object([
            "messages": S.array(R.mailSummary, "Messages, newest first."), "count": R.count,
            "mailbox_path": S.string("The mailbox listed."), "truncated": R.truncated,
        ]),
        "mail_read": S.object(["message": R.mailContent]),
        "mail_search": S.object([
            "messages": S.array(R.mailSummary, "Matching messages."), "count": R.count,
            "query": S.string("The search text."), "field": S.string("The field searched."),
            "mailbox_path": S.string("The mailbox searched."), "truncated": R.truncated,
        ]),
        "mail_compose": S.object([
            "sent": S.boolean("True when sent; false when left as a draft."),
            "draft_open_in_mail": S.boolean("True when the draft is open in Mail."),
            "subject": S.string("The subject."),
            "to": R.addresses("To"), "cc": R.addresses("Cc"), "bcc": R.addresses("Bcc"),
        ]),
        "mail_reply": S.object([
            "sent": S.boolean("True when sent; false when left as a draft."),
            "draft_open_in_mail": S.boolean("True when the draft is open in Mail."),
            "subject": S.string("The subject."),
            "reply_all": S.boolean("Whether it replied to all."),
            "id": S.string("The message replied to."),
        ]),
        "mail_move": S.object([
            "message": R.mailSummary, "moved": R.done, "to_mailbox_path": S.string("Where it went."),
        ]),
        "mail_set_status": S.object(["message": R.mailSummary, "updated": R.done]),
        "mail_thread": S.object([
            "messages": S.array(R.mailSummary, "The thread's messages."), "count": R.count,
            "root_id": S.string("The message the thread was built from."),
        ]),
    ]

    private static let maps: [String: JSONValue] = [
        "location_current": S.object(["location": R.currentLocation]),
        "location_geocode": S.object([
            "places": S.array(R.place, "Matches for the address."), "count": R.count,
            "address": S.string("The address looked up."),
        ]),
        "location_reverse_geocode": S.object([
            "places": S.array(R.place, "What is at the coordinate."), "count": R.count,
            "coordinate": R.coordinate,
        ]),
        "maps_search": S.object([
            "places": S.array(R.place, "Matching places."), "count": R.count, "query": S.string("The search text."),
        ]),
        "maps_explore": S.object([
            "places": S.array(R.place, "Places in the category."), "count": R.count,
            "category": S.string("The category explored."),
        ]),
        "maps_directions": S.object([
            "routes": S.array(R.route, "Routes, best first."), "count": R.count,
            "mode": S.string("The transport mode."),
        ]),
        "maps_eta": S.object(["eta": R.eta]),
        "maps_open": S.object(["opened": R.done, "url": S.string("The Maps link opened.")]),
    ]

    private static let music: [String: JSONValue] = [
        "music_now_playing": S.object(["player": R.player]),
        "music_playback": S.object(["action": S.string("The action taken."), "player": R.player]),
        "music_set_volume": S.object(["volume": S.integer("The volume now, 0–100.")]),
        "music_playlists": S.object([
            "playlists": S.array(R.playlist, "The playlists."),
            "count": R.count, "total": R.total, "truncated": R.truncated,
        ]),
        "music_search": S.object([
            "tracks": S.array(R.track, "Matching tracks."), "count": R.count,
            "query": S.string("The search text."), "field": S.string("The field searched."),
        ]),
        "music_play": S.object(["player": R.player]),
    ]

    private static let shortcuts: [String: JSONValue] = [
        "shortcuts_list": S.object([
            "shortcuts": S.array(R.shortcut, "The shortcuts."),
            "count": R.count, "total": R.total, "truncated": R.truncated,
        ]),
        "shortcuts_run": S.object(["result": R.shortcutRun]),
    ]
}
