import Foundation

public struct VNCConnectionStatsSnapshot: Equatable, Sendable {
    public var framesPerSecond: Double
    public var lastFrameAge: TimeInterval?
    public var interfaceName: String
    public var isExpensive: Bool
    public var isConstrained: Bool
    public var reconnectCount: Int
    public var state: String
    public var warning: String?

    public init(
        framesPerSecond: Double = 0,
        lastFrameAge: TimeInterval? = nil,
        interfaceName: String = "Unknown",
        isExpensive: Bool = false,
        isConstrained: Bool = false,
        reconnectCount: Int = 0,
        state: String = "Disconnected",
        warning: String? = nil
    ) {
        self.framesPerSecond = framesPerSecond
        self.lastFrameAge = lastFrameAge
        self.interfaceName = interfaceName
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
        self.reconnectCount = reconnectCount
        self.state = state
        self.warning = warning
    }

    var displayText: String {
        let locale = Locale(identifier: "en_US_POSIX")
        let frameAge = lastFrameAge.map { String(format: "%.1fs", locale: locale, $0) } ?? "—"
        var pathParts = [interfaceName]
        if isConstrained {
            pathParts.append("constrained")
        }
        if isExpensive {
            pathParts.append("expensive")
        }

        var lines = [
            String(format: "%.1f FPS · frame %@", locale: locale, framesPerSecond, frameAge),
            pathParts.joined(separator: " · "),
            "\(state) · reconnects \(reconnectCount)"
        ]
        if let warning, !warning.isEmpty {
            lines.append("⚠︎ \(warning)")
        }
        return lines.joined(separator: "\n")
    }
}
