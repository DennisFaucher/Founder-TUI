//
//  main.swift
//  Founder
//
//  Created by Dennis Faucher on 10/15/2026.
//

import Foundation

// MARK: - Fuzzy search (fzf-style)

struct FuzzyMatch {
    var score: Int
    var positions: [Int]
}

/// One whitespace-separated piece of a query. `exact`/`fromStart`/`toEnd` mark
/// the non-fuzzy anchor operators (`'`, `^`, `$`); `negate` is the `!` prefix.
private struct FuzzyTerm {
    var negate = false
    var exact = false
    var fromStart = false
    var toEnd = false
    var text = ""
    var caseSensitive = false
}

/// A query in the spirit of fzf's search syntax: whitespace-separated terms that
/// must all match (AND). A term may be prefixed with `!` to exclude matches and
/// `'` for an exact substring, `^` to anchor at the start, or suffixed with `$`
/// to anchor at the end. Terms containing an uppercase letter match
/// case-sensitively; everything else is case-insensitive.
struct FuzzyQuery {
    private var terms: [FuzzyTerm] = []

    var isEmpty: Bool { terms.isEmpty }

    init(_ raw: String) {
        for token in raw.split(whereSeparator: { $0.isWhitespace }) {
            var term = FuzzyTerm()
            var text = String(token)
            if text.hasPrefix("!") {
                term.negate = true
                text.removeFirst()
            }
            if text.hasPrefix("'") {
                term.exact = true
                text.removeFirst()
            } else {
                if text.hasPrefix("^") {
                    term.fromStart = true
                    text.removeFirst()
                }
                if text.count > 1, text.hasSuffix("$") {
                    term.toEnd = true
                    text.removeLast()
                }
            }
            guard !text.isEmpty else { continue }
            term.text = text
            term.caseSensitive = text.contains { $0.isUppercase }
            terms.append(term)
        }
    }

    /// Returns the combined score and highlighted character offsets when every
    /// term matches, or nil when any required term misses or any `!` term hits.
    func match(_ candidate: String) -> FuzzyMatch? {
        var score = 0
        var positions: Set<Int> = []
        for term in terms {
            let result = matchTerm(term, candidate: candidate)
            if term.negate {
                if result != nil { return nil }
                continue
            }
            guard let result = result else { return nil }
            score += result.score
            positions.formUnion(result.positions)
        }
        return FuzzyMatch(score: score, positions: positions.sorted())
    }

    private func matchTerm(_ term: FuzzyTerm, candidate: String) -> FuzzyMatch? {
        if term.exact || term.fromStart || term.toEnd {
            return anchoredMatch(term, candidate: candidate)
        }

        let original = Array(candidate)
        let folded = Array(candidate.lowercased())
        let query = Array(term.caseSensitive ? term.text : term.text.lowercased())
        if term.caseSensitive || folded.count != original.count {
            return fuzzySubsequenceMatch(query: query, candidate: original, original: original)
        }
        return fuzzySubsequenceMatch(query: query, candidate: folded, original: original)
    }

    private func anchoredMatch(_ term: FuzzyTerm, candidate: String) -> FuzzyMatch? {
        var options: String.CompareOptions = term.caseSensitive ? [] : [.caseInsensitive]
        if term.fromStart || term.toEnd { options.insert(.anchored) }
        // `.anchored` alone pins the start; adding `.backwards` also pins the
        // end, so `^foo$` requires the whole string to equal the term.
        if term.toEnd { options.insert(.backwards) }
        guard let range = candidate.range(of: term.text, options: options) else { return nil }
        let start = candidate.distance(from: candidate.startIndex, to: range.lowerBound)
        let length = candidate.distance(from: range.lowerBound, to: range.upperBound)
        var score = FuzzyScoring.match * length
        if start == 0 { score += FuzzyScoring.boundary }
        return FuzzyMatch(score: score, positions: Array(start..<(start + length)))
    }
}

/// Scoring weights, fzf-inspired. These live in a type rather than as file-scope
/// `let`s on purpose: top-level `let`s in main.swift are initialised as part of
/// the executable's top-level code, so they stay zero for anyone that imports
/// the module (e.g. the test bundle) instead of running the app.
private enum FuzzyScoring {
    static let match = 16
    static let gapStart = -3
    static let gapExtension = -1
    static let boundary = 8
    static let camel = 7
    static let consecutive = 8
}

/// Greedy fzf-style fuzzy match: every character of `query` must appear in
/// `candidate` in order. Prefers word and camelCase boundaries and consecutive
/// runs, and penalises gaps. `candidate` may be a lowercased copy of
/// `original`, which is used to classify characters.
private func fuzzySubsequenceMatch(query: [Character], candidate: [Character], original: [Character]) -> FuzzyMatch? {
    guard !query.isEmpty, candidate.count >= query.count else { return nil }

    var score = 0
    var queryIndex = 0
    var previousMatch = -1
    var consecutive = 0
    var positions: [Int] = []

    for index in candidate.indices {
        if queryIndex == query.count { break }
        guard candidate[index] == query[queryIndex] else { continue }

        score += FuzzyScoring.match

        if previousMatch >= 0, index - previousMatch > 1 {
            let gap = index - previousMatch - 1
            score += FuzzyScoring.gapStart + FuzzyScoring.gapExtension * (gap - 1)
            consecutive = 0
        }

        var bonus = 0
        if index == 0 {
            bonus = FuzzyScoring.boundary
        } else {
            let previous = original[index - 1]
            if !previous.isLetter && !previous.isNumber {
                bonus = FuzzyScoring.boundary
            } else if previous.isNumber != original[index].isNumber {
                bonus = FuzzyScoring.camel
            } else if original[index].isUppercase {
                bonus = FuzzyScoring.camel
            }
        }
        if consecutive > 0 { bonus = max(bonus, FuzzyScoring.consecutive) }
        score += bonus

        consecutive += 1
        previousMatch = index
        positions.append(index)
        queryIndex += 1
    }

    guard queryIndex == query.count else { return nil }
    return FuzzyMatch(score: score, positions: positions)
}

struct FavoriteEntry {
    var path: String
    var depth: Int
}

/// Whether `url` is a bundle/package (an `.app`, `.bundle`, `.rtfd`, …). Finder
/// presents packages as single files rather than folders, so we treat them as
/// files for listing, sorting and opening.
func isPackage(_ url: URL) -> Bool {
    // Linux has no bundle concept, so nothing is ever presented as a package.
    return false
}

/// The path shown for `url` while recursively searching: relative to the search
/// root. The recursive matcher matches this same string, so highlight offsets
/// always line up with the rendered row.
func relativeName(for url: URL, base: String) -> String {
    // `base` already ends in "/" when the search is rooted at "/", so don't
    // blindly append another one (that made every path look absolute-mismatched
    // and fall back to the bare file name).
    let prefix = base.hasSuffix("/") ? base : base + "/"
    let path = url.path
    if path.hasPrefix(prefix), path.count > prefix.count {
        return String(path.dropFirst(prefix.count))
    }
    return url.lastPathComponent
}

func uniqueDestinationURL(in directory: URL, name: String) -> URL {
    var destination = directory.appendingPathComponent(name)
    if !FileManager.default.fileExists(atPath: destination.path) { return destination }

    let base = (name as NSString).deletingPathExtension
    let ext = (name as NSString).pathExtension
    var counter = 1
    repeat {
        let newName = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
        destination = directory.appendingPathComponent(newName)
        counter += 1
    } while FileManager.default.fileExists(atPath: destination.path)
    return destination
}

// MARK: - Entry point (terminal UI)

// AppKit does not exist on Linux, so this is a self-contained terminal
// front-end: fzf-style fuzzy filtering, recursive search, favorites and the
// sort/hidden preferences stored in a `founder.config` file, folders first.

#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

private enum TUIKey {
    case up, down, left, right
    case pageUp, pageDown, home, end
    case enter, backspace, escape, tab
    case character(Character)
    case control(Character)
    case other
}

private final class Terminal {
    private var original = termios()
    private var rawEnabled = false
    private(set) var hitEOF = false

    var size: (rows: Int, cols: Int) {
        var window = winsize()
        if ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &window) == 0,
           window.ws_row > 0, window.ws_col > 0 {
            return (Int(window.ws_row), Int(window.ws_col))
        }
        return (24, 80)
    }

    func enableRawMode() {
        var raw = termios()
        guard tcgetattr(STDIN_FILENO, &raw) == 0 else { return }
        original = raw
        cfmakeraw(&raw)
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
        rawEnabled = true
    }

    func disableRawMode() {
        guard rawEnabled else { return }
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &original)
        rawEnabled = false
    }

    /// Waits up to `timeoutMs` milliseconds for a key; pass a negative value to
    /// block indefinitely. Returns nil on timeout or end of input.
    func readKey(timeoutMs: Int32 = -1) -> TUIKey? {
        if timeoutMs >= 0 {
            var descriptors = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            if poll(&descriptors, 1, timeoutMs) <= 0 { return nil }
        }
        var byte: UInt8 = 0
        guard read(STDIN_FILENO, &byte, 1) == 1 else {
            hitEOF = true
            return nil
        }
        switch byte {
        case 0x1b:
            return readEscapeSequence()
        case 0x7f, 0x08:
            return .backspace
        case 0x0d, 0x0a:
            return .enter
        case 0x09:
            return .tab
        default:
            if byte < 0x20 {
                return .control(Character(UnicodeScalar(byte)))
            }
            return readUTF8(start: byte)
        }
    }

    private func pollByte() -> UInt8? {
        var descriptors = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptors, 1, 50) > 0 else { return nil }
        var byte: UInt8 = 0
        guard read(STDIN_FILENO, &byte, 1) == 1 else { return nil }
        return byte
    }

    private func readEscapeSequence() -> TUIKey {
        guard let next = pollByte(), next == UInt8(ascii: "["), let code = pollByte() else {
            return .escape
        }
        switch code {
        case UInt8(ascii: "A"): return .up
        case UInt8(ascii: "B"): return .down
        case UInt8(ascii: "C"): return .right
        case UInt8(ascii: "D"): return .left
        case UInt8(ascii: "H"): return .home
        case UInt8(ascii: "F"): return .end
        case UInt8(ascii: "5"):
            _ = pollByte()
            return .pageUp
        case UInt8(ascii: "6"):
            _ = pollByte()
            return .pageDown
        default:
            return .other
        }
    }

    private func readUTF8(start: UInt8) -> TUIKey {
        var bytes = [start]
        let continuationCount: Int
        if start >> 5 == 0b110 {
            continuationCount = 1
        } else if start >> 4 == 0b1110 {
            continuationCount = 2
        } else if start >> 3 == 0b11110 {
            continuationCount = 3
        } else {
            continuationCount = 0
        }
        for _ in 0..<continuationCount {
            guard let continuation = pollByte() else { break }
            bytes.append(continuation)
        }
        let string = String(decoding: bytes, as: UTF8.self)
        guard let character = string.first else { return .other }
        return .character(character)
    }
}

/// Simple `key = value` config file for the Linux terminal UI, at
/// `$XDG_CONFIG_HOME/founder.config` (default `~/.config/founder.config`).
/// Swift's Linux runtime never persists `UserDefaults`, so favorites and the
/// display preferences live here instead.
private struct TerminalConfig {
    static let defaultFavoritePaths = ["~/Desktop", "~/Documents", "~/Downloads", "~/Music", "~/Pictures"]

    var favorites: [String] = []
    var sortKey = "name"
    var sortAscending = true
    var showHidden = false
    var isNew = false

    static var url: URL {
        let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            .map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        return base.appendingPathComponent("founder.config")
    }

    static func load() -> TerminalConfig {
        var config = TerminalConfig()
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            config.isNew = true
            config.favorites = defaultFavoritePaths
            return config
        }
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "favorite":
                if !value.isEmpty { config.favorites.append(value) }
            case "sort":
                if !value.isEmpty { config.sortKey = value.lowercased() }
            case "sortascending":
                config.sortAscending = value.lowercased() != "false"
            case "showhidden":
                config.showHidden = value.lowercased() == "true"
            default:
                break
            }
        }
        return config
    }

    func write() {
        var lines = [
            "# Founder — terminal UI configuration",
            "# One favorite per line; ~ expands to your home directory.",
            "# Keys: favorite, sort (name|size|date), sortAscending, showHidden",
            "#",
        ]
        lines += favorites.map { "favorite = \($0)" }
        lines.append("")
        lines.append("sort = \(sortKey)")
        lines.append("sortAscending = \(sortAscending)")
        lines.append("showHidden = \(showHidden)")
        do {
            try FileManager.default.createDirectory(
                at: Self.url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try (lines.joined(separator: "\n") + "\n").write(to: Self.url, atomically: true, encoding: .utf8)
        } catch {
            // Keep working from memory if the file can't be written.
        }
    }
}

private final class TerminalFavoritesStore {
    private(set) var favorites: [FavoriteEntry]

    init(paths: [String]) {
        favorites = paths.map { FavoriteEntry(path: $0, depth: 0) }
    }

    func toggle(path: String) -> Bool {
        if let index = favorites.firstIndex(where: { $0.path == path }) {
            favorites.remove(at: index)
            return false
        }
        favorites.append(FavoriteEntry(path: path, depth: 0))
        return true
    }
}

private final class TerminalUI {
    fileprivate struct Row {
        var url: URL
        var isDir: Bool
        var displayName: String
        var size: Int64?
        var modified: Date?
    }

    private enum Prompt {
        case goTo
        case newFolder
        case newFile
        case rename(URL)
        case confirmDelete(URL, permanent: Bool)
    }

    private let terminal = Terminal()
    private let fileManager = FileManager.default
    private var config = TerminalConfig.load()
    private lazy var favorites = TerminalFavoritesStore(paths: config.favorites)

    private var currentDirectory: URL
    private var rows: [Row] = []
    private var cursor = 0
    private var scrollOffset = 0

    private var filter = ""
    private var filterMode = false
    private var recursiveSearch = false
    private var showHidden = false

    private var sortKey = "name"
    private var sortAscending = true

    private var history: [URL] = []
    private var historyIndex = -1

    private var prompt: Prompt?
    private var promptBuffer = ""

    private var statusMessage = ""
    private var activeQuery = FuzzyQuery("")
    private var matchScores: [URL: Int] = [:]
    private var matchPositions: [URL: [Int]] = [:]
    private var lastScannedCount = 0

    private var isSearching = false
    private var needsRedraw = true
    private var lastReportedProgress = (scanned: 0, matches: 0)

    private let searchQueue = DispatchQueue(label: "com.dennisfaucher.founder.tui-search", qos: .userInitiated)
    private let searchLock = NSLock()
    private var searchGeneration = 0
    private var searchFinished = false
    private var searchProgress = (scanned: 0, matches: 0)
    private var searchResults: [Row] = []
    private var searchScores: [URL: Int] = [:]
    private var searchPositions: [URL: [Int]] = [:]

    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d HH:mm"
        return formatter
    }()

    init() {
        currentDirectory = fileManager.homeDirectoryForCurrentUser
        sortKey = config.sortKey
        sortAscending = config.sortAscending
        showHidden = config.showHidden
        if config.isNew { saveConfig() }
    }

    func run() -> Int32 {
        terminal.enableRawMode()
        defer {
            terminal.disableRawMode()
            write("\u{1b}[?25h\r\n")
        }

        navigate(to: currentDirectory, pushHistory: true)
        var lastSize = terminal.size
        draw()

        while true {
            if let key = terminal.readKey(timeoutMs: 100) {
                if handle(key) { return 0 }
                needsRedraw = true
            } else if terminal.hitEOF {
                return 0
            }
            pollSearch()
            let size = terminal.size
            if size != lastSize {
                lastSize = size
                needsRedraw = true
            }
            if needsRedraw {
                needsRedraw = false
                draw()
            }
        }
    }

    // MARK: Key handling

    private func handle(_ key: TUIKey) -> Bool {
        if prompt != nil { return handlePrompt(key) }
        if filterMode { return handleFilter(key) }

        switch key {
        case .control("c"), .character("q"):
            return true
        case .escape:
            if isSearching || recursiveSearch || !filter.isEmpty {
                recursiveSearch = false
                filter = ""
                filterMode = false
                reload()
                statusMessage = "Back to browsing \(abbreviate(currentDirectory.path))"
            } else if !statusMessage.isEmpty {
                statusMessage = ""
            }
            needsRedraw = true
        case .up, .character("k"):
            moveCursor(by: -1)
        case .down, .character("j"):
            moveCursor(by: 1)
        case .pageUp:
            moveCursor(by: -(terminal.size.rows - 7))
        case .pageDown:
            moveCursor(by: terminal.size.rows - 7)
        case .home:
            cursor = 0
        case .end:
            cursor = max(0, rows.count - 1)
        case .enter:
            openSelection()
        case .backspace, .character("-"):
            goToParent()
        case .character("["):
            historyBack()
        case .character("]"):
            historyForward()
        case .character("/"):
            filterMode = true
        case .character("r"):
            recursiveSearch.toggle()
            reload()
            statusMessage = recursiveSearch ? "Recursive search on" : "Recursive search off"
        case .character("h"):
            showHidden.toggle()
            saveConfig()
            reload()
            statusMessage = showHidden ? "Showing hidden files" : "Hiding hidden files"
        case .character("s"):
            cycleSort()
        case .character("A"):
            toggleFavorite()
        case .character("g"):
            prompt = .goTo
            promptBuffer = ""
        case .character("n"):
            prompt = .newFolder
            promptBuffer = ""
        case .character("f"):
            prompt = .newFile
            promptBuffer = ""
        case .character("m"):
            if let row = selectedRow {
                prompt = .rename(row.url)
                promptBuffer = ""
            }
        case .character("t"):
            if let row = selectedRow {
                prompt = .confirmDelete(row.url, permanent: false)
                promptBuffer = ""
            }
        case .character("D"):
            if let row = selectedRow {
                prompt = .confirmDelete(row.url, permanent: true)
                promptBuffer = ""
            }
        case .character("o"):
            if let row = selectedRow {
                openExternally(row.url)
            }
        case .character("i"):
            showInfo()
        case .character(let digit) where digit >= "1" && digit <= "9":
            jumpToFavorite(Int(String(digit))! - 1)
        default:
            break
        }
        return false
    }

    private func handleFilter(_ key: TUIKey) -> Bool {
        switch key {
        case .escape:
            filter = ""
            filterMode = false
            reload()
            statusMessage = "Filter cleared"
        case .enter:
            filterMode = false
        case .backspace:
            if filter.isEmpty {
                filterMode = false
            } else {
                filter.removeLast()
                reload()
            }
        case .character(let character):
            filter.append(character)
            reload()
        default:
            break
        }
        return false
    }

    private func handlePrompt(_ key: TUIKey) -> Bool {
        switch key {
        case .escape:
            prompt = nil
            promptBuffer = ""
            statusMessage = "Cancelled"
        case .enter:
            submitPrompt()
        case .backspace:
            if promptBuffer.isEmpty {
                prompt = nil
            } else {
                promptBuffer.removeLast()
            }
        case .character(let character):
            promptBuffer.append(character)
        default:
            break
        }
        return false
    }

    private func submitPrompt() {
        switch prompt {
        case .goTo:
            let expanded = (promptBuffer as NSString).expandingTildeInPath
            navigate(to: URL(fileURLWithPath: expanded), pushHistory: true)
        case .newFolder:
            let name = promptBuffer.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty {
                let destination = uniqueDestinationURL(in: currentDirectory, name: name)
                do {
                    try fileManager.createDirectory(at: destination, withIntermediateDirectories: false)
                    statusMessage = "Created \(destination.lastPathComponent)"
                    reload()
                } catch {
                    statusMessage = "Create failed: \(error.localizedDescription)"
                }
            }
        case .newFile:
            let name = promptBuffer.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty {
                let destination = uniqueDestinationURL(in: currentDirectory, name: name)
                if fileManager.createFile(atPath: destination.path, contents: Data()) {
                    statusMessage = "Created \(destination.lastPathComponent)"
                    reload()
                } else {
                    statusMessage = "Could not create \(name)"
                }
            }
        case .rename(let url):
            let name = promptBuffer.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty {
                do {
                    try fileManager.moveItem(
                        at: url,
                        to: url.deletingLastPathComponent().appendingPathComponent(name)
                    )
                    statusMessage = "Renamed to \(name)"
                    reload()
                } catch {
                    statusMessage = "Rename failed: \(error.localizedDescription)"
                }
            }
        case .confirmDelete(let url, let permanent):
            let answer = promptBuffer.trimmingCharacters(in: .whitespaces).lowercased()
            if answer == "y" || answer == "yes" {
                if permanent {
                    do {
                        try fileManager.removeItem(at: url)
                        statusMessage = "Deleted \(url.lastPathComponent)"
                        reload()
                    } catch {
                        statusMessage = "Delete failed: \(error.localizedDescription)"
                    }
                } else {
                    trash(url)
                }
            } else {
                statusMessage = "Cancelled"
            }
        case nil:
            break
        }
        prompt = nil
        promptBuffer = ""
    }

    private func trash(_ url: URL) {
        guard let process = launch("/usr/bin/gio", arguments: ["trash", url.path]) else { return }
        process.waitUntilExit()
        if process.terminationStatus == 0 {
            statusMessage = "Trashed \(url.lastPathComponent)"
            reload()
        } else {
            statusMessage = "gio trash failed (status \(process.terminationStatus))"
        }
    }

    private func openExternally(_ url: URL) {
        guard launch("/usr/bin/xdg-open", arguments: [url.path]) != nil else { return }
        statusMessage = "Opened \(url.lastPathComponent)"
    }

    private func launch(_ path: String, arguments: [String]) -> Process? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            return process
        } catch {
            statusMessage = "\(path) failed: \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: Navigation & listing

    @discardableResult
    private func navigate(to url: URL, pushHistory: Bool) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue, !isPackage(url) else {
            statusMessage = "Not a directory: \(url.path)"
            return false
        }

        if pushHistory {
            if historyIndex < history.count - 1 {
                history.removeSubrange((historyIndex + 1)...)
            }
            history.append(url)
            historyIndex = history.count - 1
        }

        if !filter.isEmpty {
            filter = ""
            filterMode = false
        }
        cancelSearch()
        currentDirectory = url
        reload()
        cursor = 0
        scrollOffset = 0
        statusMessage = ""
        return true
    }

    private func goToParent() {
        let parent = currentDirectory.deletingLastPathComponent()
        guard parent.path != currentDirectory.path else { return }
        navigate(to: parent, pushHistory: true)
    }

    private func historyBack() {
        guard historyIndex > 0 else { return }
        historyIndex -= 1
        navigate(to: history[historyIndex], pushHistory: false)
    }

    private func historyForward() {
        guard historyIndex < history.count - 1 else { return }
        historyIndex += 1
        navigate(to: history[historyIndex], pushHistory: false)
    }

    private func reload() {
        cancelSearch()
        let query = FuzzyQuery(filter.trimmingCharacters(in: .whitespaces))
        activeQuery = query
        matchScores.removeAll()
        matchPositions.removeAll()
        lastScannedCount = 0

        if recursiveSearch && !query.isEmpty {
            rows = []
            startRecursiveSearch(query: query)
            clampCursor()
            return
        }

        do {
            let names = try fileManager.contentsOfDirectory(atPath: currentDirectory.path)
            lastScannedCount = names.count
            var result: [Row] = []
            for name in names {
                if name.hasPrefix(".") && !showHidden { continue }
                let item = currentDirectory.appendingPathComponent(name)
                if !query.isEmpty {
                    guard let match = query.match(name) else { continue }
                    matchScores[item] = match.score
                    if !match.positions.isEmpty { matchPositions[item] = match.positions }
                }
                result.append(makeRow(for: item))
            }
            rows = sortedForDisplay(result)
        } catch {
            rows = []
            statusMessage = "Cannot read directory: \(error.localizedDescription)"
        }
        clampCursor()
    }

    private func makeRow(for url: URL) -> Row {
        var isDirectory: ObjCBool = false
        _ = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
        let isDir = isDirectory.boolValue && !isPackage(url)
        let attributes = (try? fileManager.attributesOfItem(atPath: url.path)) ?? [:]
        return Row(
            url: url,
            isDir: isDir,
            displayName: displayName(for: url),
            size: isDir ? nil : (attributes[.size] as? NSNumber)?.int64Value,
            modified: attributes[.modificationDate] as? Date
        )
    }

    private func displayName(for url: URL) -> String {
        guard recursiveSearch, !activeQuery.isEmpty else { return url.lastPathComponent }
        return relativeName(for: url, base: currentDirectory.standardizedFileURL.path)
    }

    private func sortedForDisplay(_ items: [Row]) -> [Row] {
        func compare(_ a: Row, _ b: Row) -> ComparisonResult {
            switch sortKey {
            case "size":
                let sizeA = a.size ?? -1
                let sizeB = b.size ?? -1
                if sizeA != sizeB { return sizeA < sizeB ? .orderedAscending : .orderedDescending }
            case "date":
                let dateA = a.modified ?? .distantPast
                let dateB = b.modified ?? .distantPast
                if dateA != dateB { return dateA < dateB ? .orderedAscending : .orderedDescending }
            default:
                break
            }
            return a.displayName.localizedCaseInsensitiveCompare(b.displayName)
        }

        if !activeQuery.isEmpty {
            return items.sorted { a, b in
                let scoreA = matchScores[a.url] ?? 0
                let scoreB = matchScores[b.url] ?? 0
                if scoreA != scoreB { return scoreA > scoreB }
                let result = compare(a, b)
                return sortAscending ? result == .orderedAscending : result == .orderedDescending
            }
        }
        return items.sorted { a, b in
            if a.isDir != b.isDir { return a.isDir }
            let result = compare(a, b)
            return sortAscending ? result == .orderedAscending : result == .orderedDescending
        }
    }

    // MARK: Recursive search (async, generation-cancelled, polled by the loop)

    private func startRecursiveSearch(query: FuzzyQuery) {
        searchLock.lock()
        searchGeneration += 1
        let generation = searchGeneration
        searchFinished = false
        searchProgress = (0, 0)
        searchResults = []
        searchScores = [:]
        searchPositions = [:]
        searchLock.unlock()

        isSearching = true
        lastReportedProgress = (0, 0)
        statusMessage = "Searching…"

        let root = currentDirectory
        let base = root.standardizedFileURL.path
        let includeHidden = showHidden

        searchQueue.async { [weak self] in
            guard let self else { return }
            let fileManager = FileManager.default
            var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
            if !includeHidden { options.insert(.skipsHiddenFiles) }

            let maxResults = 5000
            let maxVisited = 200_000
            var visited = 0
            var matches: [Row] = []
            var scores: [URL: Int] = [:]
            var positions: [URL: [Int]] = [:]

            if let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: options,
                errorHandler: { _, _ in true }
            ) {
                for case let item as URL in enumerator {
                    if self.searchShouldStop(generation) { break }
                    visited += 1
                    if visited >= maxVisited || matches.count >= maxResults { break }
                    if visited % 250 == 0 {
                        self.searchLock.lock()
                        self.searchProgress = (visited, matches.count)
                        self.searchLock.unlock()
                    }

                    let name = relativeName(for: item, base: base)
                    guard let match = query.match(name) else { continue }
                    var itemIsDirectory: ObjCBool = false
                    _ = fileManager.fileExists(atPath: item.path, isDirectory: &itemIsDirectory)
                    let isDir = itemIsDirectory.boolValue && !isPackage(item)
                    let attributes = (try? fileManager.attributesOfItem(atPath: item.path)) ?? [:]
                    matches.append(Row(
                        url: item,
                        isDir: isDir,
                        displayName: name,
                        size: isDir ? nil : (attributes[.size] as? NSNumber)?.int64Value,
                        modified: attributes[.modificationDate] as? Date
                    ))
                    scores[item] = match.score
                    if !match.positions.isEmpty { positions[item] = match.positions }
                }
            }

            self.searchLock.lock()
            guard generation == self.searchGeneration else {
                self.searchLock.unlock()
                return
            }
            self.searchResults = matches
            self.searchScores = scores
            self.searchPositions = positions
            self.searchProgress = (visited, matches.count)
            self.searchFinished = true
            self.searchLock.unlock()
        }
    }

    private func cancelSearch() {
        searchLock.lock()
        searchGeneration += 1
        searchFinished = false
        searchLock.unlock()
        isSearching = false
    }

    private func searchShouldStop(_ generation: Int) -> Bool {
        searchLock.lock()
        defer { searchLock.unlock() }
        return generation != searchGeneration
    }

    private func pollSearch() {
        if isSearching {
            searchLock.lock()
            let progress = searchProgress
            searchLock.unlock()
            if progress != lastReportedProgress {
                lastReportedProgress = progress
                statusMessage = "Searching… \(progress.scanned) scanned · \(progress.matches) found"
                needsRedraw = true
            }
        }

        searchLock.lock()
        guard searchFinished else {
            searchLock.unlock()
            return
        }
        matchScores = searchScores
        matchPositions = searchPositions
        lastScannedCount = searchProgress.scanned
        rows = sortedForDisplay(searchResults)
        let found = rows.count
        let scanned = searchProgress.scanned
        searchFinished = false
        searchLock.unlock()

        isSearching = false
        statusMessage = "\(found) found of \(scanned) scanned"
        clampCursor()
        needsRedraw = true
    }

    // MARK: Actions

    private var selectedRow: Row? {
        rows.indices.contains(cursor) ? rows[cursor] : nil
    }

    private func moveCursor(by delta: Int) {
        guard !rows.isEmpty else { return }
        cursor = max(0, min(cursor + delta, rows.count - 1))
    }

    private func clampCursor() {
        guard !rows.isEmpty else {
            cursor = 0
            scrollOffset = 0
            return
        }
        cursor = max(0, min(cursor, rows.count - 1))
    }

    private func openSelection() {
        guard let row = selectedRow else { return }
        if row.isDir {
            navigate(to: row.url, pushHistory: true)
        } else {
            openExternally(row.url)
        }
    }

    private func cycleSort() {
        let states: [(String, Bool)] = [
            ("name", true), ("size", true), ("date", true),
            ("name", false), ("size", false), ("date", false),
        ]
        let current = states.firstIndex { $0.0 == sortKey && $0.1 == sortAscending } ?? 0
        let next = states[(current + 1) % states.count]
        sortKey = next.0
        sortAscending = next.1
        saveConfig()
        reload()
        statusMessage = "Sort: \(sortKey) \(sortAscending ? "ascending" : "descending")"
    }

    private func saveConfig() {
        config.favorites = favorites.favorites.map { $0.path }
        config.sortKey = sortKey
        config.sortAscending = sortAscending
        config.showHidden = showHidden
        config.isNew = false
        config.write()
    }

    private func toggleFavorite() {
        let path = currentDirectory.standardizedFileURL.path
        let name = currentDirectory.lastPathComponent.isEmpty
            ? currentDirectory.path
            : currentDirectory.lastPathComponent
        if favorites.toggle(path: path) {
            statusMessage = "Added to favorites: \(name)"
        } else {
            statusMessage = "Removed from favorites: \(name)"
        }
        saveConfig()
    }

    private func jumpToFavorite(_ index: Int) {
        guard favorites.favorites.indices.contains(index) else {
            statusMessage = "No favorite #\(index + 1)"
            return
        }
        let expanded = (favorites.favorites[index].path as NSString).expandingTildeInPath
        navigate(to: URL(fileURLWithPath: expanded), pushHistory: true)
    }

    private func showInfo() {
        guard let row = selectedRow else { return }
        let attributes = (try? fileManager.attributesOfItem(atPath: row.url.path)) ?? [:]
        let size = ByteCountFormatter.string(
            fromByteCount: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
            countStyle: .file
        )
        let modified = (attributes[.modificationDate] as? Date)
            .map { Self.dateTimeFormatter.string(from: $0) } ?? "?"
        let permissions = (attributes[.posixPermissions] as? NSNumber)
            .map { String(format: "%o", $0.uint16Value) } ?? "?"
        let kind = row.isDir ? "folder" : size
        statusMessage = "\(row.url.lastPathComponent) · \(kind) · modified \(modified) · \(permissions) · \(row.url.path)"
    }

    // MARK: Drawing

    private func draw() {
        let (terminalRows, terminalColumns) = terminal.size
        let width = max(40, terminalColumns)
        let height = max(7, terminalRows)
        let listHeight = max(1, height - 7)

        if cursor < scrollOffset { scrollOffset = cursor }
        if cursor >= scrollOffset + listHeight { scrollOffset = cursor - listHeight + 1 }
        scrollOffset = max(0, min(scrollOffset, max(0, rows.count - listHeight)))

        let sizeWidth = 10
        let dateWidth = 14
        let nameWidth = max(12, width - sizeWidth - dateWidth - 2)

        var lines: [String] = []

        var title = abbreviate(currentDirectory.path)
        if recursiveSearch && !filter.isEmpty { title += "  [recursive]" }
        lines.append(buildLine([(title, "1")], selected: false, width: width))

        var favoriteSegments: [(text: String, codes: String)] = [("Favorites", "2")]
        for (index, favorite) in favorites.favorites.enumerated() where index < 9 {
            let favoriteURL = URL(fileURLWithPath: (favorite.path as NSString).expandingTildeInPath)
            let name = favoriteURL.lastPathComponent.isEmpty ? favorite.path : favoriteURL.lastPathComponent
            let isCurrent = favoriteURL.standardizedFileURL == currentDirectory.standardizedFileURL
            let label = isCurrent ? "[\(index + 1)) \(name)]" : "\(index + 1)) \(name)"
            favoriteSegments.append(("  " + label, isCurrent ? "1;36" : "36"))
        }
        lines.append(buildLine(favoriteSegments, selected: false, width: width))

        lines.append(buildLine([
            (pad(sortHeader(key: "name", title: "Name"), nameWidth), "1;2"),
            (padLeft(sortHeader(key: "size", title: "Size"), sizeWidth), "1;2"),
            (pad(sortHeader(key: "date", title: "Modified"), dateWidth), "1;2"),
        ], selected: false, width: width))

        if rows.isEmpty {
            let message: String
            if isSearching {
                message = "Searching…"
            } else if !filter.isEmpty {
                message = "No matching items"
            } else {
                message = "Empty folder"
            }
            lines.append(buildLine([(message, "2")], selected: false, width: width))
            for _ in 1..<listHeight {
                lines.append("")
            }
        } else {
            let start = scrollOffset
            let end = min(rows.count, start + listHeight)
            for index in start..<end {
                lines.append(buildRowLine(
                    rows[index],
                    selected: index == cursor,
                    nameWidth: nameWidth,
                    sizeWidth: sizeWidth,
                    dateWidth: dateWidth,
                    width: width
                ))
            }
            for _ in end..<(start + listHeight) {
                lines.append("")
            }
        }

        lines.append(buildLine([("─", "")], selected: false, width: width))
        lines.append(buildLine(statusSegments(cols: width), selected: false, width: width))
        lines.append(helpLine(helpItemsNavigation(), width: width))
        lines.append(helpLine(helpItemsActions(), width: width))

        write("\u{1b}[?25l\u{1b}[2J\u{1b}[H" + lines.joined(separator: "\r\n"))
    }

    private func buildRowLine(
        _ row: Row,
        selected: Bool,
        nameWidth: Int,
        sizeWidth: Int,
        dateWidth: Int,
        width: Int
    ) -> String {
        var segments = attributedSegments(for: row, width: nameWidth - (row.isDir ? 1 : 0))
        if row.isDir {
            segments.append(("/", "36"))
        }
        let visible = segments.reduce(0) { $0 + $1.text.count }
        if visible < nameWidth {
            segments.append((String(repeating: " ", count: nameWidth - visible), ""))
        }
        let sizeText = row.isDir
            ? "--"
            : (row.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "")
        segments.append((padLeft(sizeText, sizeWidth), ""))
        let dateText = row.modified.map { Self.dateTimeFormatter.string(from: $0) } ?? ""
        segments.append(("  " + pad(dateText, dateWidth), ""))
        return buildLine(segments, selected: selected, width: width)
    }

    private func attributedSegments(for row: Row, width: Int) -> [(text: String, codes: String)] {
        let characters = Array(row.displayName)
        let positions = Set(matchPositions[row.url] ?? [])

        func runs(_ indices: [Int]) -> [(text: String, codes: String)] {
            var segments: [(text: String, codes: String)] = []
            var run = ""
            var runCodes: String?
            for index in indices {
                let codes: String
                if positions.contains(index) {
                    codes = "1;33"
                } else if row.isDir {
                    codes = "36"
                } else if row.url.pathExtension.isEmpty {
                    codes = "2"
                } else {
                    codes = ""
                }
                if runCodes == codes {
                    run.append(characters[index])
                } else {
                    if let existing = runCodes, !run.isEmpty {
                        segments.append((run, existing))
                    }
                    run = String(characters[index])
                    runCodes = codes
                }
            }
            if let existing = runCodes, !run.isEmpty {
                segments.append((run, existing))
            }
            return segments
        }

        if characters.count <= width {
            return runs(Array(0..<characters.count))
        }
        guard width > 2 else {
            return [(String(characters.prefix(max(0, width))), "")]
        }
        let headLength = (width - 1) / 2
        let tailLength = width - 1 - headLength
        var segments = runs(Array(0..<headLength))
        segments.append(("…", ""))
        segments += runs(Array((characters.count - tailLength)..<characters.count))
        return segments
    }

    private func buildLine(
        _ segments: [(text: String, codes: String)],
        selected: Bool,
        width: Int
    ) -> String {
        var output = ""
        var visible = 0
        for segment in segments {
            guard visible < width else { break }
            var text = segment.text
            if visible + text.count > width {
                text = String(text.prefix(max(0, width - visible)))
            }
            visible += text.count
            let codes: String
            if selected {
                codes = segment.codes.isEmpty ? "7" : "7;\(segment.codes)"
            } else {
                codes = segment.codes
            }
            if codes.isEmpty {
                output += text
            } else {
                output += "\u{1b}[\(codes)m\(text)\u{1b}[0m"
            }
        }
        if visible < width {
            let spaces = String(repeating: " ", count: width - visible)
            output += selected ? "\u{1b}[7m\(spaces)\u{1b}[0m" : spaces
        }
        return output
    }

    private func sortHeader(key: String, title: String) -> String {
        guard key == sortKey else { return title }
        return title + (sortAscending ? " ▲" : " ▼")
    }

    private func pad(_ text: String, _ width: Int) -> String {
        guard text.count < width else { return String(text.prefix(max(0, width))) }
        return text + String(repeating: " ", count: width - text.count)
    }

    private func padLeft(_ text: String, _ width: Int) -> String {
        guard text.count < width else { return String(text.prefix(max(0, width))) }
        return String(repeating: " ", count: width - text.count) + text
    }

    private func statusSegments(cols: Int) -> [(text: String, codes: String)] {
        let left: String
        if prompt != nil {
            left = promptLabel() + promptBuffer + "_"
        } else if filterMode {
            left = "/ \(filter)_"
        } else if !statusMessage.isEmpty {
            left = statusMessage
        } else if !filter.isEmpty {
            left = "\(rows.count) items · filter '\(filter)' · \(lastScannedCount) scanned"
        } else {
            left = "\(rows.count) items"
        }
        let right = (prompt == nil && !filterMode && !rows.isEmpty) ? "\(cursor + 1)/\(rows.count)" : ""
        let leftBudget = max(0, cols - right.count)
        return [(pad(left, leftBudget), ""), (right, "2")]
    }

    private func promptLabel() -> String {
        switch prompt {
        case .goTo:
            return "Go to folder: "
        case .newFolder:
            return "New folder name: "
        case .newFile:
            return "New file name: "
        case .rename(let url):
            return "Rename \(url.lastPathComponent) to: "
        case .confirmDelete(let url, let permanent):
            let verb = permanent ? "Permanently delete" : "Move to trash"
            return "\(verb) \(url.lastPathComponent)? y/N: "
        case nil:
            return ""
        }
    }

    /// Fits as many whole help items as the width allows; a too-narrow window
    /// drops trailing items instead of cutting one in half. Items whose mode is
    /// currently active render bold instead of dim.
    private func helpLine(_ items: [(text: String, active: Bool)], width: Int) -> String {
        var segments: [(text: String, codes: String)] = []
        var used = 0
        for item in items {
            let text = segments.isEmpty ? " " + item.text : " · " + item.text
            if used + text.count > width { break }
            used += text.count
            segments.append((text, item.active ? "1" : "2"))
        }
        return buildLine(segments, selected: false, width: width)
    }

    private func helpItemsNavigation() -> [(text: String, active: Bool)] {
        [
            ("↑↓/jk move", false),
            ("⏎ open", false),
            ("⌫ parent", false),
            ("q quit", false),
            ("[ ] history", false),
            ("/ filter", false),
            ("r recursive", recursiveSearch),
            ("g path", false),
            ("esc clear", false),
        ]
    }

    private func helpItemsActions() -> [(text: String, active: Bool)] {
        [
            ("A add favorite", false),
            ("n new folder", false),
            ("f new file", false),
            ("m rename", false),
            ("t trash", false),
            ("D delete", false),
            ("i info", false),
            ("h hidden", showHidden),
            ("s sort", false),
            ("1-9 favorites", false),
        ]
    }

    private func abbreviate(_ path: String) -> String {
        let home = fileManager.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    private func write(_ text: String) {
        text.withCString { _ = fputs($0, stdout) }
        fflush(stdout)
    }
}

exit(TerminalUI().run())
