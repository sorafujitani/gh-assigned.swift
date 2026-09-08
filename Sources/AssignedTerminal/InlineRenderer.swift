import Foundation

public struct RenderFrame: Sendable {
    public let lines: [String]
    public let cursorColumn: Int
    /// Maximum number of terminal rows available to the inline UI.
    /// The value excludes the shell row above the UI.
    public let maxRows: Int?

    public init(lines: [String], cursorColumn: Int = 0, maxRows: Int? = nil) {
        self.lines = lines
        self.cursorColumn = cursorColumn
        self.maxRows = maxRows
    }
}

/// Generates only cursor/line operations for an inline picker. It never enters
/// the alternate screen or clears the terminal screen.
public struct InlineRenderer: Sendable {
    private var rows = 0
    private var lastMaxRows: Int?
    private var started = false

    public init() {}

    public mutating func start() -> String {
        guard !started else { return "" }
        started = true
        lastMaxRows = nil
        // The line below the shell cursor is the first reserved UI row. Do not
        // save an absolute cursor row: a linefeed at the bottom scrolls it.
        rows = 1
        return "\n"
    }

    public mutating func render(_ frame: RenderFrame) -> String {
        guard started else { return "" }
        let rowLimit = max(frame.maxRows ?? max(rows, frame.lines.count), 1)
        let desiredRows = min(max(frame.lines.count, 1), rowLimit)
        let didShrink = frame.maxRows.map { newMaxRows in
            lastMaxRows.map { oldMaxRows in newMaxRows < oldMaxRows } ?? false
        } ?? false
        lastMaxRows = frame.maxRows
        var previousRows = rows
        var output = ""

        if didShrink {
            // A terminal resize crops rows from the top of the viewport. The
            // old shell anchor is no longer visible, so clear the new viewport
            // and make its first row the new UI anchor before redrawing.
            output += "\u{1b}[1A"
            for index in 0...rowLimit {
                output += "\r\u{1b}[K"
                if index < rowLimit { output += "\u{1b}[1B" }
            }
            output += "\u{1b}[\(rowLimit)A"
            previousRows = 1
            rows = 1
        }

        let visiblePreviousRows = min(previousRows, rowLimit)

        // Re-anchor at the bottom of the currently visible UI. Relative cursor
        // movement remains correct even when a linefeed has scrolled the pane.
        if visiblePreviousRows > 1 {
            output += "\u{1b}[\(visiblePreviousRows - 1)B"
        }
        if desiredRows > visiblePreviousRows {
            output += String(repeating: "\n", count: desiredRows - visiblePreviousRows)
        } else if desiredRows < visiblePreviousRows {
            // Clear rows that disappeared without using linefeed (which could
            // scroll a shortened terminal). Only visible rows are addressed.
            let extraRows = visiblePreviousRows - desiredRows
            if extraRows > 1 { output += "\u{1b}[\(extraRows - 1)A" }
            for index in 0..<extraRows {
                output += "\r\u{1b}[K"
                if index + 1 < extraRows { output += "\u{1b}[1B" }
            }
        }

        let rowsToTop = desiredRows > visiblePreviousRows ? desiredRows : visiblePreviousRows
        if rowsToTop > 1 { output += "\u{1b}[\(rowsToTop - 1)A" }
        rows = desiredRows

        var lines = Array(frame.lines.prefix(desiredRows))
        lines.append(contentsOf: repeatElement("", count: desiredRows - lines.count))
        for (index, line) in lines.enumerated() {
            output += "\r\u{1b}[K\(line)\u{1b}[0m"
            if index + 1 < rows { output += "\n" }
        }

        // Keep the cursor in the input row for the next key and for finish().
        if rows > 1 { output += "\u{1b}[\(rows - 1)A" }
        let cursor = max(0, frame.cursorColumn)
        output += "\r"
        if cursor > 0 { output += "\u{1b}[\(cursor)C" }
        return output
    }

    public mutating func finish() -> String {
        guard started else { return "" }
        var output = ""
        let reservedRows = max(rows, 1)
        for index in 0..<reservedRows {
            output += "\r\u{1b}[K"
            if index + 1 < reservedRows { output += "\u{1b}[1B" }
        }
        // The shell row is exactly one row above the UI anchor. Avoid restoring
        // an absolute saved cursor, which may point at a pre-scroll row.
        output += "\u{1b}[\(reservedRows)A"
        started = false
        rows = 0
        lastMaxRows = nil
        return output
    }
}
