import Foundation

public enum TerminalKey: Equatable, Sendable {
    case character(Character)
    case control(Character)
    case up
    case down
    case left
    case right
    case pageUp
    case pageDown
    case tab
    case backTab
    case enter
    case escape
    case backspace
    case function(Int)
    case interrupted
}

public struct KeyDecoder: Sendable {
    private var pending: [UInt8] = []

    public init() {}

    public var hasPendingEscape: Bool { pending.first == 0x1b }

    public mutating func feed(_ bytes: [UInt8]) -> [TerminalKey] {
        pending.append(contentsOf: bytes)
        var keys: [TerminalKey] = []
        while let key = nextKey() {
            keys.append(key)
        }
        return keys
    }

    public mutating func flushEscape() -> TerminalKey? {
        guard pending.first == 0x1b else { return nil }
        pending.removeFirst()
        return .escape
    }

    private mutating func nextKey() -> TerminalKey? {
        guard let first = pending.first else { return nil }
        if first == 0x1b {
            guard pending.count > 1 else { return nil }
            if pending[1] == 0x5b {
                guard let end = pending.dropFirst(2).firstIndex(where: { (0x40...0x7e).contains($0) }) else {
                    return nil
                }
                let final = pending[end]
                let parameters = String(decoding: pending[2..<end], as: UTF8.self)
                pending.removeFirst(end + 1)
                return csi(parameters: parameters, final: final)
            }
            if pending[1] == 0x4f, pending.count >= 3 {
                let final = pending[2]
                pending.removeFirst(3)
                return final == 0x50 ? .function(1) : nil
            }
            pending.removeFirst()
            return .escape
        }

        if first < 0x80 {
            pending.removeFirst()
            switch first {
            case 0x08, 0x7f: return .backspace
            case 0x09: return .tab
            case 0x0a, 0x0d: return .enter
            case 0x01...0x1a:
                return .control(Character(UnicodeScalar(first + 0x60)))
            default: return .character(Character(UnicodeScalar(first)))
            }
        }

        let length: Int
        switch first {
        case 0xc2...0xdf: length = 2
        case 0xe0...0xef: length = 3
        case 0xf0...0xf4: length = 4
        default:
            pending.removeFirst()
            return .character("�")
        }
        guard pending.count >= length else { return nil }
        let bytes = Array(pending.prefix(length))
        pending.removeFirst(length)
        guard let string = String(bytes: bytes, encoding: .utf8), let character = string.first else {
            return .character("�")
        }
        return .character(character)
    }

    private func csi(parameters: String, final: UInt8) -> TerminalKey {
        switch final {
        case 0x41: return .up
        case 0x42: return .down
        case 0x43: return .right
        case 0x44: return .left
        case 0x5a: return .backTab
        case 0x48: return .character("\u{0001}")
        case 0x46: return .character("\u{0005}")
        case 0x7e:
            switch parameters.split(separator: ";").first.map(String.init) {
            case "5": return .pageUp
            case "6": return .pageDown
            case "11": return .function(1)
            default: return .escape
            }
        default: return .escape
        }
    }
}
