/// What happens to the pixels when the target aspect differs from the source (PRD §7).
public enum FitPolicy: String, CaseIterable, Hashable, Sendable, Codable {
    /// Scale to fill the target, discard the overflow. Default.
    case crop
    /// Scale to fit inside the target, fill the remainder with a colour.
    case pad
    /// Distort to the target.
    case stretch
}
