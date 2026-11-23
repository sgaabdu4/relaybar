import CoreGraphics
import Testing

@testable import RelaybarCore

@Suite struct DesktopIconLayoutTests {
    private let tile = CGRect(x: 100, y: 100, width: 824, height: 824)

    @Test func theLogoClearsThePillForEveryTagLength() {
        for letters in 1...3 {
            let pill = DesktopIconLayout.pill(in: tile, textWidth: CGFloat(letters) * 0.16 * tile.width)
            let logo = DesktopIconLayout.logo(in: tile, tagged: true)
            #expect(logo.minY > pill.maxY)
            #expect(tile.contains(logo))
        }
    }

    @Test func anIconWithoutATagKeepsTheCentredLogo() {
        let logo = DesktopIconLayout.logo(in: tile, tagged: false)
        #expect(logo == tile.insetBy(dx: tile.width * 0.21, dy: tile.width * 0.21))
    }
}
