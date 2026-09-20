import Foundation
#if canImport(PDFKit)
import PDFKit
#endif

/// Text pulled out of a file, with the structure worth keeping.
public struct ParsedDocument: Sendable, Equatable {
    /// One entry per page for paginated formats; one entry for everything else.
    public struct Page: Sendable, Equatable {
        public var number: Int?
        public var text: String

        public init(number: Int? = nil, text: String) {
            self.number = number
            self.text = text
        }
    }

    public var title: String?
    public var pages: [Page]
    public var pageCount: Int? { pages.contains { $0.number != nil } ? pages.count : nil }

    public var isEmpty: Bool { pages.allSatisfy { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
}

public enum DocumentParseError: Error, CustomStringConvertible, Equatable {
    case unsupported(String)
    case unreadable(String)
    case empty

    public var description: String {
        switch self {
        case let .unsupported(type): "I can't read \(type) files yet."
        case let .unreadable(reason): "That file couldn't be read: \(reason)"
        case .empty: "That file has no text in it."
        }
    }
}

public protocol DocumentParsing: Sendable {
    func parse(data: Data, fileName: String, mediaType: String?) throws -> ParsedDocument
}

/// Reads the formats a person actually shares with an assistant: PDFs, plain text and Markdown,
/// Word documents, rich text, and web pages.
///
/// Everything is parsed in-process with no network and no third-party code. HTML is stripped by a
/// small deterministic pass rather than by `NSAttributedString`, whose HTML importer runs WebKit on
/// the main thread — the wrong shape for a background import, and far more machinery than reading
/// text out of a page requires.
public struct DocumentParser: DocumentParsing {
    public init() {}

    public func parse(data: Data, fileName: String, mediaType: String? = nil) throws -> ParsedDocument {
        let parsed = try parseByFormat(data: data, fileName: fileName, mediaType: mediaType)
        guard !parsed.isEmpty else { throw DocumentParseError.empty }
        return parsed
    }

    private func parseByFormat(data: Data, fileName: String, mediaType: String?) throws -> ParsedDocument {
        let fallbackTitle = (fileName as NSString).deletingPathExtension
        switch format(fileName: fileName, mediaType: mediaType) {
        case .pdf:
            return try parsePDF(data: data, fallbackTitle: fallbackTitle)
        case .docx:
            let text = try DOCXReader.text(from: data)
            return ParsedDocument(title: fallbackTitle, pages: [.init(text: text)])
        case .rtf:
            #if canImport(AppKit) || canImport(UIKit)
            guard let attributed = try? NSAttributedString(
                data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil
            ) else { throw DocumentParseError.unreadable("rich text") }
            return ParsedDocument(title: fallbackTitle, pages: [.init(text: attributed.string)])
            #else
            throw DocumentParseError.unsupported("rtf")
            #endif
        case .html:
            guard let markup = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
                throw DocumentParseError.unreadable("web page")
            }
            let stripped = HTMLText.extract(markup)
            return ParsedDocument(title: stripped.title ?? fallbackTitle, pages: [.init(text: stripped.text)])
        case .text:
            guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
                throw DocumentParseError.unreadable("text")
            }
            return ParsedDocument(title: Self.markdownTitle(in: text) ?? fallbackTitle, pages: [.init(text: text)])
        case let .unsupported(name):
            throw DocumentParseError.unsupported(name)
        }
    }

    private func parsePDF(data: Data, fallbackTitle: String) throws -> ParsedDocument {
        #if canImport(PDFKit)
        guard let pdf = PDFDocument(data: data) else { throw DocumentParseError.unreadable("PDF") }
        var pages: [ParsedDocument.Page] = []
        for index in 0..<pdf.pageCount {
            let text = pdf.page(at: index)?.string ?? ""
            pages.append(.init(number: index + 1, text: text))
        }
        let title = (pdf.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ParsedDocument(title: title?.isEmpty == false ? title : fallbackTitle, pages: pages)
        #else
        throw DocumentParseError.unsupported("PDF")
        #endif
    }

    // MARK: Format detection

    enum Format: Equatable {
        case pdf, docx, rtf, html, text
        case unsupported(String)
    }

    /// The document's own title: a single `#` heading at the top. A file whose first heading is one
    /// of several is a document with sections, not a document called "Grading", so the file name
    /// wins — the user knows what they shared.
    static func markdownTitle(in text: String) -> String? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let headings = lines.filter { $0.hasPrefix("# ") }
        guard headings.count == 1, let first = lines.first(where: { !$0.isEmpty }), first.hasPrefix("# ") else {
            return nil
        }
        return String(first.dropFirst(2))
    }

    func format(fileName: String, mediaType: String?) -> Format {
        let ext = (fileName as NSString).pathExtension.lowercased()
        switch ext {
        case "pdf": return .pdf
        case "docx": return .docx
        case "rtf", "rtfd": return .rtf
        case "html", "htm", "xhtml": return .html
        case "txt", "md", "markdown", "text", "csv", "json", "log", "swift", "py", "js", "ts": return .text
        case "": break
        default: if mediaType == nil { return .unsupported(ext) }
        }
        switch mediaType {
        case "application/pdf": return .pdf
        case "application/vnd.openxmlformats-officedocument.wordprocessingml.document": return .docx
        case "application/rtf", "text/rtf": return .rtf
        case "text/html", "application/xhtml+xml": return .html
        case let type? where type.hasPrefix("text/"): return .text
        case let type?: return .unsupported(type)
        case nil: return .text
        }
    }
}

// MARK: - HTML

/// Pulls the readable text out of a page without a rendering engine.
enum HTMLText {
    static func extract(_ markup: String) -> (title: String?, text: String) {
        var title: String?
        if let range = markup.range(of: "(?s)<title[^>]*>.*?</title>", options: [.regularExpression, .caseInsensitive]) {
            title = decode(strip(String(markup[range])))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Script and style content is code, not reading matter. `(?s)` makes `.` cross newlines,
        // which `String.replacingOccurrences` has no option for.
        var body = markup
        for pattern in ["(?s)<script[^>]*>.*?</script>", "(?s)<style[^>]*>.*?</style>",
                        "(?s)<!--.*?-->", "(?s)<head[^>]*>.*?</head>"] {
            body = body.replacingOccurrences(
                of: pattern, with: " ", options: [.regularExpression, .caseInsensitive]
            )
        }
        // Block-level tags become line breaks so paragraphs survive.
        body = body.replacingOccurrences(
            of: "</(p|div|section|article|li|tr|h[1-6])>|<br\\s*/?>",
            with: "\n", options: [.regularExpression, .caseInsensitive]
        )
        let text = decode(strip(body))
            .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (title?.isEmpty == false ? title : nil, text)
    }

    private static func strip(_ markup: String) -> String {
        markup.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
    }

    private static let entities: [String: String] = [
        "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'",
        "&nbsp;": " ", "&mdash;": "—", "&ndash;": "–", "&hellip;": "…", "&rsquo;": "'", "&lsquo;": "'",
        "&ldquo;": "\u{201C}", "&rdquo;": "\u{201D}",
    ]

    static func decode(_ text: String) -> String {
        var decoded = text
        for (entity, character) in entities {
            decoded = decoded.replacingOccurrences(of: entity, with: character, options: .caseInsensitive)
        }
        // Numeric references (&#8217;).
        while let range = decoded.range(of: "&#[0-9]{1,6};", options: .regularExpression) {
            let digits = decoded[range].dropFirst(2).dropLast()
            let replacement = UInt32(digits).flatMap(UnicodeScalar.init).map(String.init) ?? " "
            decoded.replaceSubrange(range, with: replacement)
        }
        return decoded
    }
}
