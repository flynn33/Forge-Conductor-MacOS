import Foundation
import CoreGraphics

/// Reads a complete, flat tagged-text subset. Missing reverse maps are tolerated
/// only for that forward-linked shape; this is not PDF tagging or glyph validation.
enum NativePDFTextReader {
    struct Limits {
        var maximumInputBytes = 64 * 1_024 * 1_024
        var maximumPages = 256
        var maximumElements = 16_384
        var maximumEncodedStringBytes = 131_072
        var maximumDecodedStringBytes = 65_536
        var maximumTotalTextBytes = 8 * 1_024 * 1_024
        var maximumOperators = 1_000_000
        var maximumArrayItems = 32_768

        fileprivate var valid: Bool {
            maximumInputBytes >= 0 && maximumPages > 0 && maximumElements >= 0
                && maximumEncodedStringBytes >= 0 && maximumDecodedStringBytes >= 0
                && maximumTotalTextBytes >= 0 && maximumOperators >= 0
                && maximumArrayItems >= 0
        }
    }

    static func pages(
        in data: Data,
        limits: Limits = Limits(),
        cancellationCheck: (() throws -> Void)? = nil
    ) throws -> [String]? {
        try cancellationCheck?()
        guard !Thread.isMainThread, limits.valid, data.count <= limits.maximumInputBytes,
              let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider), !document.isEncrypted,
              document.isUnlocked, document.numberOfPages > 0,
              document.numberOfPages <= limits.maximumPages else { return nil }
        // Native parsing calls are synchronous; quotas/checks do not preempt them.
        return try withExtendedLifetime((provider, document)) {
            try Reader(document: document, limits: limits, cancellationCheck: cancellationCheck).read()
        }
    }

    private struct Binding: Hashable {
        let page: Int
        let mcid: Int
    }

    private struct Span {
        let binding: Binding
        let text: CGPDFStringRef
    }

    private final class Budget {
        let limits: Limits
        let cancellationCheck: (() throws -> Void)?
        var operators = 0
        var arrayItems = 0
        var decodedBytes = 0

        init(limits: Limits, cancellationCheck: (() throws -> Void)?) {
            self.limits = limits
            self.cancellationCheck = cancellationCheck
        }

        func array(_ count: Int) -> Bool {
            guard count >= 0, count <= limits.maximumArrayItems - arrayItems else { return false }
            arrayItems += count
            return true
        }

        func decode(_ value: CGPDFStringRef) throws -> String? {
            try cancellationCheck?()
            let length = CGPDFStringGetLength(value)
            guard length <= limits.maximumEncodedStringBytes else { return nil }
            if length >= 2 {
                guard let bytes = CGPDFStringGetBytePtr(value) else { return nil }
                if bytes[0] == 0xFE && bytes[1] == 0xFF {
                    guard length % 2 == 0 else { return nil }
                    var index = 2
                    while index < length {
                        try cancellationCheck?()
                        let unit = UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1])
                        index += 2
                        if (0xD800...0xDBFF).contains(unit) {
                            guard index + 1 < length else { return nil }
                            let next = UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1])
                            guard (0xDC00...0xDFFF).contains(next) else { return nil }
                            index += 2
                        } else if (0xDC00...0xDFFF).contains(unit) { return nil }
                    }
                }
            }
            guard let decoded = CGPDFStringCopyTextString(value) else { return nil }
            let text = decoded as String
            let count = text.utf8.count
            guard count > 0, count <= limits.maximumDecodedStringBytes,
                  count <= limits.maximumTotalTextBytes - decodedBytes else { return nil }
            decodedBytes += count
            return text
        }
    }

    private final class Reader {
        let document: CGPDFDocument
        let budget: Budget

        init(document: CGPDFDocument, limits: Limits, cancellationCheck: (() throws -> Void)?) {
            self.document = document
            budget = Budget(limits: limits, cancellationCheck: cancellationCheck)
        }

        func read() throws -> [String]? {
            try budget.cancellationCheck?()
            guard let catalog = document.catalog,
                  let catalogFields = Self.fieldNames(catalog),
                  let root = Self.dictionary(Self.object(catalog, "StructTreeRoot")),
                  Self.keys(root, allowed: ["Type", "K", "ParentTree", "ParentTreeNextKey", "IDTree"]),
                  Self.named(root, "Type", "StructTreeRoot"),
                  let parent = Self.dictionary(Self.object(root, "K")), parent != root,
                  Self.keys(parent, allowed: ["Type", "S", "P", "K"]),
                  Self.named(parent, "Type", "StructElem"), Self.named(parent, "S", "Document"),
                  Self.dictionary(Self.object(parent, "P")) == root,
                  let children = Self.array(Self.object(parent, "K")) else { return nil }
            if catalogFields.contains("AcroForm") {
                guard let form = Self.object(catalog, "AcroForm"),
                      CGPDFObjectGetType(form) == .null else { return nil }
            }
            if let nextKey = Self.object(root, "ParentTreeNextKey") {
                guard let value = Self.integer(nextKey), value >= 0 else { return nil }
            }
            // Element IDs/IDTree are outside this subset; the observed legacy writer
            // supplies an unresolved/null IDTree without IDs on its spans.
            if let idTree = Self.object(root, "IDTree"), CGPDFObjectGetType(idTree) != .null { return nil }
            let count = CGPDFArrayGetCount(children)
            guard count > 0, budget.limits.maximumElements >= 2,
                  count <= budget.limits.maximumElements - 2, budget.array(count) else { return nil }

            var pages: [CGPDFPage] = []
            var pageIndex: [CGPDFDictionaryRef: Int] = [:]
            for number in 1...document.numberOfPages {
                try budget.cancellationCheck?()
                guard let page = document.page(at: number), let dictionary = page.dictionary,
                      let fields = Self.fieldNames(dictionary),
                      pageIndex.updateValue(number - 1, forKey: dictionary) == nil else { return nil }
                if fields.contains("Annots") {
                    guard let annotations = Self.object(dictionary, "Annots") else { return nil }
                    if CGPDFObjectGetType(annotations) != .null {
                        guard let array = Self.array(annotations), CGPDFArrayGetCount(array) == 0 else { return nil }
                    }
                }
                pages.append(page)
            }
            var spans: [Span] = []
            var spanIdentities: Set<CGPDFDictionaryRef> = [root, parent]
            var bindings: [Binding: CGPDFDictionaryRef] = [:]
            var lastPage = 0
            for index in 0..<count {
                try budget.cancellationCheck?()
                var child: CGPDFObjectRef?
                guard CGPDFArrayGetObject(children, index, &child),
                      let span = Self.dictionary(child), spanIdentities.insert(span).inserted,
                      Self.keys(span, allowed: ["Type", "S", "P", "Pg", "K", "ActualText"]),
                      Self.named(span, "Type", "StructElem"), Self.named(span, "S", "Span"),
                      Self.dictionary(Self.object(span, "P")) == parent,
                      let pageDictionary = Self.dictionary(Self.object(span, "Pg")),
                      let page = pageIndex[pageDictionary], page >= lastPage,
                      let mcid = Self.integer(Self.object(span, "K")), mcid >= 0,
                      let text = Self.string(Self.object(span, "ActualText")),
                      CGPDFStringGetLength(text) > 0,
                      CGPDFStringGetLength(text) <= budget.limits.maximumEncodedStringBytes else { return nil }
                let binding = Binding(page: page, mcid: mcid)
                guard bindings.updateValue(span, forKey: binding) == nil else { return nil }
                spans.append(Span(binding: binding, text: text))
                lastPage = page
            }
            guard try reverseMap(root: root, pages: pages, bindings: bindings) else { return nil }
            guard let table = Self.operatorTable() else { return nil }
            defer { CGPDFOperatorTableRelease(table) }
            for (index, page) in pages.enumerated() {
                try budget.cancellationCheck?()
                let known = Set(bindings.keys.filter { $0.page == index }.map(\.mcid))
                let state = Scan(budget: budget, known: known)
                let stream = CGPDFContentStreamCreateWithPage(page)
                defer { CGPDFContentStreamRelease(stream) }
                let scanner = CGPDFScannerCreate(stream, table, Unmanaged.passUnretained(state).toOpaque())
                defer { CGPDFScannerRelease(scanner) }
                let scanned = withExtendedLifetime(state) { CGPDFScannerScan(scanner) }
                if let error = state.error { throw error }
                try budget.cancellationCheck?()
                guard scanned, !state.unsupported, state.scopes.isEmpty, !state.inText,
                      state.seen == known, state.nonemptyShows == known else { return nil }
            }

            // Shape and coverage are complete before any structure string is decoded.
            var text = [String](repeating: "", count: pages.count)
            for span in spans {
                try budget.cancellationCheck?()
                guard let value = try budget.decode(span.text) else { return nil }
                text[span.binding.page].append(value)
            }
            try budget.cancellationCheck?()
            return text
        }

        private func reverseMap(
            root: CGPDFDictionaryRef,
            pages: [CGPDFPage],
            bindings: [Binding: CGPDFDictionaryRef]
        ) throws -> Bool {
            var pageKeys: [Int: Int] = [:]
            for (page, value) in pages.enumerated() {
                try budget.cancellationCheck?()
                guard let dictionary = value.dictionary,
                      let names = Self.fieldNames(dictionary),
                      !names.contains("StructParent") else { return false }
                if names.contains("StructParents") {
                    guard let key = Self.integer(Self.object(dictionary, "StructParents")), key >= 0,
                          pageKeys.updateValue(page, forKey: key) == nil else { return false }
                }
            }
            let object = Self.object(root, "ParentTree")
            guard let object, CGPDFObjectGetType(object) != .null else { return pageKeys.isEmpty }
            guard let tree = Self.dictionary(object), Self.keys(tree, allowed: ["Nums", "Limits"]),
                  let fields = Self.fieldNames(tree),
                  let nums = Self.array(Self.object(tree, "Nums")) else { return false }
            let count = CGPDFArrayGetCount(nums)
            guard count % 2 == 0, count / 2 == pageKeys.count, budget.array(count) else { return false }
            var mapped: Set<Binding> = []
            var previous = -1
            var first: Int?
            for index in stride(from: 0, to: count, by: 2) {
                try budget.cancellationCheck?()
                var keyObject: CGPDFObjectRef?, arrayObject: CGPDFObjectRef?
                guard CGPDFArrayGetObject(nums, index, &keyObject),
                      let key = Self.integer(keyObject), key >= 0, key > previous,
                      let page = pageKeys[key], CGPDFArrayGetObject(nums, index + 1, &arrayObject),
                      let array = Self.array(arrayObject) else { return false }
                let length = CGPDFArrayGetCount(array)
                guard budget.array(length) else { return false }
                first = first ?? key
                previous = key
                for mcid in 0..<length {
                    try budget.cancellationCheck?()
                    var entry: CGPDFObjectRef?
                    guard CGPDFArrayGetObject(array, mcid, &entry), let entry else { return false }
                    let binding = Binding(page: page, mcid: mcid)
                    if CGPDFObjectGetType(entry) == .null {
                        guard bindings[binding] == nil else { return false }
                    } else {
                        guard let expected = bindings[binding], Self.dictionary(entry) == expected,
                              mapped.insert(binding).inserted else { return false }
                    }
                }
            }
            if fields.contains("Limits") {
                guard let rangeObject = Self.object(tree, "Limits"),
                      let range = Self.array(rangeObject), CGPDFArrayGetCount(range) == 2,
                      budget.array(2), let first else { return false }
                var lower: CGPDFObjectRef?, upper: CGPDFObjectRef?
                guard CGPDFArrayGetObject(range, 0, &lower), CGPDFArrayGetObject(range, 1, &upper),
                      Self.integer(lower) == first, Self.integer(upper) == previous else { return false }
            }
            if let nextKey = Self.object(root, "ParentTreeNextKey") {
                guard let value = Self.integer(nextKey), value > previous else { return false }
            }
            return mapped == Set(bindings.keys)
        }

        fileprivate static func object(_ dictionary: CGPDFDictionaryRef, _ key: String) -> CGPDFObjectRef? {
            var value: CGPDFObjectRef?
            return key.withCString { CGPDFDictionaryGetObject(dictionary, $0, &value) } ? value : nil
        }

        fileprivate static func dictionary(_ object: CGPDFObjectRef?) -> CGPDFDictionaryRef? {
            guard let object else { return nil }
            var value: CGPDFDictionaryRef?
            return CGPDFObjectGetValue(object, .dictionary, &value) ? value : nil
        }

        fileprivate static func array(_ object: CGPDFObjectRef?) -> CGPDFArrayRef? {
            guard let object else { return nil }
            var value: CGPDFArrayRef?
            return CGPDFObjectGetValue(object, .array, &value) ? value : nil
        }

        fileprivate static func string(_ object: CGPDFObjectRef?) -> CGPDFStringRef? {
            guard let object else { return nil }
            var value: CGPDFStringRef?
            return CGPDFObjectGetValue(object, .string, &value) ? value : nil
        }

        fileprivate static func integer(_ object: CGPDFObjectRef?) -> Int? {
            guard let object else { return nil }
            var value = CGPDFInteger(0)
            return CGPDFObjectGetValue(object, .integer, &value) ? value : nil
        }

        fileprivate static func name(_ pointer: UnsafePointer<CChar>?) -> String? {
            guard let pointer else { return nil }
            var bytes: [UInt8] = []
            for index in 0...127 {
                if pointer[index] == 0 { return String(bytes: bytes, encoding: .utf8) }
                if index < 127 { bytes.append(UInt8(bitPattern: pointer[index])) }
            }
            return nil
        }

        private static func named(_ dictionary: CGPDFDictionaryRef, _ key: String, _ expected: String) -> Bool {
            var value: UnsafePointer<CChar>?
            return key.withCString { CGPDFDictionaryGetName(dictionary, $0, &value) }
                && name(value) == expected
        }

        fileprivate static func keys(_ dictionary: CGPDFDictionaryRef, allowed: Set<String>) -> Bool {
            guard CGPDFDictionaryGetCount(dictionary) <= allowed.count else { return false }
            var valid = true
            CGPDFDictionaryApplyBlock(dictionary, { key, _, _ in
                guard let value = name(key), allowed.contains(value) else { valid = false; return false }
                return true
            }, nil)
            return valid
        }

        private static func fieldNames(_ dictionary: CGPDFDictionaryRef) -> Set<String>? {
            let count = CGPDFDictionaryGetCount(dictionary)
            guard count <= 64 else { return nil }
            var names: Set<String> = []
            var valid = true
            CGPDFDictionaryApplyBlock(dictionary, { key, _, _ in
                guard let value = name(key), names.insert(value).inserted else {
                    valid = false
                    return false
                }
                return true
            }, nil)
            // Unresolvable entries can disappear from typed lookup/enumeration.
            guard valid, names.count == count else { return nil }
            return names
        }

        private static func operatorTable() -> CGPDFOperatorTableRef? {
            guard let table = CGPDFOperatorTableCreate() else { return nil }
            let standard = "b B b* B* c cm CS cs d d0 d1 EI EX f F f* G g gs h i j J K k l m M n q Q re RG rg ri s S SC sc SCN scn sh T* Tc Td TD Tf TL Tm Tr Ts Tw Tz v w W W* y"
            for name in standard.split(separator: " ") {
                String(name).withCString { CGPDFOperatorTableSetCallback(table, $0) { scanner, info in
                    Scan.owner(info).generic(scanner)
                } }
            }
            for name in ["Do", "BI", "BX", "MP", "DP"] {
                name.withCString { CGPDFOperatorTableSetCallback(table, $0) { scanner, info in
                    let state = Scan.owner(info)
                    if state.step(scanner) { state.reject(scanner) }
                } }
            }
            CGPDFOperatorTableSetCallback(table, "BT") { scanner, info in Scan.owner(info).textBoundary(scanner, begin: true) }
            CGPDFOperatorTableSetCallback(table, "ET") { scanner, info in Scan.owner(info).textBoundary(scanner, begin: false) }
            CGPDFOperatorTableSetCallback(table, "BMC") { scanner, info in Scan.owner(info).begin(scanner, properties: false) }
            CGPDFOperatorTableSetCallback(table, "BDC") { scanner, info in Scan.owner(info).begin(scanner, properties: true) }
            CGPDFOperatorTableSetCallback(table, "EMC") { scanner, info in Scan.owner(info).end(scanner) }
            CGPDFOperatorTableSetCallback(table, "Tj") { scanner, info in Scan.owner(info).show(scanner, array: false, spacing: false) }
            CGPDFOperatorTableSetCallback(table, "TJ") { scanner, info in Scan.owner(info).show(scanner, array: true, spacing: false) }
            CGPDFOperatorTableSetCallback(table, "'") { scanner, info in Scan.owner(info).show(scanner, array: false, spacing: false) }
            CGPDFOperatorTableSetCallback(table, "\"") { scanner, info in Scan.owner(info).show(scanner, array: false, spacing: true) }
            return table
        }
    }

    private final class Scan {
        struct Scope { let owner: Int? }
        let budget: Budget
        let known: Set<Int>
        var scopes: [Scope] = []
        var seen: Set<Int> = []
        var nonemptyShows: Set<Int> = []
        var inText = false
        var unsupported = false
        var error: Error?

        init(budget: Budget, known: Set<Int>) {
            self.budget = budget
            self.known = known
        }

        static func owner(_ information: UnsafeMutableRawPointer?) -> Scan {
            Unmanaged<Scan>.fromOpaque(information!).takeUnretainedValue()
        }

        func step(_ scanner: CGPDFScannerRef) -> Bool {
            guard !unsupported, error == nil else { CGPDFScannerStop(scanner); return false }
            do { try budget.cancellationCheck?() }
            catch { self.error = error; CGPDFScannerStop(scanner); return false }
            guard budget.operators < budget.limits.maximumOperators else { reject(scanner); return false }
            budget.operators += 1
            return true
        }

        func reject(_ scanner: CGPDFScannerRef) {
            unsupported = true
            CGPDFScannerStop(scanner)
        }

        private func noMoreOperands(_ scanner: CGPDFScannerRef) -> Bool {
            var extra: CGPDFObjectRef?
            return !CGPDFScannerPopObject(scanner, &extra)
        }

        func generic(_ scanner: CGPDFScannerRef) {
            guard step(scanner) else { return }
            var object: CGPDFObjectRef?
            while CGPDFScannerPopObject(scanner, &object) {
                do { try budget.cancellationCheck?() }
                catch { self.error = error; CGPDFScannerStop(scanner); return }
                guard budget.array(1) else { reject(scanner); return }
            }
        }

        func textBoundary(_ scanner: CGPDFScannerRef, begin: Bool) {
            guard step(scanner) else { return }
            guard inText != begin, noMoreOperands(scanner) else { reject(scanner); return }
            inText = begin
        }

        func begin(_ scanner: CGPDFScannerRef, properties: Bool) {
            guard step(scanner) else { return }
            var object: CGPDFObjectRef?
            if properties, !CGPDFScannerPopObject(scanner, &object) { reject(scanner); return }
            var tag: UnsafePointer<CChar>?
            guard CGPDFScannerPopName(scanner, &tag), let name = Reader.name(tag),
                  noMoreOperands(scanner), scopes.count < 8 else { reject(scanner); return }
            var owner = scopes.last?.owner
            if properties {
                // Named property lists are outside the first admitted subset.
                guard let dictionary = Reader.dictionary(object) else { reject(scanner); return }
                if let mcidObject = Reader.object(dictionary, "MCID") {
                    guard owner == nil, Reader.keys(dictionary, allowed: ["MCID"]),
                          let mcid = Reader.integer(mcidObject), mcid >= 0, known.contains(mcid),
                          seen.insert(mcid).inserted else { reject(scanner); return }
                    owner = mcid
                } else {
                    // CoreGraphics emits bounded font-fallback Span replacements
                    // under an outer MCID. The structure replacement wins once.
                    guard owner != nil, name == "Span",
                          Reader.keys(dictionary, allowed: ["ActualText"]),
                          let string = Reader.string(Reader.object(dictionary, "ActualText")) else { reject(scanner); return }
                    do {
                        guard try budget.decode(string) != nil else { reject(scanner); return }
                    } catch { self.error = error; CGPDFScannerStop(scanner); return }
                }
            }
            scopes.append(Scope(owner: owner))
        }

        func end(_ scanner: CGPDFScannerRef) {
            guard step(scanner) else { return }
            guard !scopes.isEmpty, noMoreOperands(scanner) else { reject(scanner); return }
            scopes.removeLast()
        }

        func show(_ scanner: CGPDFScannerRef, array: Bool, spacing: Bool) {
            guard step(scanner) else { return }
            guard inText else { reject(scanner); return }
            var nonempty = false
            if array {
                var value: CGPDFArrayRef?
                guard CGPDFScannerPopArray(scanner, &value), let value,
                      budget.array(CGPDFArrayGetCount(value)) else { reject(scanner); return }
                for index in 0..<CGPDFArrayGetCount(value) {
                    do { try budget.cancellationCheck?() }
                    catch { self.error = error; CGPDFScannerStop(scanner); return }
                    var object: CGPDFObjectRef?
                    guard CGPDFArrayGetObject(value, index, &object), let object else { reject(scanner); return }
                    switch CGPDFObjectGetType(object) {
                    case .string:
                        guard let string = Reader.string(object),
                              CGPDFStringGetLength(string) <= budget.limits.maximumEncodedStringBytes else { reject(scanner); return }
                        nonempty = nonempty || CGPDFStringGetLength(string) > 0
                    case .integer, .real:
                        var number: CGPDFReal = 0
                        guard CGPDFObjectGetValue(object, .real, &number), number.isFinite else { reject(scanner); return }
                    default: reject(scanner); return
                    }
                }
            } else {
                var string: CGPDFStringRef?
                guard CGPDFScannerPopString(scanner, &string), let string,
                      CGPDFStringGetLength(string) <= budget.limits.maximumEncodedStringBytes else { reject(scanner); return }
                nonempty = CGPDFStringGetLength(string) > 0
                if spacing {
                    var a: CGPDFReal = 0, b: CGPDFReal = 0
                    guard CGPDFScannerPopNumber(scanner, &a), CGPDFScannerPopNumber(scanner, &b),
                          a.isFinite, b.isFinite else { reject(scanner); return }
                }
            }
            guard noMoreOperands(scanner) else { reject(scanner); return }
            if nonempty {
                guard let owner = scopes.last?.owner else { reject(scanner); return }
                nonemptyShows.insert(owner)
            }
        }
    }
}
