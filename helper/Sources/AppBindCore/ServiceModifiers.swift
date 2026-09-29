import CoreGraphics

/// Device-dependent left/right bits are not extra logical modifiers.
public enum ServiceModifiers {
    public static func logicalFlags(_ flags: CGEventFlags) -> CGEventFlags {
        // NX device-dependent left/right flags occupy the low 16 bits.
        flags.subtracting(CGEventFlags(rawValue: 0xffff)).subtracting(.maskNonCoalesced)
    }
    public static func names(_ flags: CGEventFlags) -> [String]? {
        let flags = logicalFlags(flags)
        let allowed: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]
        guard flags.subtracting(allowed).isEmpty else { return nil }
        let pairs: [(CGEventFlags, String)] = [(.maskControl, "control"), (.maskAlternate, "option"), (.maskShift, "shift"), (.maskCommand, "command")]
        return pairs.filter { flags.contains($0.0) }.map { $0.1 }.sorted()
    }
}
