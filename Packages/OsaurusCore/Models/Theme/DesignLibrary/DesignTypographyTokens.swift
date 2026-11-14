import Foundation

enum DesignTypographyTokens {
    static let roles: Set<String> = ["type.subheading", "type.bodyEmphasis", "type.chatBody"]
    /// Extend older documents once. Existing values and explicit alternate assignments win.
    static func extend(_ original: DesignWorkingDocument) -> DesignWorkingDocument {
        var doc = original
        let addingChat = doc.tokens["type.chatBody"] == nil
        let addingSubheading = doc.tokens["type.subheading"] == nil
        func token(size: Double, weight: Double, line: Double, use: String) -> DesignToken {
            let value = JSONValue.object(["family":.string("system"),"size":.number(size),"weight":.number(weight),"lineHeight":.number(line),"tracking":.number(0),"unit":.string("pt")])
            return DesignToken(type:"typography",light:value,dark:value,use:use)
        }
        if addingSubheading { doc.tokens["type.subheading"] = token(size:16,weight:600,line:22,use:"Smaller section headings within settings, cards and panels. Connected to actual Settings section headings such as Appearance and Behavior; separate from screen titles and larger headings.") }
        if doc.tokens["type.bodyEmphasis"] == nil { doc.tokens["type.bodyEmphasis"] = token(size:15,weight:600,line:22,use:"Emphasized (bold/strong) prose within chat messages, lists and quotations. Controls the full text recipe independently of regular Chat Body. Does not restyle Markdown headings or inline code.") }
        if addingChat {
            var body = doc.tokens["type.body"] ?? token(size:15,weight:400,line:22,use:"")
            body.use = "Reading text in user and assistant messages, including paragraphs, lists and quotations. Starts from your current Body style, then edits independently so settings descriptions remain unchanged. Code and Markdown headings keep their own styles."
            doc.tokens["type.chatBody"] = body
            for family in [28,29,31] {
                let key = "component.library.\(family).text"
                if doc.mappings[key] == nil || doc.mappings[key] == "type.bodySmall" { doc.mappings[key] = "type.chatBody" }
            }
        }
        if addingSubheading, doc.mappings["component.library.14.heading"] == nil || doc.mappings["component.library.14.heading"] == "type.heading" { doc.mappings["component.library.14.heading"] = "type.subheading" }
        if doc.mappings["component.library.31.emphasis"] == nil { doc.mappings["component.library.31.emphasis"] = "type.bodyEmphasis" }
        // Existing upstream roles; expose them without changing saved recipes or assignments.
        if doc.tokens["type.footnote"] == nil { doc.tokens["type.footnote"] = token(size:11,weight:400,line:14,use:"Small supporting text, as assigned by the updated app.") }
        if doc.tokens["type.micro"] == nil { doc.tokens["type.micro"] = token(size:10,weight:400,line:13,use:"Compact metadata, as assigned by the updated app.") }
        return doc
    }
}
