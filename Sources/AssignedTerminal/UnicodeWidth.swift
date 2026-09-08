import Foundation

public enum UnicodeWidth {
    public static func of(_ character: Character) -> Int {
        let scalars = Array(character.unicodeScalars)
        guard !scalars.isEmpty else { return 0 }
        if scalars.contains(where: isWideScalar) { return 2 }
        if scalars.allSatisfy(isZeroWidthScalar) { return 0 }
        return 1
    }

    public static func of(_ text: String) -> Int {
        text.reduce(into: 0) { $0 += of($1) }
    }

    public static func truncate(_ text: String, to width: Int) -> String {
        guard width > 0 else { return "" }
        guard of(text) > width else { return text }
        var result = ""
        let budget = max(0, width - 1)
        for character in text where of(result) + of(character) <= budget {
            result.append(character)
        }
        return result + "…"
    }

    private static func isZeroWidthScalar(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        return (0x0300...0x036f).contains(value)
            || (0x1ab0...0x1aff).contains(value)
            || (0x1dc0...0x1dff).contains(value)
            || (0x20d0...0x20ff).contains(value)
            || (0xfe00...0xfe0f).contains(value)
            || value == 0x200d
            || value == 0x200c
            || value == 0x00ad
    }

    private static func isWideScalar(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        if isZeroWidthScalar(scalar) { return false }
        return (0x1100...0x115f).contains(value)
            || (0x2329...0x232a).contains(value)
            || (0x2e80...0xa4cf).contains(value)
            || (0xac00...0xd7a3).contains(value)
            || (0xf900...0xfaff).contains(value)
            || (0xfe10...0xfe19).contains(value)
            || (0xfe30...0xfe6f).contains(value)
            || (0xff00...0xff60).contains(value)
            || (0xffe0...0xffe6).contains(value)
            || (0x2600...0x27bf).contains(value)
            || (0x1f000...0x1faff).contains(value)
            || (0x1fc00...0x1ffff).contains(value)
            || (0x20000...0x3fffd).contains(value)
    }
}

public func terminalDisplayWidth(_ text: String) -> Int { UnicodeWidth.of(text) }
