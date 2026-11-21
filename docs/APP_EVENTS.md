# App events: what a workflow trigger can listen to

Which signals from other Mac apps Osaurus could use to start a workflow,
measured on a real Mac rather than read from API docs. The probe is
[`scripts/app-events-probe/probe.swift`](../scripts/app-events-probe/probe.swift):

```bash
swift scripts/app-events-probe/probe.swift --seconds 16 --exercise
```

It prints one JSON line per signal. With `--exercise` it launches Calculator
in the background, brings it forward, hands focus back, quits it, posts a
distributed notification of its own, and posts a banner through
`osascript display notification`, timing each. It never opens the
Notification Center database; it only checks whether it could.

## Run recorded here

- macOS 26.5.2 (25F84), user session (uid 501), not root.
- Run from the Cursor terminal, which holds Accessibility trust and no Full
  Disk Access. Calendar was write-only, Reminders and Contacts had never
  been asked.
- Three runs of 14 to 16 seconds. Latency is from the probe's own action to
  the observer firing; launch latency includes the app's launch time.

## Findings

| Signal | Fired | Permission | Latency | Verdict |
| --- | --- | --- | --- | --- |
| `NSWorkspace` app launched / quit / activated / deactivated | Yes, every run | None | 144–228 ms launch, 22–33 ms activate, 5 ms deactivate, 60–71 ms quit | **Ship** (Mac App trigger) |
| `NSWorkspace` hide, Space change, sleep / wake, volume mount | Observed, not exercised | None | Not measured | Later |
| Named distributed notification | Yes | None | 1–3 ms | Later |
| Distributed notification wildcard (`name: nil`) | No, not even the probe's own post | Root only | n/a | No |
| Accessibility observer on an app | Yes, once the app has launched | Accessibility | Within a few ms | Later |
| Notification banners via Accessibility | No | Accessibility | n/a | No |
| Notification Center database | Exists, not readable | Full Disk Access | n/a | No |
| Calendar / Reminders change (`EKEventStoreChanged`) | Not exercised | Full calendar or reminders access | n/a | Later |
| Contacts change (`CNContactStoreDidChange`) | Not exercised | Contacts | n/a | No |

### App lifecycle (`NSWorkspace`)

Every launch, quit, activate, and deactivate of Calculator arrived, with
`NSWorkspace.applicationUserInfoKey` carrying bundle id, localized name, and
pid. The other side of each switch arrives too: activating Calculator
deactivated Chrome in the same tick. No permission and no prompt. This is
what the **Mac App** automation listens to (`mac_app` source kind), so a
workflow can run when an app opens, quits, or comes to the front.

An app that opens comes to the front first: on this Mac the activate
notification arrived about 100 ms before the launch notification, with
`isFinishedLaunching` still false. The Mac App adapter uses that flag so an
automation watching both *Opens* and *Comes to the front* fires once per
opening, as `launched`; one watching only *Comes to the front* still fires.

Hide, unhide, Space changes, sleep, wake, and volume mounts come from the
same notification center with no permission. They were registered but not
exercised (doing that would sleep the Mac or mount a disk). Sleep/wake and
"a disk was mounted" are plausible next triggers.

### Distributed notifications

A named observer received the probe's own post in 1–3 ms with its
`userInfo` intact, and `com.apple.bluetooth.status` arrived every five
seconds unprompted. The wildcard observer (`addObserver(forName: nil)`)
received nothing at all, including the probe's own post: macOS delivers the
wildcard only to root. Osaurus does not run as root, so there is no "listen
to everything" and no way to discover names at run time.

That makes named notifications a catalog problem, not an API one. The names
are undocumented and owned by each app (`com.apple.Music.playerInfo`,
`com.spotify.client.PlaybackStateChanged`, `com.apple.screenIsLocked`), so a
trigger would need a curated list per app, each verified on a real install.
Verdict: later, as a "Music started a track" or "screen locked" preset rather
than a free-form name field.

### Accessibility observers

With Accessibility trust, an `AXObserver` on Calculator delivered
`AXApplicationActivated` and `AXApplicationDeactivated` as the probe
switched apps. Registering before the app finished launching added nothing
(the first run's empty `added` list); the observer must be attached per
process, after launch, and again after every relaunch. Window created,
focused window, and title changed are available the same way.

Verdict: later. It is the only source of window-level events ("a window
titled Invoice opened"), but it needs Accessibility, per-process lifetimes,
and each app reports titles differently.

### Notification banners and the Notification Center database

The probe attached an Accessibility observer to the Notification Center
agent (`com.apple.notificationcenterui`) and posted a banner with
`osascript display notification`. No window-created event arrived. Banners
are not exposed as observable windows of that process in a way an observer
can rely on.

The database at
`~/Library/Group Containers/group.com.apple.usernoted/db2/db` exists but is
not readable without Full Disk Access, and its schema is private and has
changed across macOS releases. Reading other apps' notifications this way
is also a privacy line Osaurus should not cross by default.

Verdict: no, for both. "When Mail notifies me" is better served by the
app's own data (the Mail tools) on a schedule, or by a Shortcuts automation
that runs the workflow.

### Calendar, Reminders, Contacts

`EKEventStoreChanged` and `CNContactStoreDidChange` need full access for the
observing process and say only that something changed, not what. The probe
ran without that access and recorded only the authorization state. A
"calendar changed" trigger would then have to diff the store itself.
Verdict: later for Calendar and Reminders, where Osaurus already holds
access through its Apple app tools; no for Contacts.

## Shortcuts

The `shortcuts` command line on this macOS offers `run`, `list`, `view`, and
`sign`, and nothing about automations. Apple's own Shortcuts automations
(time of day, an app opening, a file arriving, a display or network
connecting, and so on) are configured in the Shortcuts app, and cannot be
listed or created from outside it.

So Osaurus does not try to replicate them. It adds a **Run Workflow** action
to Shortcuts instead (`RunWorkflowIntent`, backed by
`POST /workflows/{id}/run`), which lets any Shortcuts automation the person
sets up start an Osaurus workflow. Combined with the Mac App trigger, that
covers app-driven workflows from both directions.

## Not covered

- Runs as root, which would show what the wildcard distributed observer
  delivers there.
- A curated list of named distributed notifications per app.
- Banners from an app with notification permission granted, observed with
  Screen Recording rather than Accessibility.
