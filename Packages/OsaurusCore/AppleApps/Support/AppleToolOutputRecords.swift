//
//  AppleToolOutputRecords.swift
//  osaurus
//
//  Output schemas for the records Apple tools return: the services'
//  `Codable` models encoded with their Swift property names (`isRead`,
//  `mailboxPath`), dates as ISO 8601 strings, and nil fields omitted.
//

import Foundation

enum AppleToolOutputRecords {
    private typealias S = ToolOutputSchema

    static let count = S.integer("Items returned.")
    static let total = S.integer("Items that matched before `limit`.")
    static let truncated = S.boolean("True when `limit` cut the list.")
    static let done = S.boolean("True.")

    static func addresses(_ field: String) -> JSONValue {
        S.array(S.string("Address."), "\(field) recipients.")
    }

    // MARK: Calendar & Reminders

    static let alarm = S.object([
        "minutesBefore": S.integer("Minutes before the start."),
        "absoluteDate": S.string("Fixed alert time."),
    ])

    static let recurrence = S.object(
        [
            "frequency": S.string("`daily`, `weekly`, `monthly`, or `yearly`."),
            "interval": S.integer("Every N periods."),
            "daysOfWeek": S.array(S.string("Day."), "Days it repeats on."),
            "endDate": S.string("Last date."),
            "occurrenceCount": S.integer("Number of occurrences."),
        ], "The repeat rule.")

    static let calendar = S.object(
        [
            "id": S.string("Calendar id."), "title": S.string("Title."), "account": S.string("Account."),
            "color": S.string("Hex color."), "isEditable": S.boolean("Can hold new events."),
            "isDefault": S.boolean("The default for new events."),
            "isSubscribed": S.boolean("A read-only subscription."), "type": S.string("Calendar type."),
        ], required: ["id", "title"])

    static let event = S.object(
        [
            "id": S.string("Event id."),
            "calendarId": S.string("Calendar id."),
            "calendarTitle": S.string("Calendar title."),
            "title": S.string("Title."),
            "start": S.string("Start (ISO 8601)."),
            "end": S.string("End (ISO 8601)."),
            "isAllDay": S.boolean("All-day event."),
            "allDayDates": S.object(
                ["start": S.string("First day."), "end": S.string("Last day, inclusive.")],
                "For all-day events: the first and last day as `YYYY-MM-DD`."),
            "location": S.string("Location."),
            "notes": S.string("Notes."),
            "url": S.string("URL."),
            "status": S.string("Status."),
            "availability": S.string("Show as."),
            "organizer": S.string("Organizer."),
            "attendees": S.array(
                S.object([
                    "name": S.string("Name."), "email": S.string("Email."), "status": S.string("Response."),
                    "isCurrentUser": S.boolean("This is the user."),
                ]), "Attendees."),
            "alarms": S.array(alarm, "Alerts."),
            "recurrence": recurrence,
            "isRecurring": S.boolean("Repeats."),
            "isDetached": S.boolean("An edited occurrence of a repeating event."),
            "lastModified": S.string("Last change."),
            "openURL": S.string("Link that opens it in Calendar."),
        ], required: ["id", "title", "start", "end"], "An event.")

    static let reminderList = S.object(
        [
            "id": S.string("List id."), "title": S.string("Title."), "account": S.string("Account."),
            "color": S.string("Hex color."), "isEditable": S.boolean("Can hold new reminders."),
            "isDefault": S.boolean("The default for new reminders."),
        ], required: ["id", "title"])

    static let reminder = S.object(
        [
            "id": S.string("Reminder id."),
            "listId": S.string("List id."),
            "listTitle": S.string("List title."),
            "title": S.string("Title."),
            "notes": S.string("Notes."),
            "url": S.string("URL."),
            "isCompleted": S.boolean("Completed."),
            "completionDate": S.string("When it was completed."),
            "dueDate": S.string("Due."),
            "dueIsDateOnly": S.boolean("Due on a day, with no time."),
            "startDate": S.string("Start."),
            "priority": S.integer("0 none, 1 high, 5 medium, 9 low."),
            "priorityLabel": S.string("Priority as a word."),
            "alarms": S.array(alarm, "Alerts."),
            "recurrence": recurrence,
            "lastModified": S.string("Last change."),
            "openURL": S.string("Link that opens it in Reminders."),
        ], required: ["id", "title"], "A reminder.")

    // MARK: Contacts

    static let labeled = S.array(
        S.object(["label": S.string("Label, e.g. `home`."), "value": S.string("Value.")], required: ["value"]),
        "Labeled values.")

    static let contactSummary = S.object(
        [
            "id": S.string("Contact id."), "displayName": S.string("Name."),
            "organization": S.string("Company."), "phones": labeled, "emails": labeled,
        ], required: ["id", "displayName"], "A contact.")

    static let contact = S.object(
        [
            "id": S.string("Contact id."),
            "displayName": S.string("Name."),
            "givenName": S.string("First name."),
            "familyName": S.string("Last name."),
            "middleName": S.string("Middle name."),
            "nickname": S.string("Nickname."),
            "organization": S.string("Company."),
            "jobTitle": S.string("Job title."),
            "department": S.string("Department."),
            "phones": labeled,
            "emails": labeled,
            "urls": labeled,
            "postalAddresses": S.array(
                S.object([
                    "label": S.string("Label."), "street": S.string("Street."), "city": S.string("City."),
                    "state": S.string("State."), "postalCode": S.string("Postal code."),
                    "country": S.string("Country."), "formatted": S.string("The whole address."),
                ]), "Addresses."),
            "birthday": S.string("Birthday."),
            "relations": labeled,
            "socialProfiles": labeled,
            "hasImage": S.boolean("Has a photo."),
            "openURL": S.string("Link that opens it in Contacts."),
        ], required: ["id", "displayName"], "A contact card.")

    // MARK: Messages & Notes

    static let conversation = S.object(
        [
            "id": S.string("Chat id: pass as `chat_id`."),
            "chatIdentifier": S.string("Handle or group id."),
            "displayName": S.string("Group name."),
            "participants": S.array(S.string("Handle."), "Participants."),
            "service": S.string("Service."),
            "isGroup": S.boolean("Group chat."),
            "lastMessageDate": S.string("Last message time."),
            "lastMessagePreview": S.string("Last message text."),
            "unreadCount": S.integer("Unread messages."),
        ], required: ["id"])

    static let textMessage = S.object(
        [
            "id": S.string("Message id."),
            "chatId": S.string("Chat id."),
            "sender": S.string("Sender handle."),
            "isFromMe": S.boolean("Sent by the user."),
            "date": S.string("When."),
            "text": S.string("The text."),
            "isRead": S.boolean("Read."),
            "service": S.string("Service."),
            "hasAttachments": S.boolean("Has attachments."),
        ], required: ["id", "text"])

    static let noteFolder = S.object(
        [
            "id": S.string("Folder id."), "name": S.string("Name."), "account": S.string("Account."),
            "noteCount": S.integer("Notes in it."),
        ], required: ["id", "name"])

    static let noteSummary = S.object(
        [
            "id": S.string("Note id."), "title": S.string("Title."), "folder": S.string("Folder."),
            "created": S.string("Created."), "modified": S.string("Last change."),
            "preview": S.string("The first ~200 characters."),
        ], required: ["id", "title"])

    static let note = S.object(
        [
            "id": S.string("Note id."),
            "title": S.string("Title."),
            "folder": S.string("Folder."),
            "created": S.string("Created."),
            "modified": S.string("Last change."),
            "plaintext": S.string("The note's text."),
            "characterCount": S.integer("Length of `plaintext`."),
            "hasAttachments": S.boolean("Has attachments."),
            "attachments": S.array(S.string("Name."), "Attachment names."),
        ], required: ["id", "title", "plaintext"], "A note.")

    // MARK: Mail

    static let mailbox = S.object(
        [
            "path": S.string("Mailbox path: pass as `mailbox_path`."), "name": S.string("Name."),
            "account": S.string("Account."), "unreadCount": S.integer("Unread messages."),
        ], required: ["path", "name"])

    static let mailSummary = S.object(
        [
            "id": S.string("Message-ID: pass as `id`."),
            "subject": S.string("Subject."),
            "sender": S.string("From."),
            "dateReceived": S.string("Received."),
            "dateSent": S.string("Sent."),
            "isRead": S.boolean("Read."),
            "isFlagged": S.boolean("Flagged."),
            "mailboxPath": S.string("Its mailbox."),
        ], required: ["id", "subject", "sender"], "A message.")

    static let mailContent = S.object(
        [
            "id": S.string("Message-ID."),
            "subject": S.string("Subject."),
            "sender": S.string("From."),
            "to": S.array(S.string("Address."), "To."),
            "cc": S.array(S.string("Address."), "Cc."),
            "replyTo": S.string("Reply-To."),
            "dateReceived": S.string("Received."),
            "dateSent": S.string("Sent."),
            "isRead": S.boolean("Read."),
            "isFlagged": S.boolean("Flagged."),
            "isJunk": S.boolean("Junk."),
            "mailboxPath": S.string("Its mailbox."),
            "content": S.string("The body as plain text."),
            "attachments": S.array(
                S.object([
                    "name": S.string("File name."), "sizeBytes": S.integer("Size."),
                    "mimeType": S.string("MIME type."),
                ]), "Attachments."),
        ], required: ["id", "subject", "sender", "content"], "The message.")

    // MARK: Maps

    static let coordinate = S.object(
        ["latitude": S.number("Latitude."), "longitude": S.number("Longitude.")],
        required: ["latitude", "longitude"], "A coordinate.")

    static let place = S.object(
        [
            "name": S.string("Name."),
            "coordinate": coordinate,
            "address": S.string("Full address."),
            "street": S.string("Street."),
            "city": S.string("City."),
            "state": S.string("State."),
            "postalCode": S.string("Postal code."),
            "country": S.string("Country."),
            "countryCode": S.string("Country code."),
            "phone": S.string("Phone."),
            "url": S.string("Website."),
            "category": S.string("Category."),
            "timeZone": S.string("Time zone."),
            "mapsURL": S.string("Link that opens it in Maps."),
        ], required: ["coordinate", "mapsURL"], "A place.")

    static let route = S.object(
        [
            "name": S.string("Route name."),
            "distanceMeters": S.number("Distance."),
            "expectedTravelSeconds": S.number("Travel time in seconds."),
            "expectedTravelText": S.string("Travel time, e.g. `13 min`."),
            "distanceText": S.string("Distance as text."),
            "transportType": S.string("Transport mode."),
            "advisoryNotices": S.array(S.string("Notice."), "Advisories."),
            "steps": S.array(
                S.object([
                    "instructions": S.string("What to do."), "distanceMeters": S.number("Distance."),
                    "notice": S.string("Notice."),
                ]), "Turn-by-turn steps."),
            "mapsURL": S.string("Link that opens it in Maps."),
        ], required: ["name", "expectedTravelSeconds"], "A route.")

    static let eta = S.object(
        [
            "expectedTravelSeconds": S.number("Travel time in seconds."),
            "distanceMeters": S.number("Distance."),
            "expectedTravelText": S.string("Travel time, e.g. `13 min`."),
            "distanceText": S.string("Distance as text."),
            "transportType": S.string("Transport mode."),
            "expectedDeparture": S.string("Departure time."),
            "expectedArrival": S.string("Arrival time."),
        ], required: ["expectedTravelSeconds"], "The estimate.")

    static let currentLocation = S.object(
        [
            "coordinate": coordinate,
            "horizontalAccuracyMeters": S.number("Accuracy radius."),
            "altitudeMeters": S.number("Altitude."),
            "timestamp": S.string("When the fix was taken."),
            "place": place,
        ], required: ["coordinate"], "Where this Mac is.")

    // MARK: Music & Shortcuts

    static let track = S.object(
        [
            "id": S.string("Track id."), "name": S.string("Title."), "artist": S.string("Artist."),
            "album": S.string("Album."), "durationSeconds": S.number("Length."), "year": S.integer("Year."),
            "genre": S.string("Genre."), "rating": S.integer("Rating."), "playedCount": S.integer("Plays."),
        ], required: ["id", "name"], "A track.")

    static let playlist = S.object(
        [
            "id": S.string("Playlist id."), "name": S.string("Name."), "trackCount": S.integer("Tracks."),
            "durationSeconds": S.number("Length."), "kind": S.string("Kind."),
        ], required: ["id", "name"])

    static let player = S.object(
        [
            "state": S.string("Player state, e.g. `playing` or `paused`."),
            "track": track,
            "positionSeconds": S.number("Position in the track."),
            "volume": S.integer("Volume, 0–100."),
            "shuffle": S.boolean("Shuffle on."),
            "repeatMode": S.string("Repeat mode."),
        ], required: ["state"], "The player.")

    static let shortcut = S.object(
        ["name": S.string("Name."), "identifier": S.string("Stable id."), "folder": S.string("Folder.")],
        required: ["name"])

    static let shortcutRun = S.object(
        [
            "name": S.string("The shortcut run."),
            "output": S.string("Its text output."),
            "outputIsEmpty": S.boolean("True when it produced nothing."),
            "outputIsBinary": S.boolean("True when the output is not text."),
            "outputBytes": S.integer("Output size."),
            "outputTruncated": S.boolean("True when `output` was cut."),
            "durationSeconds": S.number("How long it ran."),
        ], required: ["name"], "The run.")
}
