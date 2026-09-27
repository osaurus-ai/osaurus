//
//  OOXMLPackage.swift
//  osaurus
//
//  An Office Open XML package (docx / xlsx / pptx) opened for in-place
//  editing. Parts are parsed lazily with `XMLDocument`; on save only the
//  parts an edit touched are re-serialized, and every other zip entry is
//  copied byte-for-byte (see `ZipArchive.rewrite`), so styles, media,
//  embedded objects and macros survive an edit untouched.
//

import Foundation

enum OOXMLNamespace {
    static let wordprocessing = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
    static let drawing = "http://schemas.openxmlformats.org/drawingml/2006/main"
    static let presentation = "http://schemas.openxmlformats.org/presentationml/2006/main"
    static let spreadsheet = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    static let officeRelationships = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    static let packageRelationships = "http://schemas.openxmlformats.org/package/2006/relationships"
    static let contentTypes = "http://schemas.openxmlformats.org/package/2006/content-types"
}

enum OOXMLRelationshipType {
    private static let base = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/"
    static let officeDocument = base + "officeDocument"
    static let worksheet = base + "worksheet"
    static let calcChain = base + "calcChain"
    static let slide = base + "slide"
    static let notesSlide = base + "notesSlide"
    static let slideLayout = base + "slideLayout"
    static let slideMaster = base + "slideMaster"
    static let theme = base + "theme"
    static let presProps = base + "presProps"
    static let tableStyles = base + "tableStyles"
}

/// A user-facing reason a document edit was refused. Messages are written
/// for the model: what was wrong and what to do instead.
struct DocumentEditError: LocalizedError, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

final class OOXMLPackage {
    struct Relationship: Equatable {
        let id: String
        let type: String
        let target: String
        let external: Bool
    }

    let source: Data
    private var sourceNames: [String] = []
    private var sourceEntries: [String: ZipArchive.Entry] = [:]
    private var replaced: [String: Data?] = [:]
    private var xmlCache: [String: XMLDocument] = [:]
    private var dirtyXML = Set<String>()
    private var appended: [String] = []

    /// Parts bigger than this are never inflated for editing.
    static let maxPartBytes = 64 * 1024 * 1024

    init(data: Data) throws {
        guard ZipArchive.isArchive(data) else {
            throw DocumentEditError("The file isn't a valid Office document (it is not a zip package).")
        }
        source = data
        let entries: [ZipArchive.Entry]
        do {
            entries = try ZipArchive.entries(in: data)
        } catch {
            throw DocumentEditError("The document package is damaged and can't be edited safely: \(error.localizedDescription)")
        }
        for entry in entries where !entry.name.hasSuffix("/") {
            guard sourceEntries[entry.name] == nil else {
                throw DocumentEditError("The document package lists '\(entry.name)' twice; refusing to edit it.")
            }
            sourceNames.append(entry.name)
            sourceEntries[entry.name] = entry
        }
        guard sourceEntries["[Content_Types].xml"] != nil else {
            throw DocumentEditError("The document package has no [Content_Types].xml; it isn't a valid Office file.")
        }
    }

    // MARK: - Parts

    var partNames: [String] {
        sourceNames.filter { has($0) } + appended.filter { has($0) }
    }

    func has(_ part: String) -> Bool {
        if let replacement = replaced[part] { return replacement != nil }
        return sourceEntries[part] != nil || xmlCache[part] != nil
    }

    func data(_ part: String) throws -> Data {
        if dirtyXML.contains(part), let doc = xmlCache[part] { return Self.serialize(doc) }
        if let replacement = replaced[part] {
            guard let replacement else { throw DocumentEditError("Part '\(part)' was removed.") }
            return replacement
        }
        guard let entry = sourceEntries[part] else {
            throw DocumentEditError("The document has no part '\(part)'.")
        }
        guard entry.uncompressedSize <= Self.maxPartBytes else {
            throw DocumentEditError("Part '\(part)' is too large to edit (\(entry.uncompressedSize) bytes).")
        }
        do {
            return try ZipArchive.extract(entry, from: source, verifyChecksum: true)
        } catch {
            throw DocumentEditError("Part '\(part)' is damaged (\(error.localizedDescription)); refusing to edit.")
        }
    }

    func xml(_ part: String) throws -> XMLDocument {
        if let cached = xmlCache[part] { return cached }
        let bytes = try data(part)
        do {
            let doc = try XMLDocument(data: bytes, options: [.nodePreserveWhitespace, .nodePreserveCDATA])
            xmlCache[part] = doc
            return doc
        } catch {
            throw DocumentEditError("Part '\(part)' isn't well-formed XML; refusing to edit.")
        }
    }

    func root(_ part: String) throws -> XMLElement {
        guard let root = try xml(part).rootElement() else {
            throw DocumentEditError("Part '\(part)' has no root element.")
        }
        return root
    }

    /// Record that a parsed part was mutated in place.
    func markDirty(_ part: String) {
        dirtyXML.insert(part)
        replaced[part] = nil
    }

    func setXML(_ part: String, _ doc: XMLDocument) {
        noteAppended(part)
        xmlCache[part] = doc
        markDirty(part)
    }

    func setData(_ part: String, _ bytes: Data) {
        noteAppended(part)
        xmlCache[part] = nil
        dirtyXML.remove(part)
        replaced[part] = .some(bytes)
    }

    func remove(_ part: String) {
        xmlCache[part] = nil
        dirtyXML.remove(part)
        replaced[part] = .some(nil)
    }

    private func noteAppended(_ part: String) {
        if sourceEntries[part] == nil, !appended.contains(part) { appended.append(part) }
    }

    func serialize() throws -> Data {
        var replacing: [String: Data?] = replaced
        for part in dirtyXML {
            if let doc = xmlCache[part] { replacing[part] = Self.serialize(doc) }
        }
        do {
            return try ZipArchive.rewrite(source, replacing: replacing, appendOrder: appended)
        } catch {
            throw DocumentEditError("Couldn't assemble the edited document: \(error.localizedDescription)")
        }
    }

    static func serialize(_ doc: XMLDocument) -> Data {
        if doc.version == nil { doc.version = "1.0" }
        doc.characterEncoding = "UTF-8"
        return doc.xmlData(options: [.nodeCompactEmptyElement])
    }

    static func newXML(_ string: String) throws -> XMLDocument {
        do {
            let doc = try XMLDocument(xmlString: string, options: [.nodePreserveWhitespace])
            doc.isStandalone = true
            return doc
        } catch {
            throw DocumentEditError("Internal error building XML: \(error.localizedDescription)")
        }
    }

    // MARK: - Relationships

    static func relsPath(for part: String) -> String {
        guard !part.isEmpty else { return "_rels/.rels" }
        let url = URL(fileURLWithPath: "/" + part)
        let dir = url.deletingLastPathComponent().path
        let prefix = dir == "/" ? "" : String(dir.dropFirst()) + "/"
        return prefix + "_rels/" + url.lastPathComponent + ".rels"
    }

    /// Resolve a relationship target relative to its source part.
    static func resolve(_ target: String, from part: String) -> String {
        if target.hasPrefix("/") { return String(target.dropFirst()) }
        var components = part.split(separator: "/").map(String.init)
        if !components.isEmpty { components.removeLast() }
        for piece in target.split(separator: "/").map(String.init) {
            switch piece {
            case ".", "": continue
            case "..": if !components.isEmpty { components.removeLast() }
            default: components.append(piece)
            }
        }
        return components.joined(separator: "/")
    }

    /// Target path for `targetPart` written relative to `part`'s folder.
    static func relativeTarget(from part: String, to targetPart: String) -> String {
        var fromDir = part.split(separator: "/").map(String.init)
        if !fromDir.isEmpty { fromDir.removeLast() }
        let to = targetPart.split(separator: "/").map(String.init)
        var common = 0
        while common < fromDir.count, common < to.count - 1, fromDir[common] == to[common] { common += 1 }
        let ups = Array(repeating: "..", count: fromDir.count - common)
        return (ups + to[common...]).joined(separator: "/")
    }

    func relationships(of part: String) throws -> [Relationship] {
        let path = Self.relsPath(for: part)
        guard has(path) else { return [] }
        return try root(path).childElements("Relationship").compactMap { rel in
            guard let id = rel.attr("Id"), let type = rel.attr("Type"), let target = rel.attr("Target") else {
                return nil
            }
            return Relationship(id: id, type: type, target: target, external: rel.attr("TargetMode") == "External")
        }
    }

    /// Absolute part name a relationship id points to.
    func target(of id: String, from part: String) throws -> String? {
        guard let rel = try relationships(of: part).first(where: { $0.id == id }), !rel.external else { return nil }
        return Self.resolve(rel.target, from: part)
    }

    @discardableResult
    func addRelationship(from part: String, type: String, to targetPart: String) throws -> String {
        let path = Self.relsPath(for: part)
        if !has(path) {
            setXML(
                path,
                try Self.newXML(
                    "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
                        + "<Relationships xmlns=\"\(OOXMLNamespace.packageRelationships)\"/>"))
        }
        let rels = try root(path)
        let used = Set(rels.childElements("Relationship").compactMap { $0.attr("Id") })
        var n = used.count + 1
        while used.contains("rId\(n)") { n += 1 }
        let id = "rId\(n)"
        let element = XMLElement(name: "Relationship", uri: OOXMLNamespace.packageRelationships)
        element.setAttr("Id", id)
        element.setAttr("Type", type)
        element.setAttr("Target", Self.relativeTarget(from: part, to: targetPart))
        rels.addChild(element)
        markDirty(path)
        return id
    }

    func removeRelationship(from part: String, id: String) throws {
        let path = Self.relsPath(for: part)
        guard has(path) else { return }
        let rels = try root(path)
        for rel in rels.childElements("Relationship") where rel.attr("Id") == id {
            rel.detach()
        }
        markDirty(path)
    }

    // MARK: - Content types

    func addOverride(_ part: String, contentType: String) throws {
        let types = try root("[Content_Types].xml")
        let name = "/" + part
        for existing in types.childElements("Override") where existing.attr("PartName") == name {
            existing.setAttr("ContentType", contentType)
            markDirty("[Content_Types].xml")
            return
        }
        let element = XMLElement(name: "Override", uri: OOXMLNamespace.contentTypes)
        element.setAttr("PartName", name)
        element.setAttr("ContentType", contentType)
        types.addChild(element)
        markDirty("[Content_Types].xml")
    }

    func removeOverride(_ part: String) throws {
        let types = try root("[Content_Types].xml")
        for existing in types.childElements("Override") where existing.attr("PartName") == "/" + part {
            existing.detach()
        }
        markDirty("[Content_Types].xml")
    }

    func contentType(of part: String) throws -> String? {
        let types = try root("[Content_Types].xml")
        if let override = types.childElements("Override").first(where: { $0.attr("PartName") == "/" + part }) {
            return override.attr("ContentType")
        }
        let ext = (part as NSString).pathExtension.lowercased()
        return types.childElements("Default").first { $0.attr("Extension")?.lowercased() == ext }?
            .attr("ContentType")
    }

    /// Remove a part plus its relationships file and content-type override.
    func removePart(_ part: String) throws {
        remove(part)
        let rels = Self.relsPath(for: part)
        if has(rels) { remove(rels) }
        try removeOverride(part)
    }

    /// The package's main document part (word/document.xml, xl/workbook.xml…).
    func mainPart() throws -> String {
        guard let rel = try relationships(of: "").first(where: { $0.type == OOXMLRelationshipType.officeDocument })
        else {
            throw DocumentEditError("The package has no main document part.")
        }
        return Self.resolve(rel.target, from: "")
    }
}

// MARK: - XML helpers (namespace-prefix agnostic: match on local names)

extension XMLNode {
    var local: String { localName ?? name ?? "" }
}

extension XMLElement {
    func childElements(_ local: String) -> [XMLElement] {
        (children ?? []).compactMap { $0 as? XMLElement }.filter { $0.local == local }
    }

    var elementChildren: [XMLElement] {
        (children ?? []).compactMap { $0 as? XMLElement }
    }

    func firstChild(_ local: String) -> XMLElement? {
        (children ?? []).lazy.compactMap { $0 as? XMLElement }.first { $0.local == local }
    }

    /// Every descendant element named `local`, in document order.
    func descendants(_ local: String) -> [XMLElement] {
        var out: [XMLElement] = []
        func walk(_ element: XMLElement) {
            for child in element.elementChildren {
                if child.local == local { out.append(child) }
                walk(child)
            }
        }
        walk(self)
        return out
    }

    func attr(_ name: String) -> String? {
        if let direct = attribute(forName: name)?.stringValue { return direct }
        let localPart = name.split(separator: ":").last.map(String.init) ?? name
        return attributes?.first { $0.local == localPart }?.stringValue
    }

    func setAttr(_ name: String, _ value: String, uri: String? = nil) {
        if let existing = attribute(forName: name) {
            existing.stringValue = value
            return
        }
        let node: XMLNode
        if let uri {
            node = XMLNode.attribute(withName: name, uri: uri, stringValue: value) as! XMLNode
        } else {
            node = XMLNode.attribute(withName: name, stringValue: value) as! XMLNode
        }
        addAttribute(node)
    }

    func removeAttr(_ name: String) {
        removeAttribute(forName: name)
    }

    /// Qualified name for a new child in `uri`, reusing this element's
    /// prefix for that namespace (so `w:` documents stay `w:`).
    /// Elements built before they're attached can't resolve prefixes
    /// through the tree, so fall back to the nearest same-namespace
    /// element's prefix, then the conventional one. An unprefixed name
    /// here would serialize into no namespace and be ignored by Office.
    func qualified(_ local: String, uri: String) -> String {
        if let prefix = resolvePrefix(forNamespaceURI: uri) {
            return prefix.isEmpty ? local : "\(prefix):\(local)"
        }
        var node: XMLNode? = self
        while let element = node as? XMLElement {
            if element.uri == uri, let prefix = element.prefix {
                return prefix.isEmpty ? local : "\(prefix):\(local)"
            }
            node = element.parent
        }
        if let prefix = Self.conventionalPrefixes[uri] {
            return "\(prefix):\(local)"
        }
        return local
    }

    private static let conventionalPrefixes: [String: String] = [
        OOXMLNamespace.wordprocessing: "w",
        OOXMLNamespace.drawing: "a",
        OOXMLNamespace.presentation: "p",
    ]

    /// `r:id` pointing at a relationship, declaring the relationships
    /// namespace on the part's root when it isn't in scope yet.
    func setRelationshipId(_ rid: String) {
        let uri = OOXMLNamespace.officeRelationships
        var prefix = resolvePrefix(forNamespaceURI: uri) ?? ""
        if prefix.isEmpty {
            prefix = "r"
            let root = rootDocument?.rootElement() ?? self
            root.addNamespace(XMLNode.namespace(withName: prefix, stringValue: uri) as! XMLNode)
        }
        setAttr("\(prefix):id", rid, uri: uri)
    }

    func makeChild(_ local: String, uri: String) -> XMLElement {
        XMLElement(name: qualified(local, uri: uri), uri: uri)
    }

    func deepCopy() -> XMLElement {
        copy() as! XMLElement
    }
}
