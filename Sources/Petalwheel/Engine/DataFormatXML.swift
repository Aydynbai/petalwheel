import Foundation

/// Generic XML ↔ data-tree mapping (the usual "xml2json" convention):
/// - an element becomes an object: attributes as "@name", child elements by name (repeated names become
///   an array), text as "#text"; an element with only text becomes a string, an empty one null;
/// - the document becomes `{ rootName: … }`.
/// Writing reverses it: a single-key object names the root element, anything else is wrapped in `<root>`;
/// arrays repeat their key's element (top-level or nested arrays use `<item>`). Values are kept as text,
/// so numbers read back from XML are strings. Comments, processing instructions and mixed-content order
/// (text between child elements) aren't preserved.
enum DataXML {
    // MARK: Reading

    static func parse(_ data: Data) throws -> DataValue {
        let doc: XMLDocument
        do {
            doc = try XMLDocument(data: data, options: [.nodePreserveCDATA])
        } catch {
            throw NurToError(l: "Couldn't read the XML: %@", error.localizedDescription)
        }
        guard let root = doc.rootElement() else { throw NurToError(l: "The document has no content.") }
        return .object([(root.name ?? "root", element(root))])
    }

    private static func element(_ e: XMLElement) -> DataValue {
        var pairs: [(String, DataValue)] = []
        for attr in e.attributes ?? [] {
            pairs.append(("@" + (attr.name ?? ""), .string(attr.stringValue ?? "")))
        }
        // Namespace declarations show up separately.
        for ns in e.namespaces ?? [] {
            let name = ns.name ?? ""
            pairs.append((name.isEmpty ? "@xmlns" : "@xmlns:" + name, .string(ns.stringValue ?? "")))
        }
        var text = ""
        var childOrder: [String] = []
        var children: [String: [DataValue]] = [:]
        for node in e.children ?? [] {
            switch node.kind {
            case .element:
                guard let child = node as? XMLElement else { continue }
                let name = child.name ?? "item"
                if children[name] == nil { childOrder.append(name) }
                children[name, default: []].append(element(child))
            case .text:
                text += node.stringValue ?? ""
            default:
                continue
            }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if pairs.isEmpty && childOrder.isEmpty {
            return trimmed.isEmpty ? .null : .string(text.contains("\n") ? trimmed : text)
        }
        for name in childOrder {
            let values = children[name] ?? []
            pairs.append((name, values.count == 1 ? values[0] : .array(values)))
        }
        if !trimmed.isEmpty { pairs.append(("#text", .string(trimmed))) }
        return .object(pairs)
    }

    // MARK: Writing

    static func write(_ value: DataValue) -> String {
        var out = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        if case .object(let pairs) = value, pairs.count == 1, !pairs[0].0.hasPrefix("@"), pairs[0].0 != "#text",
           !isArray(pairs[0].1) {
            emit(name: pairs[0].0, value: pairs[0].1, indent: 0, into: &out)
        } else if isArray(value) {
            out += "<root>\n"
            emit(name: "item", value: value, indent: 1, into: &out)
            out += "</root>\n"
        } else {
            emit(name: "root", value: value, indent: 0, into: &out)
        }
        return out
    }

    private static func isArray(_ v: DataValue) -> Bool {
        if case .array = v { return true }
        return false
    }

    /// A valid XML name from an arbitrary key.
    static func elementName(_ key: String) -> String {
        var out = ""
        for (i, u) in key.unicodeScalars.enumerated() {
            let ok = CharacterSet.letters.contains(u) || u == "_" || u == ":" ||
                (i > 0 && (CharacterSet.decimalDigits.contains(u) || u == "-" || u == "."))
            out.unicodeScalars.append(ok ? u : "_")
        }
        if out.isEmpty { return "item" }
        if let f = out.unicodeScalars.first, !(CharacterSet.letters.contains(f) || f == "_") { out = "_" + out }
        return out
    }

    private static func escape(_ s: String, attribute: Bool) -> String {
        var out = ""
        for u in EpubWriter.stripInvalidXMLCharacters(s).unicodeScalars {
            switch u {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"" where attribute: out += "&quot;"
            case "\n" where attribute: out += "&#10;"
            default: out.unicodeScalars.append(u)
            }
        }
        return out
    }

    private static func emit(name rawName: String, value: DataValue, indent: Int, into out: inout String) {
        let pad = String(repeating: "  ", count: indent)
        let name = elementName(rawName)
        switch value {
        case .array(let items):
            // A nested array of arrays can't repeat a name meaningfully: wrap.
            for item in items {
                if case .array = item {
                    out += "\(pad)<\(name)>\n"
                    emit(name: "item", value: item, indent: indent + 1, into: &out)
                    out += "\(pad)</\(name)>\n"
                } else {
                    emit(name: rawName, value: item, indent: indent, into: &out)
                }
            }
        case .object(let pairs):
            var attrs = ""
            var text: String?
            var childPairs: [(String, DataValue)] = []
            for (k, v) in pairs {
                if k.hasPrefix("@") && !v.isContainer {
                    let attrName = k.hasPrefix("@xmlns") ? String(k.dropFirst()) : elementName(String(k.dropFirst()))
                    attrs += " \(attrName)=\"\(escape(v.scalarText, attribute: true))\""
                } else if k == "#text" && !v.isContainer {
                    text = v.scalarText
                } else {
                    childPairs.append((k, v))
                }
            }
            if childPairs.isEmpty {
                if let text, !text.isEmpty {
                    out += "\(pad)<\(name)\(attrs)>\(escape(text, attribute: false))</\(name)>\n"
                } else {
                    out += "\(pad)<\(name)\(attrs)/>\n"
                }
                return
            }
            out += "\(pad)<\(name)\(attrs)>\n"
            if let text, !text.isEmpty { out += "\(pad)  \(escape(text, attribute: false))\n" }
            for (k, v) in childPairs {
                if case .array(let items) = v, items.isEmpty { continue }
                emit(name: k, value: v, indent: indent + 1, into: &out)
            }
            out += "\(pad)</\(name)>\n"
        case .null:
            out += "\(pad)<\(name)/>\n"
        default:
            let t = value.scalarText
            out += t.isEmpty ? "\(pad)<\(name)/>\n" : "\(pad)<\(name)>\(escape(t, attribute: false))</\(name)>\n"
        }
    }
}
