import Foundation
import Testing
@testable import AssignedCore
@testable import AssignedTerminal

struct RendererTests {
    @Test func inlineRendererUsesRelativeRowsForShrinkAndFinish() {
        var renderer = InlineRenderer()
        #expect(renderer.start() == "\n")

        _ = renderer.render(RenderFrame(
            lines: ["input", "info", "first", "second"],
            cursorColumn: 4,
            maxRows: 7
        ))
        let resize = renderer.render(RenderFrame(lines: ["input"], cursorColumn: 2, maxRows: 2))
        #expect(resize.hasPrefix("\u{1b}[1A"))
        #expect(resize.contains("\u{1b}[2A"))
        let finish = renderer.finish()

        #expect(!finish.contains("[u"))
        #expect(finish.contains("[1A"))
        #expect(!finish.contains("[4A"))
        #expect(renderer.finish().isEmpty)
    }

    @Test func viewRendererKeepsRowsAndInputCursorInsideTerminalContent() {
        var state = AppState(cached: Snapshot(lists: [[PullRequest(
            repo: "owner/example",
            number: 1,
            title: "a title that is intentionally much longer than the terminal width",
            url: "https://example.invalid/1",
            author: "author",
            isDraft: false,
            baseRef: "main",
            headRef: "feature"
        )], [], []]))
        for character in "012345678901234567890123456789" {
            state.push(character)
        }

        let frame = ViewRenderer.frame(state: &state, terminal: TerminalSize(columns: 20, rows: 8))
        #expect(frame.maxRows == 7)
        #expect(frame.lines.count <= 7)
        #expect(frame.cursorColumn <= 19)
        #expect(frame.cursorColumn == 19)
        for line in frame.lines {
            #expect(terminalDisplayWidth(stripANSI(line)) <= 19)
        }

        state.clearQuery()
        state.setHelp(true)
        let help = ViewRenderer.frame(state: &state, terminal: TerminalSize(columns: 20, rows: 8))
        #expect(help.lines.count <= 7)
        #expect(help.cursorColumn == 0)
        for line in help.lines {
            #expect(terminalDisplayWidth(stripANSI(line)) <= 19)
        }
    }

    private func stripANSI(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var result = ""
        var index = 0
        while index < scalars.count {
            if scalars[index].value == 0x1b {
                index += 1
                if index < scalars.count, scalars[index].value == 0x5b { index += 1 }
                while index < scalars.count && !(0x40...0x7e).contains(scalars[index].value) {
                    index += 1
                }
                if index < scalars.count { index += 1 }
            } else {
                result.unicodeScalars.append(scalars[index])
                index += 1
            }
        }
        return result
    }
}
