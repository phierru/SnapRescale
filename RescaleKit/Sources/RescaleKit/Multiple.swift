/// The lattice quantiser applied *after* the continuous solve (PRD §5).
///
/// Not a degree of freedom. Restricted to 1, 8 and 16 so that the
/// pin-respecting snap (PRD §6) never costs more than ~0.75 % of aspect error.
public enum Multiple: Int, CaseIterable, Hashable, Sendable, Codable {
    case one = 1
    case eight = 8
    case sixteen = 16

    public var isIdentity: Bool { self == .one }
}
