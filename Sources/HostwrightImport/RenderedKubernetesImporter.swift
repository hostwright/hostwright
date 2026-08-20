import Foundation
import HostwrightManifest

public enum RenderedKubernetesDiagnosticCode: String, Equatable, Sendable {
    case inputTooLarge
    case documentTooLarge
    case tooManyDocuments
    case tooManyLines
    case lineTooLong
    case emptyDocument
    case unsupportedYAMLFeature
    case invalidIndentation
    case malformedMapping
    case duplicateKey
    case depthExceeded
    case nodeLimitExceeded
    case scalarTooLarge
    case missingField
    case unsupportedField
    case unsupportedAPIVersion
    case unsupportedKind
    case invalidValue
    case duplicateObject
}

public struct RenderedKubernetesDiagnostic: Equatable, Sendable {
    public let code: RenderedKubernetesDiagnosticCode
    public let documentIndex: Int
    public let line: Int
    public let path: String
    public let message: String

    public init(
        code: RenderedKubernetesDiagnosticCode,
        documentIndex: Int,
        line: Int,
        path: String,
        message: String
    ) {
        self.code = code
        self.documentIndex = documentIndex
        self.line = line
        self.path = path
        self.message = message
    }

    public var rendered: String {
        "\(code.rawValue): document \(documentIndex), line \(line), path \(path): \(message)"
    }
}

public enum RenderedKubernetesObjectKind: String, Equatable, Sendable {
    case pod = "Pod"
    case deployment = "Deployment"
    case service = "Service"
}

public struct RenderedKubernetesKeyValueSummary: Equatable, Sendable {
    public let key: String
    public let value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

public struct RenderedKubernetesContainerSummary: Equatable, Sendable {
    public let name: String
    public let image: String

    public init(name: String, image: String) {
        self.name = name
        self.image = image
    }
}

public struct RenderedKubernetesServicePortSummary: Equatable, Sendable {
    public let name: String?
    public let port: Int
    public let targetPort: Int
    public let protocolName: String

    public init(name: String?, port: Int, targetPort: Int, protocolName: String) {
        self.name = name
        self.port = port
        self.targetPort = targetPort
        self.protocolName = protocolName
    }
}

public struct RenderedKubernetesObjectSummary: Equatable, Sendable {
    public let documentIndex: Int
    public let apiVersion: String
    public let kind: RenderedKubernetesObjectKind
    public let name: String
    public let namespace: String
    public let labels: [RenderedKubernetesKeyValueSummary]
    public let containers: [RenderedKubernetesContainerSummary]
    public let replicas: Int?
    public let selector: [RenderedKubernetesKeyValueSummary]
    public let servicePorts: [RenderedKubernetesServicePortSummary]

    public init(
        documentIndex: Int,
        apiVersion: String,
        kind: RenderedKubernetesObjectKind,
        name: String,
        namespace: String,
        labels: [RenderedKubernetesKeyValueSummary],
        containers: [RenderedKubernetesContainerSummary],
        replicas: Int?,
        selector: [RenderedKubernetesKeyValueSummary],
        servicePorts: [RenderedKubernetesServicePortSummary]
    ) {
        self.documentIndex = documentIndex
        self.apiVersion = apiVersion
        self.kind = kind
        self.name = name
        self.namespace = namespace
        self.labels = labels
        self.containers = containers
        self.replicas = replicas
        self.selector = selector
        self.servicePorts = servicePorts
    }
}

public struct RenderedKubernetesImportResult: Equatable, Sendable {
    public let objects: [RenderedKubernetesObjectSummary]
    public let diagnostics: [RenderedKubernetesDiagnostic]

    public init(
        objects: [RenderedKubernetesObjectSummary],
        diagnostics: [RenderedKubernetesDiagnostic]
    ) {
        self.objects = objects
        self.diagnostics = diagnostics
    }

    public var succeeded: Bool {
        diagnostics.isEmpty
    }
}

public enum RenderedKubernetesImporter {
    public static let maximumInputBytes = 1_048_576
    public static let maximumDocumentBytes = 262_144
    public static let maximumDocuments = 64
    public static let maximumLinesPerDocument = 4_096
    public static let maximumLineBytes = 8_192
    public static let maximumDepth = 12
    public static let maximumNodesPerDocument = 4_096
    public static let maximumScalarBytes = 4_096

    private static let limitation = "Rendered Kubernetes import accepts only the documented offline restricted YAML subset."

    public static func scan(_ text: String) -> RenderedKubernetesImportResult {
        guard text.utf8.count <= maximumInputBytes else {
            return failed(
                code: .inputTooLarge,
                documentIndex: 1,
                line: 1,
                path: "$",
                message: "Input exceeds the \(maximumInputBytes)-byte stream limit."
            )
        }

        let split = splitDocuments(text)
        if let diagnostic = split.diagnostic {
            return RenderedKubernetesImportResult(objects: [], diagnostics: [diagnostic])
        }

        var accepted: [ValidatedObject] = []
        var diagnostics: [RenderedKubernetesDiagnostic] = []

        for (zeroBasedIndex, document) in split.documents.enumerated() {
            let documentIndex = zeroBasedIndex + 1
            let byteCount = document.lines.reduce(into: 0) { total, sourceLine in
                total += sourceLine.originalByteCount + 1
            }
            if byteCount > maximumDocumentBytes {
                diagnostics.append(
                    diagnostic(
                        code: .documentTooLarge,
                        documentIndex: documentIndex,
                        line: document.startLine,
                        path: "$",
                        message: "Document exceeds the \(maximumDocumentBytes)-byte limit."
                    )
                )
                continue
            }
            if document.lines.count > maximumLinesPerDocument {
                diagnostics.append(
                    diagnostic(
                        code: .tooManyLines,
                        documentIndex: documentIndex,
                        line: document.startLine,
                        path: "$",
                        message: "Document exceeds the \(maximumLinesPerDocument)-line limit."
                    )
                )
                continue
            }

            do {
                var parser = RestrictedBlockYAMLParser(
                    sourceLines: document.lines,
                    documentIndex: documentIndex,
                    fallbackLine: document.startLine
                )
                let root = try parser.parse()
                let validated = try KubernetesSummaryValidator(
                    documentIndex: documentIndex,
                    fallbackLine: document.startLine
                ).validate(root)
                accepted.append(validated)
            } catch let failure as RenderedKubernetesParseFailure {
                diagnostics.append(failure.diagnostic)
            } catch {
                diagnostics.append(
                    diagnostic(
                        code: .invalidValue,
                        documentIndex: documentIndex,
                        line: document.startLine,
                        path: "$",
                        message: "Document could not be classified within the restricted subset."
                    )
                )
            }
        }

        if diagnostics.isEmpty {
            var identities: [String: ValidatedObject] = [:]
            for object in accepted {
                let summary = object.summary
                let identity = "\(summary.kind.rawValue)|\(summary.namespace)|\(summary.name)"
                if identities[identity] != nil {
                    diagnostics.append(
                        diagnostic(
                            code: .duplicateObject,
                            documentIndex: summary.documentIndex,
                            line: object.nameLine,
                            path: "$.metadata.name",
                            message: "Object identity '\(summary.kind.rawValue)/\(summary.namespace)/\(summary.name)' is duplicated in the stream."
                        )
                    )
                } else {
                    identities[identity] = object
                }
            }
        }

        diagnostics.sort(by: diagnosticOrder)
        guard diagnostics.isEmpty else {
            return RenderedKubernetesImportResult(objects: [], diagnostics: diagnostics)
        }
        return RenderedKubernetesImportResult(
            objects: accepted.map(\.summary),
            diagnostics: []
        )
    }

    private static func splitDocuments(_ text: String) -> DocumentSplitResult {
        let rawLines = text.components(separatedBy: "\n")
        var documents: [RenderedDocument] = []
        var current: [RenderedSourceLine] = []
        var currentStartLine = 1
        var streamStartedByMarker = false

        for (zeroBasedIndex, rawLine) in rawLines.enumerated() {
            let lineNumber = zeroBasedIndex + 1
            let normalized = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            let uncommented = stripInlineComment(normalized)
            let marker = uncommented.trimmingCharacters(in: .whitespaces)
            let isTopLevelMarker = !normalized.contains("\t") &&
                uncommented.first == "-" &&
                marker == "---"

            if isTopLevelMarker {
                let hasMeaningfulPreamble = containsMeaningfulContent(current)
                if streamStartedByMarker || hasMeaningfulPreamble {
                    documents.append(RenderedDocument(lines: current, startLine: currentStartLine))
                }
                streamStartedByMarker = true
                current = []
                currentStartLine = lineNumber + 1
                if documents.count >= maximumDocuments {
                    return DocumentSplitResult(
                        documents: [],
                        diagnostic: diagnostic(
                            code: .tooManyDocuments,
                            documentIndex: maximumDocuments + 1,
                            line: lineNumber,
                            path: "$",
                            message: "Stream exceeds the \(maximumDocuments)-document limit."
                        )
                    )
                }
                continue
            }
            current.append(
                RenderedSourceLine(
                    text: normalized,
                    number: lineNumber,
                    originalByteCount: rawLine.utf8.count
                )
            )
        }

        documents.append(RenderedDocument(lines: current, startLine: currentStartLine))
        if documents.count > maximumDocuments {
            return DocumentSplitResult(
                documents: [],
                diagnostic: diagnostic(
                    code: .tooManyDocuments,
                    documentIndex: maximumDocuments + 1,
                    line: currentStartLine,
                    path: "$",
                    message: "Stream exceeds the \(maximumDocuments)-document limit."
                )
            )
        }
        return DocumentSplitResult(documents: documents, diagnostic: nil)
    }

    private static func containsMeaningfulContent(_ lines: [RenderedSourceLine]) -> Bool {
        lines.contains { sourceLine in
            !stripInlineComment(sourceLine.text).trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    fileprivate static func stripInlineComment(_ line: String) -> String {
        var inSingleQuote = false
        var inDoubleQuote = false
        var escapingDoubleQuote = false
        var previous: Character?
        var index = line.startIndex

        while index < line.endIndex {
            let character = line[index]
            if inDoubleQuote {
                if escapingDoubleQuote {
                    escapingDoubleQuote = false
                } else if character == "\\" {
                    escapingDoubleQuote = true
                } else if character == "\"" {
                    inDoubleQuote = false
                }
            } else if inSingleQuote {
                if character == "'" {
                    let next = line.index(after: index)
                    if next < line.endIndex, line[next] == "'" {
                        index = next
                    } else {
                        inSingleQuote = false
                    }
                }
            } else if character == "\"" {
                inDoubleQuote = true
            } else if character == "'" {
                inSingleQuote = true
            } else if character == "#", previous == nil || previous?.isWhitespace == true {
                return String(line[..<index])
            }
            previous = character
            index = line.index(after: index)
        }
        return line
    }

    fileprivate static func diagnostic(
        code: RenderedKubernetesDiagnosticCode,
        documentIndex: Int,
        line: Int,
        path: String,
        message: String
    ) -> RenderedKubernetesDiagnostic {
        RenderedKubernetesDiagnostic(
            code: code,
            documentIndex: documentIndex,
            line: max(1, line),
            path: path,
            message: "\(message) \(limitation)"
        )
    }

    private static func failed(
        code: RenderedKubernetesDiagnosticCode,
        documentIndex: Int,
        line: Int,
        path: String,
        message: String
    ) -> RenderedKubernetesImportResult {
        RenderedKubernetesImportResult(
            objects: [],
            diagnostics: [
                diagnostic(
                    code: code,
                    documentIndex: documentIndex,
                    line: line,
                    path: path,
                    message: message
                )
            ]
        )
    }

    private static func diagnosticOrder(
        _ lhs: RenderedKubernetesDiagnostic,
        _ rhs: RenderedKubernetesDiagnostic
    ) -> Bool {
        if lhs.documentIndex != rhs.documentIndex {
            return lhs.documentIndex < rhs.documentIndex
        }
        if lhs.line != rhs.line {
            return lhs.line < rhs.line
        }
        if lhs.path != rhs.path {
            return lhs.path < rhs.path
        }
        return lhs.code.rawValue < rhs.code.rawValue
    }
}

private struct RenderedSourceLine {
    let text: String
    let number: Int
    let originalByteCount: Int
}

private struct RenderedDocument {
    let lines: [RenderedSourceLine]
    let startLine: Int
}

private struct DocumentSplitResult {
    let documents: [RenderedDocument]
    let diagnostic: RenderedKubernetesDiagnostic?
}

private struct RenderedKubernetesParseFailure: Error {
    let diagnostic: RenderedKubernetesDiagnostic
}

private indirect enum RestrictedYAMLNode {
    case scalar(value: String, line: Int)
    case mapping(entries: [RestrictedYAMLEntry], line: Int)
    case sequence(items: [RestrictedYAMLNode], line: Int)

    var line: Int {
        switch self {
        case let .scalar(_, line), let .mapping(_, line), let .sequence(_, line):
            return line
        }
    }
}

private struct RestrictedYAMLEntry {
    let key: String
    let keyLine: Int
    let value: RestrictedYAMLNode
}

private struct ParsedYAMLLine {
    let indent: Int
    let content: String
    let number: Int
}

private struct RestrictedBlockYAMLParser {
    private let sourceLines: [RenderedSourceLine]
    private let documentIndex: Int
    private let fallbackLine: Int
    private var lines: [ParsedYAMLLine] = []
    private var cursor = 0
    private var nodeCount = 0

    init(sourceLines: [RenderedSourceLine], documentIndex: Int, fallbackLine: Int) {
        self.sourceLines = sourceLines
        self.documentIndex = documentIndex
        self.fallbackLine = fallbackLine
    }

    mutating func parse() throws -> RestrictedYAMLNode {
        lines = try preprocess(sourceLines)
        guard let first = lines.first else {
            throw failure(
                .emptyDocument,
                line: fallbackLine,
                path: "$",
                "Document has no Kubernetes object."
            )
        }
        guard first.indent == 0 else {
            throw failure(
                .invalidIndentation,
                line: first.number,
                path: "$",
                "The root mapping must start at indentation zero."
            )
        }
        let root = try parseBlock(indent: 0, path: "$", depth: 1)
        if cursor != lines.count {
            let line = lines[cursor]
            throw failure(
                .invalidIndentation,
                line: line.number,
                path: "$",
                "Indentation does not belong to the preceding mapping or sequence."
            )
        }
        return root
    }

    private mutating func preprocess(_ source: [RenderedSourceLine]) throws -> [ParsedYAMLLine] {
        var parsed: [ParsedYAMLLine] = []
        for sourceLine in source {
            if sourceLine.originalByteCount > RenderedKubernetesImporter.maximumLineBytes {
                throw failure(
                    .lineTooLong,
                    line: sourceLine.number,
                    path: "$",
                    "Line exceeds the \(RenderedKubernetesImporter.maximumLineBytes)-byte limit."
                )
            }
            if sourceLine.text.contains("\t") || sourceLine.text.unicodeScalars.contains(where: { $0.value < 32 }) {
                throw failure(
                    .unsupportedYAMLFeature,
                    line: sourceLine.number,
                    path: "$",
                    "Tabs and control characters are not accepted."
                )
            }

            let uncommented = RenderedKubernetesImporter.stripInlineComment(sourceLine.text)
            let content = uncommented.trimmingCharacters(in: .whitespaces)
            guard !content.isEmpty else { continue }
            let indent = uncommented.prefix { $0 == " " }.count
            if indent % 2 != 0 {
                throw failure(
                    .invalidIndentation,
                    line: sourceLine.number,
                    path: "$",
                    "Only two-space indentation levels are accepted."
                )
            }
            if content == "..." || content == "---" {
                throw failure(
                    .unsupportedYAMLFeature,
                    line: sourceLine.number,
                    path: "$",
                    "Aliases, anchors, merge keys, tags, flow collections, and multiline scalars are not accepted."
                )
            }
            parsed.append(ParsedYAMLLine(indent: indent, content: content, number: sourceLine.number))
        }
        return parsed
    }

    private mutating func parseBlock(indent: Int, path: String, depth: Int) throws -> RestrictedYAMLNode {
        guard depth <= RenderedKubernetesImporter.maximumDepth else {
            let line = cursor < lines.count ? lines[cursor].number : fallbackLine
            throw failure(
                .depthExceeded,
                line: line,
                path: path,
                "Nesting exceeds \(RenderedKubernetesImporter.maximumDepth) levels."
            )
        }
        guard cursor < lines.count else {
            throw failure(.missingField, line: fallbackLine, path: path, "A nested value is required.")
        }
        let first = lines[cursor]
        guard first.indent == indent else {
            throw failure(
                .invalidIndentation,
                line: first.number,
                path: path,
                "Expected indentation \(indent), found \(first.indent)."
            )
        }
        if isSequenceLine(first.content) {
            return try parseSequence(indent: indent, path: path, depth: depth)
        }
        return try parseMapping(indent: indent, path: path, depth: depth)
    }

    private mutating func parseMapping(indent: Int, path: String, depth: Int) throws -> RestrictedYAMLNode {
        let startLine = lines[cursor].number
        var entries: [RestrictedYAMLEntry] = []
        var seen: Set<String> = []

        while cursor < lines.count {
            let line = lines[cursor]
            if line.indent < indent { break }
            if line.indent > indent {
                throw failure(
                    .invalidIndentation,
                    line: line.number,
                    path: path,
                    "Unexpected indentation without a parent field."
                )
            }
            if isSequenceLine(line.content) { break }
            let parsed = try parseMappingEntry(
                line: line,
                mappingIndent: indent,
                path: path,
                depth: depth,
                seen: &seen
            )
            entries.append(parsed)
        }

        try recordNode(line: startLine, path: path)
        return .mapping(entries: entries, line: startLine)
    }

    private mutating func parseSequence(indent: Int, path: String, depth: Int) throws -> RestrictedYAMLNode {
        let startLine = lines[cursor].number
        var items: [RestrictedYAMLNode] = []

        while cursor < lines.count {
            let line = lines[cursor]
            if line.indent < indent { break }
            if line.indent > indent {
                throw failure(
                    .invalidIndentation,
                    line: line.number,
                    path: path,
                    "Unexpected indentation inside sequence."
                )
            }
            guard isSequenceLine(line.content) else { break }
            let itemPath = "\(path)[\(items.count)]"
            let remainder = line.content == "-" ? "" : String(line.content.dropFirst(2))
            cursor += 1

            if remainder.isEmpty {
                guard cursor < lines.count, lines[cursor].indent == indent + 2 else {
                    throw failure(.missingField, line: line.number, path: itemPath, "Sequence item requires a value.")
                }
                items.append(try parseBlock(indent: indent + 2, path: itemPath, depth: depth + 1))
                continue
            }

            if let pair = splitKeyValue(remainder) {
                items.append(
                    try parseInlineMappingSequenceItem(
                        firstPair: pair,
                        sourceLine: line.number,
                        sequenceIndent: indent,
                        path: itemPath,
                        depth: depth + 1
                    )
                )
            } else {
                if cursor < lines.count, lines[cursor].indent > indent {
                    throw failure(
                        .invalidIndentation,
                        line: lines[cursor].number,
                        path: itemPath,
                        "Scalar sequence items cannot own nested values."
                    )
                }
                items.append(try scalarNode(remainder, line: line.number, path: itemPath))
            }
        }

        try recordNode(line: startLine, path: path)
        return .sequence(items: items, line: startLine)
    }

    private mutating func parseInlineMappingSequenceItem(
        firstPair: (key: String, value: String),
        sourceLine: Int,
        sequenceIndent: Int,
        path: String,
        depth: Int
    ) throws -> RestrictedYAMLNode {
        guard depth <= RenderedKubernetesImporter.maximumDepth else {
            throw failure(
                .depthExceeded,
                line: sourceLine,
                path: path,
                "Nesting exceeds \(RenderedKubernetesImporter.maximumDepth) levels."
            )
        }
        let mappingIndent = sequenceIndent + 2
        var entries: [RestrictedYAMLEntry] = []
        var seen: Set<String> = []
        if firstPair.key == "<<" {
            throw failure(
                .unsupportedYAMLFeature,
                line: sourceLine,
                path: "\(path).<<",
                "YAML merge keys are not accepted."
            )
        }
        try validateKey(firstPair.key, line: sourceLine, path: path)
        seen.insert(firstPair.key)
        let firstPath = "\(path).\(firstPair.key)"
        let firstValue: RestrictedYAMLNode
        if firstPair.value.isEmpty {
            guard cursor < lines.count, lines[cursor].indent == mappingIndent + 2 else {
                throw failure(.missingField, line: sourceLine, path: firstPath, "Field requires a nested value.")
            }
            firstValue = try parseBlock(indent: mappingIndent + 2, path: firstPath, depth: depth + 1)
        } else {
            firstValue = try scalarNode(firstPair.value, line: sourceLine, path: firstPath)
        }
        entries.append(RestrictedYAMLEntry(key: firstPair.key, keyLine: sourceLine, value: firstValue))

        while cursor < lines.count {
            let line = lines[cursor]
            if line.indent <= sequenceIndent { break }
            if line.indent != mappingIndent || isSequenceLine(line.content) {
                throw failure(
                    .invalidIndentation,
                    line: line.number,
                    path: path,
                    "Sequence mapping fields must align two spaces after '-'."
                )
            }
            entries.append(
                try parseMappingEntry(
                    line: line,
                    mappingIndent: mappingIndent,
                    path: path,
                    depth: depth,
                    seen: &seen
                )
            )
        }

        try recordNode(line: sourceLine, path: path)
        return .mapping(entries: entries, line: sourceLine)
    }

    private mutating func parseMappingEntry(
        line: ParsedYAMLLine,
        mappingIndent: Int,
        path: String,
        depth: Int,
        seen: inout Set<String>
    ) throws -> RestrictedYAMLEntry {
        guard let pair = splitKeyValue(line.content) else {
            throw failure(
                .malformedMapping,
                line: line.number,
                path: path,
                "Mapping entries must use an unquoted key followed by ':'."
            )
        }
        if pair.key == "<<" {
            throw failure(
                .unsupportedYAMLFeature,
                line: line.number,
                path: "\(path).<<",
                "YAML merge keys are not accepted."
            )
        }
        try validateKey(pair.key, line: line.number, path: path)
        let entryPath = "\(path).\(pair.key)"
        guard seen.insert(pair.key).inserted else {
            throw failure(.duplicateKey, line: line.number, path: entryPath, "Mapping key '\(pair.key)' is duplicated.")
        }
        cursor += 1

        let node: RestrictedYAMLNode
        if pair.value.isEmpty {
            guard cursor < lines.count, lines[cursor].indent == mappingIndent + 2 else {
                throw failure(.missingField, line: line.number, path: entryPath, "Field requires a nested value.")
            }
            node = try parseBlock(indent: mappingIndent + 2, path: entryPath, depth: depth + 1)
        } else {
            if cursor < lines.count, lines[cursor].indent > mappingIndent {
                throw failure(
                    .invalidIndentation,
                    line: lines[cursor].number,
                    path: entryPath,
                    "Scalar field cannot own nested values."
                )
            }
            node = try scalarNode(pair.value, line: line.number, path: entryPath)
        }
        return RestrictedYAMLEntry(key: pair.key, keyLine: line.number, value: node)
    }

    private mutating func scalarNode(_ raw: String, line: Int, path: String) throws -> RestrictedYAMLNode {
        if containsUnquotedFlowIndicator(raw) {
            throw failure(
                .unsupportedYAMLFeature,
                line: line,
                path: path,
                "Flow collections are not accepted."
            )
        }
        let parsed = RestrictedYAMLSubsetParser.parseScalar(
            raw,
            lineNumber: line,
            subject: path,
            limitation: "Rendered Kubernetes import is restricted."
        )
        if let issue = parsed.issues.first {
            throw failure(.unsupportedYAMLFeature, line: issue.line, path: path, issue.message)
        }
        guard let value = parsed.value else {
            throw failure(.invalidValue, line: line, path: path, "Scalar could not be decoded.")
        }
        guard value.utf8.count <= RenderedKubernetesImporter.maximumScalarBytes else {
            throw failure(
                .scalarTooLarge,
                line: line,
                path: path,
                "Scalar exceeds the \(RenderedKubernetesImporter.maximumScalarBytes)-byte limit."
            )
        }
        try recordNode(line: line, path: path)
        return .scalar(value: value, line: line)
    }

    private mutating func recordNode(line: Int, path: String) throws {
        nodeCount += 1
        if nodeCount > RenderedKubernetesImporter.maximumNodesPerDocument {
            throw failure(
                .nodeLimitExceeded,
                line: line,
                path: path,
                "Document exceeds the \(RenderedKubernetesImporter.maximumNodesPerDocument)-node limit."
            )
        }
    }

    private func validateKey(_ key: String, line: Int, path: String) throws {
        guard !key.isEmpty,
              key.utf8.count <= 253,
              key.unicodeScalars.allSatisfy({ scalar in
                  switch scalar.value {
                  case 45, 46, 47, 48...57, 65...90, 95, 97...122:
                      return true
                  default:
                      return false
                  }
              }) else {
            throw failure(
                .malformedMapping,
                line: line,
                path: path,
                "Mapping keys must be bounded unquoted ASCII identifiers."
            )
        }
    }

    private func failure(
        _ code: RenderedKubernetesDiagnosticCode,
        line: Int,
        path: String,
        _ message: String
    ) -> RenderedKubernetesParseFailure {
        RenderedKubernetesParseFailure(
            diagnostic: RenderedKubernetesImporter.diagnostic(
                code: code,
                documentIndex: documentIndex,
                line: line,
                path: path,
                message: message
            )
        )
    }

    private func isSequenceLine(_ content: String) -> Bool {
        content == "-" || content.hasPrefix("- ")
    }

    private func splitKeyValue(_ content: String) -> (key: String, value: String)? {
        var inSingleQuote = false
        var inDoubleQuote = false
        var escapingDoubleQuote = false
        var index = content.startIndex

        while index < content.endIndex {
            let character = content[index]
            if inDoubleQuote {
                if escapingDoubleQuote {
                    escapingDoubleQuote = false
                } else if character == "\\" {
                    escapingDoubleQuote = true
                } else if character == "\"" {
                    inDoubleQuote = false
                }
            } else if inSingleQuote {
                if character == "'" {
                    let next = content.index(after: index)
                    if next < content.endIndex, content[next] == "'" {
                        index = next
                    } else {
                        inSingleQuote = false
                    }
                }
            } else if character == "\"" {
                inDoubleQuote = true
            } else if character == "'" {
                inSingleQuote = true
            } else if character == ":" {
                let afterColon = content.index(after: index)
                guard afterColon == content.endIndex || content[afterColon].isWhitespace else {
                    index = afterColon
                    continue
                }
                let key = String(content[..<index]).trimmingCharacters(in: .whitespaces)
                let value = String(content[afterColon...]).trimmingCharacters(in: .whitespaces)
                return (key, value)
            }
            index = content.index(after: index)
        }
        return nil
    }

    private func containsUnquotedFlowIndicator(_ content: String) -> Bool {
        var inSingleQuote = false
        var inDoubleQuote = false
        var escapingDoubleQuote = false
        var index = content.startIndex

        while index < content.endIndex {
            let character = content[index]
            if inDoubleQuote {
                if escapingDoubleQuote {
                    escapingDoubleQuote = false
                } else if character == "\\" {
                    escapingDoubleQuote = true
                } else if character == "\"" {
                    inDoubleQuote = false
                }
            } else if inSingleQuote {
                if character == "'" {
                    let next = content.index(after: index)
                    if next < content.endIndex, content[next] == "'" {
                        index = next
                    } else {
                        inSingleQuote = false
                    }
                }
            } else if character == "\"" {
                inDoubleQuote = true
            } else if character == "'" {
                inSingleQuote = true
            } else if character == "[" || character == "]" {
                return true
            }
            index = content.index(after: index)
        }
        return false
    }
}

private struct ValidatedObject {
    let summary: RenderedKubernetesObjectSummary
    let nameLine: Int
}

private struct KubernetesSummaryValidator {
    private let documentIndex: Int
    private let fallbackLine: Int

    init(documentIndex: Int, fallbackLine: Int) {
        self.documentIndex = documentIndex
        self.fallbackLine = fallbackLine
    }

    func validate(_ root: RestrictedYAMLNode) throws -> ValidatedObject {
        let rootEntries = try mapping(root, path: "$")
        try rejectUnsupportedFields(
            rootEntries,
            allowed: ["apiVersion", "kind", "metadata", "spec"],
            path: "$"
        )
        let (apiVersion, apiVersionLine) = try requiredScalar(rootEntries, key: "apiVersion", path: "$")
        let (rawKind, kindLine) = try requiredScalar(rootEntries, key: "kind", path: "$")
        guard let kind = RenderedKubernetesObjectKind(rawValue: rawKind) else {
            throw failure(
                .unsupportedKind,
                line: kindLine,
                path: "$.kind",
                "Kind '\(rawKind)' is unsupported; accepted kinds are Pod, Deployment, and Service."
            )
        }
        let expectedAPIVersion = kind == .deployment ? "apps/v1" : "v1"
        guard apiVersion == expectedAPIVersion else {
            throw failure(
                .unsupportedAPIVersion,
                line: apiVersionLine,
                path: "$.apiVersion",
                "Kind \(kind.rawValue) requires apiVersion '\(expectedAPIVersion)'."
            )
        }

        let metadataEntry = try requiredEntry(rootEntries, key: "metadata", path: "$", line: root.line)
        let metadata = try validateMetadata(metadataEntry.value)
        let specEntry = try requiredEntry(rootEntries, key: "spec", path: "$", line: root.line)

        switch kind {
        case .pod:
            let pod = try validatePodSpec(specEntry.value)
            return ValidatedObject(
                summary: RenderedKubernetesObjectSummary(
                    documentIndex: documentIndex,
                    apiVersion: apiVersion,
                    kind: kind,
                    name: metadata.name,
                    namespace: metadata.namespace,
                    labels: metadata.labels,
                    containers: pod.containers,
                    replicas: nil,
                    selector: [],
                    servicePorts: []
                ),
                nameLine: metadata.nameLine
            )
        case .deployment:
            let deployment = try validateDeploymentSpec(specEntry.value)
            return ValidatedObject(
                summary: RenderedKubernetesObjectSummary(
                    documentIndex: documentIndex,
                    apiVersion: apiVersion,
                    kind: kind,
                    name: metadata.name,
                    namespace: metadata.namespace,
                    labels: metadata.labels,
                    containers: deployment.containers,
                    replicas: deployment.replicas,
                    selector: deployment.selector,
                    servicePorts: []
                ),
                nameLine: metadata.nameLine
            )
        case .service:
            let service = try validateServiceSpec(specEntry.value)
            return ValidatedObject(
                summary: RenderedKubernetesObjectSummary(
                    documentIndex: documentIndex,
                    apiVersion: apiVersion,
                    kind: kind,
                    name: metadata.name,
                    namespace: metadata.namespace,
                    labels: metadata.labels,
                    containers: [],
                    replicas: nil,
                    selector: service.selector,
                    servicePorts: service.ports
                ),
                nameLine: metadata.nameLine
            )
        }
    }

    private func validateMetadata(_ node: RestrictedYAMLNode) throws -> MetadataSummary {
        let entries = try mapping(node, path: "$.metadata")
        try rejectUnsupportedFields(entries, allowed: ["name", "namespace", "labels"], path: "$.metadata")
        let (name, nameLine) = try requiredScalar(entries, key: "name", path: "$.metadata")
        try validateDNSSubdomain(name, line: nameLine, path: "$.metadata.name", maximumBytes: 253)

        let namespace: String
        if let entry = entry(entries, key: "namespace") {
            namespace = try scalar(entry.value, path: "$.metadata.namespace").value
            try validateDNSLabel(namespace, line: entry.value.line, path: "$.metadata.namespace")
        } else {
            namespace = "default"
        }

        let labels: [RenderedKubernetesKeyValueSummary]
        if let labelEntry = entry(entries, key: "labels") {
            labels = try validateStringMap(labelEntry.value, path: "$.metadata.labels", requireNonEmpty: false)
        } else {
            labels = []
        }
        return MetadataSummary(name: name, namespace: namespace, labels: labels, nameLine: nameLine)
    }

    private func validatePodSpec(_ node: RestrictedYAMLNode) throws -> PodSummary {
        let entries = try mapping(node, path: "$.spec")
        try rejectUnsupportedFields(entries, allowed: ["containers", "restartPolicy"], path: "$.spec")
        let containerEntry = try requiredEntry(entries, key: "containers", path: "$.spec", line: node.line)
        let containers = try validateContainers(containerEntry.value, path: "$.spec.containers")
        if let restartEntry = entry(entries, key: "restartPolicy") {
            let restart = try scalar(restartEntry.value, path: "$.spec.restartPolicy")
            guard ["Always", "Never", "OnFailure"].contains(restart.value) else {
                throw failure(
                    .invalidValue,
                    line: restart.line,
                    path: "$.spec.restartPolicy",
                    "restartPolicy must be Always, Never, or OnFailure."
                )
            }
        }
        return PodSummary(containers: containers)
    }

    private func validateDeploymentSpec(_ node: RestrictedYAMLNode) throws -> DeploymentSummary {
        let entries = try mapping(node, path: "$.spec")
        try rejectUnsupportedFields(entries, allowed: ["replicas", "selector", "template"], path: "$.spec")
        let replicas: Int
        if let replicasEntry = entry(entries, key: "replicas") {
            replicas = try boundedInteger(
                replicasEntry.value,
                path: "$.spec.replicas",
                range: 0...1_000
            )
        } else {
            replicas = 1
        }

        let selectorEntry = try requiredEntry(entries, key: "selector", path: "$.spec", line: node.line)
        let selectorEntries = try mapping(selectorEntry.value, path: "$.spec.selector")
        try rejectUnsupportedFields(selectorEntries, allowed: ["matchLabels"], path: "$.spec.selector")
        let matchLabelsEntry = try requiredEntry(
            selectorEntries,
            key: "matchLabels",
            path: "$.spec.selector",
            line: selectorEntry.value.line
        )
        let selector = try validateStringMap(
            matchLabelsEntry.value,
            path: "$.spec.selector.matchLabels",
            requireNonEmpty: true
        )

        let templateEntry = try requiredEntry(entries, key: "template", path: "$.spec", line: node.line)
        let templateEntries = try mapping(templateEntry.value, path: "$.spec.template")
        try rejectUnsupportedFields(templateEntries, allowed: ["metadata", "spec"], path: "$.spec.template")
        let templateMetadataEntry = try requiredEntry(
            templateEntries,
            key: "metadata",
            path: "$.spec.template",
            line: templateEntry.value.line
        )
        let templateMetadata = try mapping(templateMetadataEntry.value, path: "$.spec.template.metadata")
        try rejectUnsupportedFields(templateMetadata, allowed: ["labels"], path: "$.spec.template.metadata")
        let templateLabelsEntry = try requiredEntry(
            templateMetadata,
            key: "labels",
            path: "$.spec.template.metadata",
            line: templateMetadataEntry.value.line
        )
        let templateLabels = try validateStringMap(
            templateLabelsEntry.value,
            path: "$.spec.template.metadata.labels",
            requireNonEmpty: true
        )
        let templateLabelEntries = try mapping(
            templateLabelsEntry.value,
            path: "$.spec.template.metadata.labels"
        )
        let templateDictionary = Dictionary(uniqueKeysWithValues: templateLabels.map { ($0.key, $0.value) })
        for required in selector where templateDictionary[required.key] != required.value {
            let mismatchLine = entry(templateLabelEntries, key: required.key)?.value.line ??
                templateLabelsEntry.value.line
            throw failure(
                .invalidValue,
                line: mismatchLine,
                path: "$.spec.template.metadata.labels.\(required.key)",
                "Deployment selector labels must match template labels."
            )
        }

        let templateSpecEntry = try requiredEntry(
            templateEntries,
            key: "spec",
            path: "$.spec.template",
            line: templateEntry.value.line
        )
        let pod = try validatePodSpecAtTemplate(templateSpecEntry.value)
        return DeploymentSummary(replicas: replicas, selector: selector, containers: pod.containers)
    }

    private func validatePodSpecAtTemplate(_ node: RestrictedYAMLNode) throws -> PodSummary {
        let path = "$.spec.template.spec"
        let entries = try mapping(node, path: path)
        try rejectUnsupportedFields(entries, allowed: ["containers", "restartPolicy"], path: path)
        let containerEntry = try requiredEntry(entries, key: "containers", path: path, line: node.line)
        let containers = try validateContainers(containerEntry.value, path: "\(path).containers")
        if let restartEntry = entry(entries, key: "restartPolicy") {
            let restart = try scalar(restartEntry.value, path: "\(path).restartPolicy")
            guard restart.value == "Always" else {
                throw failure(
                    .invalidValue,
                    line: restart.line,
                    path: "\(path).restartPolicy",
                    "Deployment template restartPolicy must be Always."
                )
            }
        }
        return PodSummary(containers: containers)
    }

    private func validateContainers(
        _ node: RestrictedYAMLNode,
        path: String
    ) throws -> [RenderedKubernetesContainerSummary] {
        let items = try sequence(node, path: path)
        guard !items.isEmpty, items.count <= 64 else {
            throw failure(
                .invalidValue,
                line: node.line,
                path: path,
                "containers must contain between 1 and 64 entries."
            )
        }
        var names: Set<String> = []
        return try items.enumerated().map { index, item in
            let itemPath = "\(path)[\(index)]"
            let entries = try mapping(item, path: itemPath)
            try rejectUnsupportedFields(entries, allowed: ["name", "image"], path: itemPath)
            let (name, nameLine) = try requiredScalar(entries, key: "name", path: itemPath)
            try validateDNSLabel(name, line: nameLine, path: "\(itemPath).name")
            guard names.insert(name).inserted else {
                throw failure(
                    .invalidValue,
                    line: nameLine,
                    path: "\(itemPath).name",
                    "Container name '\(name)' is duplicated."
                )
            }
            let (image, imageLine) = try requiredScalar(entries, key: "image", path: itemPath)
            guard isRestrictedImageReference(image) else {
                throw failure(
                    .invalidValue,
                    line: imageLine,
                    path: "\(itemPath).image",
                    "Container image must be a restricted ASCII image reference of at most 1024 bytes."
                )
            }
            return RenderedKubernetesContainerSummary(name: name, image: image)
        }
    }

    private func validateServiceSpec(_ node: RestrictedYAMLNode) throws -> ServiceSummary {
        let entries = try mapping(node, path: "$.spec")
        try rejectUnsupportedFields(entries, allowed: ["selector", "ports", "type"], path: "$.spec")
        let selectorEntry = try requiredEntry(entries, key: "selector", path: "$.spec", line: node.line)
        let selector = try validateStringMap(selectorEntry.value, path: "$.spec.selector", requireNonEmpty: true)
        if let typeEntry = entry(entries, key: "type") {
            let type = try scalar(typeEntry.value, path: "$.spec.type")
            guard type.value == "ClusterIP" else {
                throw failure(
                    .invalidValue,
                    line: type.line,
                    path: "$.spec.type",
                    "Only ClusterIP Service objects are accepted by this offline subset."
                )
            }
        }

        let portsEntry = try requiredEntry(entries, key: "ports", path: "$.spec", line: node.line)
        let portNodes = try sequence(portsEntry.value, path: "$.spec.ports")
        guard !portNodes.isEmpty, portNodes.count <= 64 else {
            throw failure(
                .invalidValue,
                line: portsEntry.value.line,
                path: "$.spec.ports",
                "ports must contain between 1 and 64 entries."
            )
        }
        var names: Set<String> = []
        var tuples: Set<String> = []
        let ports = try portNodes.enumerated().map { index, portNode in
            let path = "$.spec.ports[\(index)]"
            let fields = try mapping(portNode, path: path)
            try rejectUnsupportedFields(fields, allowed: ["name", "port", "targetPort", "protocol"], path: path)
            let portEntry = try requiredEntry(fields, key: "port", path: path, line: portNode.line)
            let port = try boundedInteger(portEntry.value, path: "\(path).port", range: 1...65_535)
            let targetPort: Int
            if let targetEntry = entry(fields, key: "targetPort") {
                targetPort = try boundedInteger(targetEntry.value, path: "\(path).targetPort", range: 1...65_535)
            } else {
                targetPort = port
            }
            let protocolName: String
            if let protocolEntry = entry(fields, key: "protocol") {
                let parsed = try scalar(protocolEntry.value, path: "\(path).protocol")
                guard parsed.value == "TCP" || parsed.value == "UDP" else {
                    throw failure(
                        .invalidValue,
                        line: parsed.line,
                        path: "\(path).protocol",
                        "Service port protocol must be TCP or UDP."
                    )
                }
                protocolName = parsed.value
            } else {
                protocolName = "TCP"
            }
            let name: String?
            if let nameEntry = entry(fields, key: "name") {
                let parsed = try scalar(nameEntry.value, path: "\(path).name")
                try validateDNSLabel(parsed.value, line: parsed.line, path: "\(path).name")
                guard names.insert(parsed.value).inserted else {
                    throw failure(
                        .invalidValue,
                        line: parsed.line,
                        path: "\(path).name",
                        "Service port name '\(parsed.value)' is duplicated."
                    )
                }
                name = parsed.value
            } else {
                name = nil
            }
            if portNodes.count > 1, name == nil {
                throw failure(
                    .missingField,
                    line: portNode.line,
                    path: "\(path).name",
                    "Service port name is required when a Service exposes multiple ports."
                )
            }
            let tuple = "\(port)|\(protocolName)"
            guard tuples.insert(tuple).inserted else {
                throw failure(
                    .invalidValue,
                    line: portEntry.value.line,
                    path: "\(path).port",
                    "Service port/protocol tuple is duplicated."
                )
            }
            return RenderedKubernetesServicePortSummary(
                name: name,
                port: port,
                targetPort: targetPort,
                protocolName: protocolName
            )
        }
        return ServiceSummary(selector: selector, ports: ports)
    }

    private func validateStringMap(
        _ node: RestrictedYAMLNode,
        path: String,
        requireNonEmpty: Bool
    ) throws -> [RenderedKubernetesKeyValueSummary] {
        let entries = try mapping(node, path: path)
        if requireNonEmpty, entries.isEmpty {
            throw failure(.invalidValue, line: node.line, path: path, "Mapping must not be empty.")
        }
        guard entries.count <= 128 else {
            throw failure(.invalidValue, line: node.line, path: path, "Mapping exceeds 128 entries.")
        }
        var result: [RenderedKubernetesKeyValueSummary] = []
        for entry in entries {
            try validateLabelKey(entry.key, line: entry.keyLine, path: "\(path).\(entry.key)")
            let parsed = try scalar(entry.value, path: "\(path).\(entry.key)")
            try validateLabelValue(parsed.value, line: parsed.line, path: "\(path).\(entry.key)")
            result.append(RenderedKubernetesKeyValueSummary(key: entry.key, value: parsed.value))
        }
        return result.sorted { lhs, rhs in lhs.key < rhs.key }
    }

    private func rejectUnsupportedFields(
        _ entries: [RestrictedYAMLEntry],
        allowed: Set<String>,
        path: String
    ) throws {
        if let unsupported = entries.first(where: { !allowed.contains($0.key) }) {
            throw failure(
                .unsupportedField,
                line: unsupported.keyLine,
                path: "\(path).\(unsupported.key)",
                "Field '\(unsupported.key)' is unsupported in this object position."
            )
        }
    }

    private func requiredEntry(
        _ entries: [RestrictedYAMLEntry],
        key: String,
        path: String,
        line: Int
    ) throws -> RestrictedYAMLEntry {
        guard let found = entry(entries, key: key) else {
            throw failure(.missingField, line: line, path: "\(path).\(key)", "Required field '\(key)' is missing.")
        }
        return found
    }

    private func requiredScalar(
        _ entries: [RestrictedYAMLEntry],
        key: String,
        path: String
    ) throws -> (value: String, line: Int) {
        let found = try requiredEntry(
            entries,
            key: key,
            path: path,
            line: entries.first?.keyLine ?? fallbackLine
        )
        return try scalar(found.value, path: "\(path).\(key)")
    }

    private func entry(_ entries: [RestrictedYAMLEntry], key: String) -> RestrictedYAMLEntry? {
        entries.first { $0.key == key }
    }

    private func mapping(
        _ node: RestrictedYAMLNode,
        path: String
    ) throws -> [RestrictedYAMLEntry] {
        guard case let .mapping(entries, _) = node else {
            throw failure(.invalidValue, line: node.line, path: path, "Expected a mapping.")
        }
        return entries
    }

    private func sequence(
        _ node: RestrictedYAMLNode,
        path: String
    ) throws -> [RestrictedYAMLNode] {
        guard case let .sequence(items, _) = node else {
            throw failure(.invalidValue, line: node.line, path: path, "Expected a block sequence.")
        }
        return items
    }

    private func scalar(
        _ node: RestrictedYAMLNode,
        path: String
    ) throws -> (value: String, line: Int) {
        guard case let .scalar(value, line) = node else {
            throw failure(.invalidValue, line: node.line, path: path, "Expected a scalar.")
        }
        return (value, line)
    }

    private func boundedInteger(
        _ node: RestrictedYAMLNode,
        path: String,
        range: ClosedRange<Int>
    ) throws -> Int {
        let parsed = try scalar(node, path: path)
        guard let value = Int(parsed.value),
              String(value) == parsed.value,
              range.contains(value) else {
            throw failure(
                .invalidValue,
                line: parsed.line,
                path: path,
                "Expected a canonical integer in \(range.lowerBound)...\(range.upperBound)."
            )
        }
        return value
    }

    private func validateDNSLabel(_ value: String, line: Int, path: String) throws {
        guard value.utf8.count <= 63, isDNSComponent(value) else {
            throw failure(
                .invalidValue,
                line: line,
                path: path,
                "Value must be a lowercase DNS label of at most 63 bytes."
            )
        }
    }

    private func validateDNSSubdomain(
        _ value: String,
        line: Int,
        path: String,
        maximumBytes: Int
    ) throws {
        let components = value.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard !value.isEmpty,
              value.utf8.count <= maximumBytes,
              components.allSatisfy({ $0.utf8.count <= 63 && isDNSComponent($0) }) else {
            throw failure(
                .invalidValue,
                line: line,
                path: path,
                "Value must be a lowercase DNS subdomain of at most \(maximumBytes) bytes."
            )
        }
    }

    private func isDNSComponent(_ value: String) -> Bool {
        guard let first = value.utf8.first, let last = value.utf8.last,
              isLowercaseAlphaNumeric(first), isLowercaseAlphaNumeric(last) else {
            return false
        }
        return value.utf8.allSatisfy { byte in
            isLowercaseAlphaNumeric(byte) || byte == 45
        }
    }

    private func isLowercaseAlphaNumeric(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (97...122).contains(byte)
    }

    private func validateLabelKey(_ value: String, line: Int, path: String) throws {
        let slashParts = value.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !value.isEmpty, value.utf8.count <= 253, slashParts.count <= 2 else {
            throw failure(.invalidValue, line: line, path: path, "Label key is invalid or exceeds 253 bytes.")
        }
        let name = slashParts.last ?? ""
        guard isLabelToken(name, allowEmpty: false, maximumBytes: 63) else {
            throw failure(.invalidValue, line: line, path: path, "Label key name is invalid.")
        }
        if slashParts.count == 2 {
            do {
                try validateDNSSubdomain(slashParts[0], line: line, path: path, maximumBytes: 253)
            } catch {
                throw failure(.invalidValue, line: line, path: path, "Label key prefix must be a DNS subdomain.")
            }
        }
    }

    private func validateLabelValue(_ value: String, line: Int, path: String) throws {
        guard isLabelToken(value, allowEmpty: true, maximumBytes: 63) else {
            throw failure(.invalidValue, line: line, path: path, "Label value is invalid or exceeds 63 bytes.")
        }
    }

    private func isLabelToken(_ value: String, allowEmpty: Bool, maximumBytes: Int) -> Bool {
        if value.isEmpty { return allowEmpty }
        guard value.utf8.count <= maximumBytes,
              let first = value.utf8.first,
              let last = value.utf8.last,
              isASCIIAlphaNumeric(first),
              isASCIIAlphaNumeric(last) else {
            return false
        }
        return value.utf8.allSatisfy { byte in
            isASCIIAlphaNumeric(byte) || byte == 45 || byte == 46 || byte == 95
        }
    }

    private func isASCIIAlphaNumeric(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
    }

    private func isRestrictedImageReference(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.utf8.count <= 1_024,
              let first = value.utf8.first,
              let last = value.utf8.last,
              isASCIIAlphaNumeric(first),
              isASCIIAlphaNumeric(last) else {
            return false
        }
        return value.utf8.allSatisfy { byte in
            isASCIIAlphaNumeric(byte) ||
                byte == 43 ||
                byte == 45 ||
                byte == 46 ||
                byte == 47 ||
                byte == 58 ||
                byte == 64 ||
                byte == 95
        }
    }

    private func failure(
        _ code: RenderedKubernetesDiagnosticCode,
        line: Int,
        path: String,
        _ message: String
    ) -> RenderedKubernetesParseFailure {
        RenderedKubernetesParseFailure(
            diagnostic: RenderedKubernetesImporter.diagnostic(
                code: code,
                documentIndex: documentIndex,
                line: line,
                path: path,
                message: message
            )
        )
    }
}

private struct MetadataSummary {
    let name: String
    let namespace: String
    let labels: [RenderedKubernetesKeyValueSummary]
    let nameLine: Int
}

private struct PodSummary {
    let containers: [RenderedKubernetesContainerSummary]
}

private struct DeploymentSummary {
    let replicas: Int
    let selector: [RenderedKubernetesKeyValueSummary]
    let containers: [RenderedKubernetesContainerSummary]
}

private struct ServiceSummary {
    let selector: [RenderedKubernetesKeyValueSummary]
    let ports: [RenderedKubernetesServicePortSummary]
}
