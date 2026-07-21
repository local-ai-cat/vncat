import Testing

@testable import RoyalVNCKitUI

struct VNCConnectionStatsSnapshotTests {
    @Test func formatsAllConnectionSignals() {
        let snapshot = VNCConnectionStatsSnapshot(
            framesPerSecond: 24.75,
            lastFrameAge: 1.25,
            interfaceName: "Wi-Fi",
            isExpensive: true,
            isConstrained: true,
            reconnectCount: 2,
            state: "Connected",
            warning: "Weak signal"
        )

        #expect(snapshot.displayText == """
        24.8 FPS · frame 1.2s
        Wi-Fi · constrained · expensive
        Connected · reconnects 2
        ⚠︎ Weak signal
        """)
    }

    @Test func representsMissingFrameWithoutAStallClaim() {
        let snapshot = VNCConnectionStatsSnapshot(
            interfaceName: "Ethernet",
            state: "Connected"
        )

        #expect(snapshot.displayText.contains("frame —"))
        #expect(!snapshot.displayText.contains("stalled"))
    }
}
