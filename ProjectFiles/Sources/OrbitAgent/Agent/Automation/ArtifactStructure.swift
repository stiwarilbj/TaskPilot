import Foundation

/// Private facts, not a promise that arbitrary document content is correct.
struct ArtifactStructureProof {
    let format: String
    let count: Int
    var fields: [String: Any] {
        ["format": format, "verified": true, "validation_version": 1,
         "scope": "document_structure", "structure_count": count,
         "facts": Self.facts(format)]
    }
    static func facts(_ format: String) -> [String] {
        let profiles = ActionContract.definition["artifact_formats"] as! [String: [String: Any]]
        return profiles[format]?["facts"] as? [String] ?? []
    }
}

final class ArtifactInspectionBudget {
    enum Exhausted: Error { case limit }
    private let clock: () -> TimeInterval
    private let start: TimeInterval
    init(clock: @escaping () -> TimeInterval) { self.clock = clock; start = clock() }
    func check() throws {
        try TaskOwnership.check()
        let elapsed = clock() - start
        guard elapsed.isFinite, elapsed >= 0, elapsed < 2 else { throw Exhausted.limit }
    }
}

/// A deliberately bounded OOXML subset. XML is parsed, not searched for marker
/// text. No entities, network access, extraction, or external resource loading.
final class ArtifactPackage {
    static let packageNS = "http://schemas.openxmlformats.org/package/2006/relationships"
    static let typesNS = "http://schemas.openxmlformats.org/package/2006/content-types"
    static let officeNS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    static let strictOfficeNS = "http://purl.oclc.org/ooxml/officeDocument/relationships"
    static let wordNS = ["http://schemas.openxmlformats.org/wordprocessingml/2006/main", "http://purl.oclc.org/ooxml/wordprocessingml/main"]
    static let sheetNS = ["http://schemas.openxmlformats.org/spreadsheetml/2006/main", "http://purl.oclc.org/ooxml/spreadsheetml/main"]
    let names: Set<String>
    let budget: ArtifactInspectionBudget
    let load: (String) throws -> Data?
    private var parsed: [String: ArtifactXML] = [:]
    private var parsedNodes = 0
    init(names: Set<String>, budget: ArtifactInspectionBudget, load: @escaping (String) throws -> Data?) {
        self.names = names; self.budget = budget; self.load = load
    }
    static func safeMember(_ name: String) -> Bool {
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        return !name.isEmpty && !name.hasPrefix("/") && !name.contains("\\") && !name.contains("\0") &&
        !name.contains("%") && parts.enumerated().allSatisfy {
            ($0.element != "" || $0.offset == parts.count - 1) &&
            $0.element != "." && $0.element != ".."
        }
    }
    private func xml(_ name: String) throws -> ArtifactXML? {
        try budget.check()
        if let cached = parsed[name] { return cached }
        guard let data = try load(name), let tree = try ArtifactXML.parse(data, budget: budget) else { return nil }
        guard parsedNodes + tree.nodes.count <= 50_000 else { return nil }
        parsedNodes += tree.nodes.count
        parsed[name] = tree
        return tree
    }
    private struct Relationship {
        let type: String
        let target: String?
    }
    private func relationships(_ name: String, source: String) throws -> [String: Relationship]? {
        guard let tree = try xml(name), tree.rootIs("Relationships", namespaces: [Self.packageNS]) else { return nil }
        var result: [String: Relationship] = [:]
        for node in tree.children(of: 0) {
            try budget.check()
            guard node.name == "Relationship", node.namespace == Self.packageNS,
                  let id = node.attributes["Id"], !id.isEmpty, result[id] == nil,
                  let type = node.attributes["Type"], let target = node.attributes["Target"], !target.isEmpty else { return nil }
            let mode = node.attributes["TargetMode"] ?? "Internal"
            if mode == "External" {
                // External links are metadata only. They cannot establish a
                // required part or cause any URL to be opened.
                result[id] = Relationship(type: type, target: nil)
            } else {
                guard mode == "Internal", let resolved = Self.resolve(target, from: source),
                      names.contains(resolved), !resolved.hasSuffix("/") else { return nil }
                result[id] = Relationship(type: type, target: resolved)
            }
        }
        return result
    }
    static func resolve(_ value: String, from source: String) -> String? {
        guard !value.contains("\\"), !value.contains("?"), !value.contains("#"),
              !value.contains(":"), !value.contains("\0"), let decoded = value.removingPercentEncoding,
              !decoded.contains("%"), !decoded.contains("\\"), !decoded.contains("\0"),
              !decoded.contains(":"), !decoded.contains("?"), !decoded.contains("#"),
              !decoded.hasPrefix("//"), !value.lowercased().contains("%2f") else { return nil }
        var parts = decoded.hasPrefix("/") ? [] : Array(source.split(separator: "/").dropLast()).map(String.init)
        for part in decoded.split(separator: "/", omittingEmptySubsequences: false) {
            if part.isEmpty || part == "." { continue }
            if part == ".." { guard !parts.isEmpty else { return nil }; parts.removeLast() }
            else { parts.append(String(part)) }
        }
        let name = parts.joined(separator: "/")
        return safeMember(name) ? name : nil
    }
    private func isType(_ type: String, _ suffix: String) -> Bool {
        [Self.officeNS, Self.strictOfficeNS].contains { type == $0 + "/" + suffix }
    }

    func validate(kind: String) throws -> Int? {
        guard let types = try xml("[Content_Types].xml"), types.rootIs("Types", namespaces: [Self.typesNS]),
              let packageRels = try relationships("_rels/.rels", source: "") else { return nil }
        var overrides: [String: String] = [:], defaults: [String: String] = [:]
        for node in types.children(of: 0) {
            guard node.namespace == Self.typesNS, let mime = node.attributes["ContentType"], !mime.isEmpty else { return nil }
            if node.name == "Override" {
                guard let name = node.attributes["PartName"], name.hasPrefix("/"),
                      let resolved = Self.resolve(name, from: ""), names.contains(resolved), overrides[resolved] == nil else { return nil }
                overrides[resolved] = mime
            } else if node.name == "Default" {
                guard let ext = node.attributes["Extension"], !ext.isEmpty, defaults[ext.lowercased()] == nil else { return nil }
                defaults[ext.lowercased()] = mime
            } else { return nil }
        }
        func mime(_ name: String) -> String? { overrides[name] ?? defaults[URL(fileURLWithPath: name).pathExtension.lowercased()] }
        let roots = packageRels.values.filter { isType($0.type, "officeDocument") }
        guard roots.count == 1, let main = roots.first?.target,
              main == (kind == "docx" ? "word/document.xml" : "xl/workbook.xml"),
              mime(main) == (kind == "docx"
                ? "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"
                : "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"),
              let document = try xml(main) else { return nil }

        // Every declared internal package relationship must resolve, including
        // optional document parts. At most 256 relationship files are inspected.
        let relNames = names.filter { $0.hasSuffix(".rels") }.sorted()
        guard relNames.count <= 256 else { return nil }
        var bySource: [String: [String: Relationship]] = [:]
        for relName in relNames where relName != "_rels/.rels" {
            let pieces = relName.split(separator: "/").map(String.init)
            guard pieces.count >= 2, pieces[pieces.count - 2] == "_rels" else { return nil }
            let source = (Array(pieces.dropLast(2)) + [String(pieces.last!.dropLast(5))]).joined(separator: "/")
            guard names.contains(source), let rels = try relationships(relName, source: source) else { return nil }
            bySource[source] = rels
        }
        func referencesResolve(_ tree: ArtifactXML, _ rels: [String: Relationship]) -> Bool {
            tree.nodes.allSatisfy { node in
                node.attributes.allSatisfy { key, value in
                    if key.hasPrefix("{" + Self.officeNS + "}") || key.hasPrefix("{" + Self.strictOfficeNS + "}") {
                        return rels[value] != nil
                    }
                    return true
                }
            }
        }
        guard referencesResolve(document, bySource[main] ?? [:]) else { return nil }
        if kind == "docx" {
            guard document.rootIs("document", namespaces: Self.wordNS),
                  document.children(of: 0).filter({ $0.name == "body" && Self.wordNS.contains($0.namespace) }).count == 1 else { return nil }
            return 1
        }
        guard document.rootIs("workbook", namespaces: Self.sheetNS) else { return nil }
        let containers = document.childIndices(of: 0).filter { document.nodes[$0].name == "sheets" && Self.sheetNS.contains(document.nodes[$0].namespace) }
        guard containers.count == 1 else { return nil }
        let sheets = document.children(of: containers[0])
        guard !sheets.isEmpty, sheets.count <= 256 else { return nil }
        var ids = Set<UInt32>(), labels = Set<String>(), targets = Set<String>(), links = Set<String>()
        for node in sheets {
            try budget.check()
            guard node.name == "sheet", Self.sheetNS.contains(node.namespace),
                  let id = node.attributes["sheetId"], let number = UInt32(id), number > 0, ids.insert(number).inserted,
                  let label = node.attributes["name"], !label.isEmpty, labels.insert(label.lowercased()).inserted,
                  let link = node.attributes["{" + Self.officeNS + "}id"] ?? node.attributes["{" + Self.strictOfficeNS + "}id"],
                  links.insert(link).inserted, let relationship = bySource[main]?[link],
                  let target = relationship.target, targets.insert(target).inserted,
                  isType(relationship.type, "worksheet") || isType(relationship.type, "chartsheet"),
                  let sheet = try xml(target), referencesResolve(sheet, bySource[target] ?? [:]) else { return nil }
            let isWorksheet = isType(relationship.type, "worksheet")
            guard sheet.rootIs(isWorksheet ? "worksheet" : "chartsheet", namespaces: Self.sheetNS),
                  mime(target) == "application/vnd.openxmlformats-officedocument.spreadsheetml.\(isWorksheet ? "worksheet" : "chartsheet")+xml" else { return nil }
            if isWorksheet, sheet.children(of: 0).filter({ $0.name == "sheetData" && Self.sheetNS.contains($0.namespace) }).count != 1 { return nil }
        }
        return sheets.count
    }
}

final class ArtifactXML: NSObject, XMLParserDelegate {
    struct Node {
        let name: String
        let namespace: String
        let attributes: [String: String]
        let parent: Int?
    }
    var nodes: [Node] = []
    private var stack: [Int] = []
    private var children: [Int: [Int]] = [:]
    private var prefixes: [String: [String]] = [:]
    private var invalid = false
    private let budget: ArtifactInspectionBudget
    private var characterCount = 0
    init(budget: ArtifactInspectionBudget) { self.budget = budget }
    static func parse(_ data: Data, budget: ArtifactInspectionBudget) throws -> ArtifactXML? {
        try budget.check()
        guard data.count <= 4 * 1024 * 1024, let text = String(data: data, encoding: .utf8),
              !text.contains("<!DOCTYPE"), !text.contains("<!ENTITY") else { return nil }
        let tree = ArtifactXML(budget: budget), parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = true
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        parser.delegate = tree
        let parsed = parser.parse()
        try budget.check()
        return parsed && !tree.invalid && !tree.nodes.isEmpty && tree.stack.isEmpty ? tree : nil
    }
    func rootIs(_ name: String, namespaces: [String]) -> Bool {
        nodes.first.map { $0.name == name && namespaces.contains($0.namespace) } ?? false
    }
    func childIndices(of node: Int) -> [Int] { children[node] ?? [] }
    func children(of node: Int) -> [Node] { childIndices(of: node).map { nodes[$0] } }
    private func check(_ parser: XMLParser) -> Bool {
        do { try budget.check(); return true }
        catch { invalid = true; parser.abortParsing(); return false }
    }
    func parser(_ parser: XMLParser, didStartMappingPrefix prefix: String, toURI namespaceURI: String) { prefixes[prefix, default: []].append(namespaceURI) }
    func parser(_ parser: XMLParser, didEndMappingPrefix prefix: String) { _ = prefixes[prefix]?.popLast() }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        guard check(parser), nodes.count < 50_000, stack.count < 64, attributes.count <= 64 else { invalid = true; parser.abortParsing(); return }
        var resolved: [String: String] = [:]
        for (key, value) in attributes {
            let parts = key.split(separator: ":", maxSplits: 1)
            let field: String
            if parts.count == 2, let ns = prefixes[String(parts[0])]?.last { field = "{\(ns)}\(parts[1])" }
            else { field = key }
            if resolved[field] != nil { invalid = true; parser.abortParsing(); return }
            resolved[field] = value
        }
        let index = nodes.count
        if let parent = stack.last { children[parent, default: []].append(index) }
        else if !nodes.isEmpty { invalid = true; parser.abortParsing(); return }
        nodes.append(Node(name: name, namespace: namespaceURI ?? "", attributes: resolved, parent: stack.last))
        stack.append(index)
    }
    func parser(_ parser: XMLParser, didEndElement: String, namespaceURI: String?, qualifiedName: String?) { _ = stack.popLast() }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        characterCount += string.utf8.count
        if !check(parser) || characterCount > 4 * 1024 * 1024 { invalid = true; parser.abortParsing() }
    }
}
