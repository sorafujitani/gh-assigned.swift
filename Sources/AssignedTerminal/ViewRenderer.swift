import AssignedCore
import Foundation

public enum ViewRenderer {
    private static let cyan = "\u{1b}[36m"
    private static let dim = "\u{1b}[2m"
    private static let red = "\u{1b}[31m"
    private static let bold = "\u{1b}[1m"
    private static let hit = "\u{1b}[48;5;238m\u{1b}[38;5;255m"
    private static let reset = "\u{1b}[0m"
    private static let prompt = "> "
    private static let draftPrefix = "[draft] "

    public static func frame(state: inout AppState, terminal: TerminalSize) -> RenderFrame {
        // Leave the last terminal column unused so rendered rows cannot wrap.
        let width = max(0, max(terminal.columns, 1) - 1)
        let terminalRows = max(terminal.rows, 1)
        // The saved shell cursor occupies the row above the inline UI.
        let availableRows = max(1, terminalRows - 1)
        let headerRows = 2
        let normalLimit = max(1, min(availableRows, terminalRows * 2 / 5))
        let listCapacity = max(1, min(state.filtered.count, max(1, normalLimit - headerRows)))
        let maxRows = state.help
            ? max(1, min(availableRows, HelpText.lines.count + 1))
            : listCapacity
        state.ensureCursorVisible(maxRows: maxRows)

        let input = promptLine(state: state, width: width)
        var lines: [String] = [input.text]
        if state.help {
            let remaining = max(0, availableRows - lines.count)
            lines.append(contentsOf: helpLines(width: width, height: remaining))
        } else {
            if lines.count < availableRows {
                lines.append(infoLine(state: state, width: width))
            }
            if let notice = state.notice, lines.count < availableRows {
                let remaining = max(0, availableRows - lines.count)
                lines.append(contentsOf: wrapNotice(notice, width: width).prefix(remaining))
            }
            let remaining = max(0, availableRows - lines.count)
            let listRows = min(listCapacity, remaining)
            if listRows > 0 {
                lines.append(contentsOf: listLines(state: &state, width: width, maxRows: listRows))
            }
        }
        lines = lines.map { clipAnsi($0, width: width) }
        return RenderFrame(
            lines: lines,
            cursorColumn: state.help ? 0 : min(width, input.cursorColumn),
            maxRows: availableRows
        )
    }

    private static func promptLine(state: AppState, width: Int) -> (text: String, cursorColumn: Int) {
        let modeText = safe(modeLabel(state))
        let mode = UnicodeWidth.truncate(modeText, to: max(0, width - UnicodeWidth.of(prompt)))
        let modeWidth = UnicodeWidth.of(mode)
        let promptText = UnicodeWidth.truncate(prompt, to: max(0, width - modeWidth))
        let fixedWidth = modeWidth + UnicodeWidth.of(promptText)
        let query = horizontalSlice(safe(state.query), to: max(0, width - fixedWidth))
        let cursorColumn = min(width, fixedWidth + UnicodeWidth.of(query))
        let line = styled(mode, .dim) + styled(promptText, .accent) + styled(query, .plain)
        return (line, cursorColumn)
    }

    private static func modeLabel(_ state: AppState) -> String {
        "\(state.scope.label)·\(state.mode.label) "
    }

    private static func infoLine(state: AppState, width: Int) -> String {
        var result = styled("  \(state.filtered.count)/\(state.rows.count)  ", .accent)
        for (index, kind) in ListKind.all.enumerated() {
            if index > 0 { result += styled(" · ", .dim) }
            let label = "\(kind.label.lowercased()) \(state.count(kind))"
            result += styled(label, kind == state.tab ? .boldAccent : .dim)
        }
        switch state.status {
        case let .fetching(showingCache): result += styled(showingCache ? "   cached · fetching…" : "   fetching…", .dim)
        case .fresh: break
        case let .error(error): result += styled("   error: \(safe(error))", .red)
        }
        return clipAnsi(result, width: width)
    }

    private static func listLines(state: inout AppState, width: Int, maxRows: Int) -> [String] {
        let authorWidth = state.tab == .mine ? 0 : state.rows.map { UnicodeWidth.of(safe($0.pr.author)) }.max() ?? 0
        let selectedPosition = state.cursor
        return state.visibleRows(maxRows: maxRows).enumerated().map { visiblePosition, rowIndex in
            let position = (state.filtered.firstIndex(of: rowIndex) ?? visiblePosition)
            let row = state.rows[rowIndex]
            let pr = row.pr
            let highlight = state.highlight(at: position)
            let pointer = position == selectedPosition ? "▌ " : "  "
            let tree = String(repeating: "  ", count: row.depth) + (row.depth > 0 ? "└ " : "")
            let repo = "\(pr.shortRepo)  "
            let author = authorWidth > 0 ? " \(safe(pr.author))\(String(repeating: " ", count: max(0, authorWidth - UnicodeWidth.of(safe(pr.author)))))" : ""
            let checks = " \(checksMark(pr.checks))"
            let review = " \(reviewMark(pr.review))"
            let fixedWidth = UnicodeWidth.of(pointer) + UnicodeWidth.of(tree) + UnicodeWidth.of(repo) + UnicodeWidth.of(author) + UnicodeWidth.of(checks) + UnicodeWidth.of(review)
            let titleWidth = max(0, width - fixedWidth)
            let fullTitle = pr.isDraft ? draftPrefix + safe(pr.title) : safe(pr.title)
            let title = UnicodeWidth.truncate(fullTitle, to: titleWidth)
            let titleHitOffset = pr.isDraft ? Array(draftPrefix).count : 0
            let titleHits = highlight.title.map { $0 + titleHitOffset }.filter { $0 < Array(title).count }
            var line = styled(pointer, .accent) + styled(tree, .accent)
            line += highlighted(repo, highlight.repo, offset: 0, base: .plain)
            line += highlighted(title, titleHits, offset: 0, base: pr.isDraft ? .dim : .plain)
            line += String(repeating: " ", count: max(0, titleWidth - UnicodeWidth.of(title)))
            line += styled(checks, checksStyle(pr.checks))
            line += styled(review, reviewStyle(pr.review))
            line += highlighted(author, highlight.author, offset: 1, base: .dim)
            if position == selectedPosition { line = bold + line + reset }
            return line
        }
    }

    private enum BaseStyle { case plain, dim, accent, boldAccent, red }

    private static func styled(_ text: String, _ style: BaseStyle) -> String {
        let prefix: String
        switch style {
        case .plain: prefix = ""
        case .dim: prefix = dim
        case .accent: prefix = cyan
        case .boldAccent: prefix = bold + cyan
        case .red: prefix = red
        }
        return prefix + text + reset
    }

    private static func highlighted(_ text: String, _ hits: [Int], offset: Int, base: BaseStyle) -> String {
        let hitSet = Set(hits)
        var output = ""
        var active = false
        for (index, character) in safe(text).enumerated() {
            let isHit = hitSet.contains(index - offset)
            if isHit != active {
                output += isHit ? hit : stylePrefix(base)
                active = isHit
            }
            output.append(character)
        }
        if active { output += stylePrefix(base) }
        return output
    }

    private static func stylePrefix(_ style: BaseStyle) -> String {
        switch style {
        case .plain: return reset
        case .dim: return dim
        case .accent: return cyan
        case .boldAccent: return bold + cyan
        case .red: return red
        }
    }

    private static func checksMark(_ checks: Checks) -> String {
        switch checks { case .success: "✓"; case .failure: "✗"; case .pending: "●"; case .none: " " }
    }

    private static func checksStyle(_ checks: Checks) -> BaseStyle {
        switch checks { case .success: .accent; case .failure: .red; case .pending, .none: .dim }
    }

    private static func reviewMark(_ review: Review) -> String {
        switch review { case .approved: "approved"; case .changesRequested: "changes "; case .pending: "review  "; case .none: "        " }
    }

    private static func reviewStyle(_ review: Review) -> BaseStyle {
        switch review { case .approved: .accent; case .changesRequested: .red; case .pending: .plain; case .none: .dim }
    }

    private static func wrapNotice(_ notice: Notice, width: Int) -> [String] {
        guard width > 0 else { return [] }
        let text: String
        let style: BaseStyle
        switch notice { case let .success(value): text = value; style = .accent; case let .failure(value): text = value; style = .red }
        let prefix = "   "
        let prefixWidth = UnicodeWidth.of(prefix)
        guard prefixWidth < width else {
            return [styled(UnicodeWidth.truncate(prefix, to: width), style)]
        }
        return wrap(safe(text), width: width - prefixWidth).map { styled(prefix + $0, style) }
    }

    private static func helpLines(width: Int, height: Int) -> [String] {
        guard height > 0 else { return [] }
        var result = [clipAnsi(styled("  keys", .boldAccent) + styled("   esc to close", .dim), width: width)]
        let shown = min(HelpText.lines.count, max(0, height - 1))
        for index in 0..<shown {
            result.append(clipAnsi(safe(HelpText.lines[index]), width: width))
        }
        if shown < HelpText.lines.count, result.count < height {
            result.append(clipAnsi(styled("   terminal too small, some keys hidden", .dim), width: width))
        }
        return result
    }

    private static func horizontalSlice(_ text: String, to width: Int) -> String {
        guard width > 0 else { return "" }
        guard UnicodeWidth.of(text) > width else { return text }
        guard width > 1 else { return suffix(text, to: width) }
        return "…" + suffix(text, to: width - 1)
    }

    private static func suffix(_ text: String, to width: Int) -> String {
        guard width > 0 else { return "" }
        var result = ""
        var used = 0
        for character in text.reversed() {
            let characterWidth = UnicodeWidth.of(character)
            guard used + characterWidth <= width else { continue }
            result.insert(character, at: result.startIndex)
            used += characterWidth
            if used == width { break }
        }
        return result
    }

    private static func wrap(_ text: String, width: Int) -> [String] {
        guard width > 0 else { return [] }
        var result: [String] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var remaining = String(rawLine)
            if remaining.isEmpty { result.append(""); continue }
            while UnicodeWidth.of(remaining) > width {
                var prefix = ""
                for character in remaining where UnicodeWidth.of(prefix) + UnicodeWidth.of(character) <= width {
                    prefix.append(character)
                }
                if prefix.isEmpty { prefix = String(remaining.first!) }
                result.append(prefix)
                remaining = String(remaining.dropFirst(prefix.count))
            }
            result.append(remaining)
        }
        return result
    }

    private static func clipAnsi(_ text: String, width: Int) -> String {
        // Header text is generated from fixed labels plus sanitized errors; avoid
        // letting a long error wrap into the list area.
        let plain = stripANSI(text)
        guard UnicodeWidth.of(plain) > width else { return text }
        return styled(UnicodeWidth.truncate(plain, to: width), .plain)
    }

    private static func safe(_ text: String) -> String {
        var result = ""
        let scalars = Array(text.unicodeScalars)
        var index = 0
        while index < scalars.count {
            let value = scalars[index].value
            if value == 0x1b {
                index += 1
                if index < scalars.count, scalars[index].value == 0x5b { index += 1 }
                while index < scalars.count && !(0x40...0x7e).contains(scalars[index].value) { index += 1 }
                if index < scalars.count { index += 1 }
            } else if value < 0x20 || value == 0x7f || (0x80...0x9f).contains(value) {
                result.append(" ")
                index += 1
            } else {
                result.unicodeScalars.append(scalars[index])
                index += 1
            }
        }
        return result.replacingOccurrences(of: "\n", with: " ")
    }

    private static func stripANSI(_ text: String) -> String {
        safe(text)
    }
}

public enum HelpText {
    public static let lines = [
        "type              filter the current list",
        "ctrl-f            cycle field: all / repo / title / author",
        "ctrl-t            cycle match: fuzzy / substring / exact",
        "tab / shift-tab   switch list",
        "up / down         move (ctrl-p/n or ctrl-k/j)",
        "pgup / pgdn       move ten rows",
        "ctrl-w / ctrl-u / ctrl-h   delete word / query / character",
        "enter             open the selected PR and exit",
        "O                 open the selected PR and stay",
        "Y                 copy the selected PR URL",
        "N                 copy the selected PR number",
        "ctrl-r            fetch fresh data",
        "F1 / ?             show help",
        "esc / ctrl-c      quit (status 130)",
    ]
}
