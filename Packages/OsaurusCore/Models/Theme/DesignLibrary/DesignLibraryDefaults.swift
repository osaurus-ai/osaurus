import SwiftUI

enum DesignLibraryDefaults {
    static let inputDefaults = [
        "component.input.paddingX":"space.12", "component.input.paddingY":"space.6",
        "component.input.label.text":"type.label", "component.input.label.foreground":"color.text.primary",
        "component.input.helper.text":"type.footnote", "component.input.helper.foreground":"color.text.tertiary",
        "component.input.error.foreground":"color.border.error", "component.input.borderWidth":"stroke.default",
        "component.input.contentGap":"space.6",
        "component.settings.heading":"type.heading", "component.settings.text":"type.bodySmall",
        "component.settings.caption":"type.caption", "component.settings.foreground":"color.text.primary",
        "component.settings.secondary":"color.text.secondary", "component.settings.gap":"space.24",
        "component.settings.actionGap":"space.12", "component.settings.borderWidth":"stroke.default"
    ]
}

struct CatalogComponentSpec:Identifiable {
    let id:Int
    let name:String
    let detail:String
    var assignmentFamily: Int { (58...64).contains(id) ? (id == 62 ? 18 : id == 63 ? 57 : 12) : id }
    var key:String {id == 65 ? "component.contextMenu" : "component.library.\(assignmentFamily)"}
    var section:String {"library.\(id)"}
    var isBase:Bool {id <= 20 || id == 56 || id == 57 || id == 65}
    var isComposition: Bool { [13,14,15,16,17,18,19,20,57].contains(id) || (58...64).contains(id) }
    var isProduct: Bool { !isBase && !isComposition }
    var isMessaging: Bool { id == 24 || (28...40).contains(id) }
    var Catalogstates:[String] {
        switch id {
        case 29,31,32:return ["default","streaming","complete","empty","error","disabled"]
        case 3,21:return ["empty","filled","disabled","error","sending","queued"]
        case 4,6,15,41:return ["default","selected","hover","disabled"]
        case 12,33,34,35,45,47,49:return ["waiting","running","complete","error","disabled"]
        case 18,19,36,40,52:return ["info","success","warning","error"]
        default:return ["default","hover","selected","disabled","error"]
        }
    }
    var inherited:[String] {
        var keys = ["component.focus.color","component.focus.width","component.focus.offset"]
        if [5,9,13,15,16,17,18,19,21,22,24,25,26,27,28,29,30,32,34,35,36,37,38,40,41,42,43,44,45,46,47,48,49,50,51,52,53,54,55].contains(id) {
            keys += ["component.button.label","component.button.radius","component.button.paddingX","component.button.paddingY","component.button.minimumHeight"]
            for variant in ["primary","secondary","tertiary","destructive"] {
                for state in ["default","hover","pressed","disabled"] {for property in ["background","foreground","border"] {keys.append("component.button.\(variant).\(state).\(property)")}}
                keys.append("component.button.\(variant).focus.color")
            }
        }
        if [16,17,21,25,26,27,28,36,41,44,46,47,50,51,52,55].contains(id) {
            keys += ["component.control.heightDefault"] + Array(DesignLibraryDefaults.inputDefaults.keys)
            keys += ["component.input.background","component.input.foreground","component.input.placeholder","component.input.border","component.input.borderHover","component.input.borderError","component.input.disabled.background","component.input.disabled.foreground","component.input.radius","component.input.text"]
        }
        return Array(Set(keys)).sorted()
    }
    var defaults:[String:String] {
        if id == 65 { return ChatContextMenuAssignments.defaults }
        // These navigation entries preserve existing compositions and their
        // original assignments; they do not introduce a second style recipe.
        if (58...64).contains(id) { return [:] }
        var d = ["background":"color.surface.raised","foreground":"color.text.primary","secondary":"color.text.secondary","border":"color.border.default","hover":"color.surface.hover","selected":"color.surface.selected","accent":"color.border.focus","disabledBackground":"color.surface.disabled","disabledForeground":"color.text.disabled","error":"color.status.error.foreground","success":"color.status.success.foreground","warning":"color.status.warning.foreground","placeholder":"color.text.placeholder","heading":"type.heading","text":"type.bodySmall","label":"type.label","caption":"type.caption","code":"type.code","radius":"radius.medium","padding":"space.12","gap":"space.8","height":"size.control.defaultHeight","borderWidth":"stroke.default","avatarSize":"size.chat.avatar"]
        if id == 5 { d["paddingY"] = "space.6" }
        if id == 6 { d["selectedBorder"] = "color.border.strong" }
        if [4,46,48,50,52].contains(id) {d["onBackground"]="color.border.focus";d["offBackground"]="color.surface.selected";d["onForeground"]="color.action.primary.default.foreground";d["switchWidth"]="space.48";d["switchHeight"]="size.control.compactHeight";d["indicatorSize"]="space.24";d["thumbSize"]="space.16"}
        if [7,12,46].contains(id) {d["trackHeight"]="space.6";d["thumbSize"]="space.16"}
        if id == 31 { d["emphasis"] = "type.bodyEmphasis" }
        if id == 28 {d["background"]="color.chat.user.background";d["radius"]="radius.bubble"}
        if id == 29 {d["background"]="color.chat.assistant.background";d["radius"]="radius.bubble"}
        if [31,32,38,39].contains(id) {d["background"]="color.surface.code"}
        if [16,17,25,26,27,36].contains(id) {d["background"]="color.surface.overlay";d["radius"]="radius.xlarge"}
        if [41,42].contains(id) {d["background"]="color.surface.sidebar"}
        // Expose properties used by the component's production views as well
        // as its catalog specimen.
        if ![6,12,13,14,16,17,19,21,22,23,24,26,27,28,31,34,35,36,37,38,39,41,42,46,47,48,49,50,51,52,53,54,55].contains(id) {d.removeValue(forKey:"heading")}
        if ![3,4,5,7,9,11,14,15,16,18,20,21,23,25,26,27,29,30,31,33,34,35,36,37,38,40,41,42,43,46,47,48,49,50,52,53,54].contains(id) {d.removeValue(forKey:"label")}
        if ![31,32,34,35,36,37,38,39,49,52,53,55].contains(id) {d.removeValue(forKey:"code")}
        if ![11,29,30].contains(id) {d.removeValue(forKey:"avatarSize")}
        if ![10,12,18,26,33,34,35,36,38,39,40,47,49,51,53].contains(id) {d.removeValue(forKey:"success")}
        if ![10,18,35,36,38,39,40,41,43,45,49,51,53].contains(id) {d.removeValue(forKey:"warning")}
        d.removeValue(forKey:"placeholder")
        return Dictionary(uniqueKeysWithValues:d.map{(key + "." + $0.key,$0.value)})
    }
}

let CatalogcomponentCatalog:[CatalogComponentSpec] = [
    CatalogComponentSpec(id:1,name:"Buttons",detail:"Primary, secondary, tertiary, destructive; text, icon-only, icon+text; loading and disabled"),
    CatalogComponentSpec(id:2,name:"Text fields",detail:"Single-line, secure/reveal, search, clear action; labels, hints, validation"),
    CatalogComponentSpec(id:3,name:"Multiline text editor",detail:"Growing height, placeholder, selection, long text, paste and composition input"),
    CatalogComponentSpec(id:4,name:"Switches and checkboxes",detail:"Standalone switch and checkbox controls: on, off and disabled. Used inside settings rows in Chat, Server and channel settings. Row layout is under Composed components."),
    CatalogComponentSpec(id:65,name:"Context menus",detail:"Shared menu container, rows and dividers. Used by app dropdowns, action menus and context menus in Chat, Settings, Workflows, agents, files and projects. Edit these assignments once to update every popup."),
    CatalogComponentSpec(id:5,name:"Selects and menus",detail:"Standalone select, menu button and overflow button. Used in voice, model, sharing and queue settings. Button appearance comes from Buttons."),
    CatalogComponentSpec(id:6,name:"Segmented controls and tabs",detail:"Standalone segmented controls and tabs with optional counts. Used in voice and image settings and library filters. No settings-row wrapper."),
    CatalogComponentSpec(id:7,name:"Sliders and number steppers",detail:"Standalone slider and number steppers: integer, unit and inherited value. Used in provider and voice settings, email ports and workspace limits."),
    CatalogComponentSpec(id:8,name:"Date and time picker",detail:"Time fields with AM/PM · recurring and one-time schedules. Date field · Workflow forms. Combined field · Agent Resume at. Calendar popup stays native."),
    CatalogComponentSpec(id:9,name:"Shortcut recorder and key hints",detail:"HotkeyRecorder · Settings → General and Voice → Transcription. PickerCardKeyHints · searchable chat pickers."),
    CatalogComponentSpec(id:10,name:"Badges and tags",detail:"StatusChip and CountBadge · model, agent, provider and settings lists. Informational badges; editable filter/selector chips are under Chips."),
    CatalogComponentSpec(id:56,name:"Chips",detail:"Shared selector, filter and removable chips. Small and regular sizes; used by chat toolbar and settings filters."),
    CatalogComponentSpec(id:11,name:"Avatars and identity marks",detail:"AgentAvatarView · chat sidebar, empty conversation, Orchestrator and Architect settings. Mascot or name fallback; the identity color belongs to the agent."),
    CatalogComponentSpec(id:12,name:"Progress and status indicators",detail:"SettingsProgressBar and status indicators · model downloads, workflow media and toasts. Progress value and status determine the appearance."),
    CatalogComponentSpec(id:13,name:"Library cards",detail:"LibraryCard — used for model cards in Models, agent cards in Agents, and agent templates. Existing card variants; settings groups are on Settings sections."),
    CatalogComponentSpec(id:14,name:"Settings rows",detail:"SettingsRow — used throughout Settings, including Chat and Configuration. Value, toggle, picker, link and navigation variants. Rows are flat inside a Settings section and standalone outside one."),
    CatalogComponentSpec(id:57,name:"Settings sections",detail:"Header, optional supporting text, grouped or plain content, divider and footer. Used across Settings. Child rows and controls have their own base styles."),
    CatalogComponentSpec(id:15,name:"Expandable settings section",detail:"SettingsAdvancedDisclosure — the Advanced section in Settings > Chat and Settings > Configuration. Collapsed and expanded; child controls retain their own styles."),
    CatalogComponentSpec(id:16,name:"Popover container",detail:"PickerCard / popoverCard — used by model and agent pickers. This page edits the floating panel, heading and footer. Picker contents belong to their own components."),
    CatalogComponentSpec(id:17,name:"Sheet container",detail:"SettingsSheet — used by Add email account, Generate access key, and agent runtime setup. Existing header, body and action footer; inputs and buttons retain their base styles."),
    CatalogComponentSpec(id:18,name:"Inline banners and toasts",detail:"InlineBanner · Search, Providers, Tools and Workspace settings. ToastView · app notifications. Info, success, warning, error and action variants."),
    CatalogComponentSpec(id:19,name:"Empty and unavailable states",detail:"SettingsEmptyState · Insights, Browser, Agent Runtimes and channel settings. Empty, no-results and unavailable messages with optional actions."),
    CatalogComponentSpec(id:20,name:"Tables and data lists",detail:"LibraryRow and settings table rows · Search, Providers and Agent Runtimes. Table cells are distinct from grouped SettingsRow controls."),
    CatalogComponentSpec(id:58,name:"Step trackers",detail:"Existing SettingsStepTracker retained from the app. Composed component; its original assignments are preserved."),
    CatalogComponentSpec(id:59,name:"Statistics",detail:"Existing SettingsStatStrip and stat tiles retained from the app. Composed component; its original assignments are preserved."),
    CatalogComponentSpec(id:60,name:"Status panels",detail:"Existing SettingsStatusHero retained from the app. Composed component; its original assignments are preserved."),
    CatalogComponentSpec(id:61,name:"Finding rows",detail:"Existing SettingsFindingRow retained from the app. Composed component; its original assignments are preserved."),
    CatalogComponentSpec(id:62,name:"Callouts",detail:"Existing SettingsCallout retained from the app. Composed component; its original assignments are preserved."),
    CatalogComponentSpec(id:63,name:"Drill-in rows",detail:"Existing SettingsDrillInRows retained from the app. Composed component; its original assignments are preserved."),
    CatalogComponentSpec(id:64,name:"Icon tiles",detail:"Existing SettingsIconTile retained from the app. Composed component; its original assignments are preserved."),
    CatalogComponentSpec(id:21,name:"Chat composer",detail:"Multiline editor + toolbar + attachment tray; empty, typing, expanded, sending, stopped and blocked"),
    CatalogComponentSpec(id:22,name:"Composer action controls",detail:"Send, stop, queue/send-now, attachment, slash command and voice; reuse base buttons"),
    CatalogComponentSpec(id:23,name:"Composer selector/context chips",detail:"Model, folder, skill, sandbox, clipboard, context budget, credits/workspace; selection and unavailable states"),
    CatalogComponentSpec(id:24,name:"Attachment chips and thumbnails",detail:"Composer · pending files, images, pasted text and media. Chat · attachments above a sent user message. Select the location to edit its actual attachment view."),
    CatalogComponentSpec(id:25,name:"Command and file suggestion menus",detail:"Slash commands and @file results, filtering, highlighted result and empty state"),
    CatalogComponentSpec(id:26,name:"Model picker",detail:"Trigger + searchable rows + availability/category/detail; model-specific row variants"),
    CatalogComponentSpec(id:27,name:"Agent/workspace picker",detail:"Identity row, selected agent/workspace, status and availability"),
    CatalogComponentSpec(id:28,name:"User message",detail:"Chat · sent text, long messages, file/image attachments, inline editing and dispatched messages. Uses shared buttons, multiline editor and attachment components."),
    CatalogComponentSpec(id:29,name:"Agent message",detail:"Chat · agent header, formatted body, metadata and actions. Completed, streaming, waiting, finishing, interrupted, empty and failed replies use the actual transcript builder."),
    CatalogComponentSpec(id:30,name:"Message header and actions",detail:"Chat · agent identity above a reply, actions and run metadata below it. Avatars and Buttons supply their shared appearance."),
    CatalogComponentSpec(id:31,name:"Rich-text message content",detail:"Chat · formatted agent message text. Plugin details also use the SwiftUI Markdown renderer shown separately. Code fences have their own Code blocks page."),
    CatalogComponentSpec(id:32,name:"Code blocks",detail:"Chat · fenced code inside an agent reply. Plugin editors use the SwiftUI code renderer shown separately. Both retain their actual Copy and overflow behavior."),
    CatalogComponentSpec(id:33,name:"Thinking and generation status",detail:"Chat · reasoning disclosure above an agent reply; generation indicator while waiting for text or finishing. Reasoning can be collapsed or expanded."),
    CatalogComponentSpec(id:34,name:"Tool-call and activity blocks",detail:"Chat · pending tool arguments, individual tool results and grouped reasoning/tool activity. Expand the actual rows to see arguments and output."),
    CatalogComponentSpec(id:35,name:"Agent progress and subagent items",detail:"Chat · agent task checklist and completion/blocked summary. Delegated and computer-use tool activity uses the subagent event feed below."),
    CatalogComponentSpec(id:36,name:"Approval and clarification prompts",detail:"Chat · clarification cards, secret request, computer-action confirmation and cloud consent. Configuration plans use the actual approval dialog content."),
    CatalogComponentSpec(id:37,name:"Artifact preview cards",detail:"Chat · files shared by the agent: document, image, PDF, audio, web page or folder. The actual file type and local-path availability determine the preview and actions."),
    CatalogComponentSpec(id:38,name:"File-change and diff items",detail:"Chat · inline file diff. File changes panel · current created/modified/deleted files, history and revert outcomes. These are distinct existing app views."),
    CatalogComponentSpec(id:39,name:"Terminal and chart content",detail:"Chat · terminal output from command tools and charts embedded in agent replies. Choose the actual renderer; no command is executed."),
    CatalogComponentSpec(id:40,name:"Conversation notices and markers",detail:"Chat · connection, hosted-run and unsaved-conversation notices; compaction summary, charged empty reply and follow-up suggestions."),
    CatalogComponentSpec(id:41,name:"Sidebar row family",detail:"Chat/session, project, local/remote/shared agent, footer; selected, hover, running, rename and action menu"),
    CatalogComponentSpec(id:42,name:"Sidebar section and panel chrome",detail:"Section headers, lens/segment selector, container, footer; isolated chrome without fixing full navigation layout"),
    CatalogComponentSpec(id:43,name:"Chat tab and header controls",detail:"Tab label, active state, close, overflow; header actions reuse base buttons"),
    CatalogComponentSpec(id:44,name:"Conversation search and navigation",detail:"Find bar, match count, previous/next; minimap as optional specialized specimen"),
    CatalogComponentSpec(id:45,name:"Voice input and transcription",detail:"Idle/listening/transcribing/error; waveform/status, transcript and stop/cancel"),
    CatalogComponentSpec(id:46,name:"Settings rows and groups",detail:"Toggle, picker, text, slider, link and destructive rows assembled from base controls"),
    CatalogComponentSpec(id:47,name:"Model/provider connection and download items",detail:"Credential field, connection/status row, model download/progress and retry"),
    CatalogComponentSpec(id:48,name:"Agent/capability/plugin/skill catalog items",detail:"Reusable identity/status/action rows and cards; consolidate repeated implementations"),
    CatalogComponentSpec(id:49,name:"Workspace/resource and provisioning items",detail:"Pool/resource row, activity/audit item, provisioning step and post-start task"),
    CatalogComponentSpec(id:50,name:"Schedule/watcher configuration items",detail:"Trigger/rule row, next-run summary, date/time control and enabled state"),
    CatalogComponentSpec(id:51,name:"Usage, credits and resource summaries",detail:"Usage bar/chart, balance, limits, redeem-code and top-up form patterns"),
    CatalogComponentSpec(id:52,name:"Privacy and identity/security items",detail:"Redaction preview/review, rule editor, permission summary, credential/recovery presentation"),
    CatalogComponentSpec(id:53,name:"Data, knowledge and memory items",detail:"Data-grid cell/row, history/change record, knowledge preview and memory entry"),
    CatalogComponentSpec(id:54,name:"Image-generation option and result items",detail:"Size/settings selection, progress, result thumbnail and preview"),
    CatalogComponentSpec(id:55,name:"Onboarding, announcements and tours",detail:"Step, choice card, progress/navigation and announcement pattern; preserve as patterns until redesigned"),
]
