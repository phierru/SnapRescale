/// The lattice quantiser applied *after* the continuous solve (PRD §5).
///
/// Not a degree of freedom. Restricted to 1, 8, 16 and 32 (image-editing
/// models such as Qwen Image want 32) so the pin-respecting snap (PRD §6)
/// stays cheap in aspect error.
public enum Multiple: Int, CaseIterable, Hashable, Sendable, Codable {
    case one = 1
    case eight = 8
    case sixteen = 16
    case thirtyTwo = 32

    public var isIdentity: Bool { self == .one }
}
