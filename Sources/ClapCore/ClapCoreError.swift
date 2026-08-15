import Foundation

/// Errors surfaced by ClapCore. Never contains clipboard content.
public enum ClapCoreError: Error, Sendable, CustomStringConvertible {
    /// SQLite-level failure with the raw result code and error message.
    case database(code: Int32, message: String)
    /// Invalid or rejected regular expression pattern.
    case invalidPattern(String)
    /// Filesystem / IO failure (paths only, never content).
    case io(String)

    public var description: String {
        switch self {
        case .database(let code, let message):
            return "database error (code \(code)): \(message)"
        case .invalidPattern(let detail):
            return "invalid regex pattern: \(detail)"
        case .io(let detail):
            return "io error: \(detail)"
        }
    }
}
