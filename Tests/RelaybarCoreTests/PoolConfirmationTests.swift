import Testing

@testable import RelaybarCore

@Suite struct PoolConfirmationTests {
    @Test func combiningOffersT3CodeAndUndoThenClosesByItself() {
        let note = PoolConfirmation.combined(host: nil, t3: true, note: nil, tailscale: false)
        #expect(note.title == "Your accounts are combined on this Mac")
        #expect(note.primary == .openT3)
        #expect(note.secondary == .undo)
        #expect(note.closesAfter == 10)
        #expect(note.warning == nil)
        #expect(note.detail == "New chats in T3 Code now use Claude+.")
    }

    @Test func theDetailOfAPlainConfirmationIsOneShortLine() {
        for t3 in [true, false] {
            let note = PoolConfirmation.combined(host: nil, t3: t3, note: nil, tailscale: false)
            #expect(note.detail.contains("\n") == false)
            #expect(note.detail.count <= 60)
        }
    }

    @Test func combiningWithoutT3CodeKeepsOnlyUndo() {
        let note = PoolConfirmation.combined(host: "homebox", t3: false, note: nil, tailscale: false)
        #expect(note.title == "Your accounts are combined on homebox")
        #expect(note.primary == nil)
        #expect(note.secondary == .undo)
    }

    @Test func aTailscaleOfferStaysUntilTheUserAnswersAndOffersNoUndo() {
        let note = PoolConfirmation.combined(host: "homebox", t3: true, note: nil, tailscale: true)
        #expect(note.primary == .tailscale)
        #expect(note.secondary == .dismiss)
        #expect(note.closesAfter == nil)
        #expect(note.detail.contains("Tailscale on this Mac and on homebox"))
    }

    @Test func aWarningGoesToAnAlertAndDoesNotChangeTheConfirmation() {
        let warning = "Sleep is still on for homebox."
        let note = PoolConfirmation.combined(host: "homebox", t3: true, note: warning, tailscale: false)
        #expect(note.warning == warning)
        #expect(note.detail.contains(warning) == false)
        #expect(note.closesAfter == 10)
    }

    @Test func movingTheHelperHasNoUndoAndAnOfferStaysOpen() {
        let plain = PoolConfirmation.moved(host: "homebox", computers: [], old: nil, pending: false, note: nil, tailscale: false)
        #expect(plain.title == "Your accounts now run on homebox")
        #expect(plain.primary == nil)
        #expect(plain.secondary == nil)
        #expect(plain.closesAfter == 12)
        let offer = PoolConfirmation.moved(host: "homebox", computers: [], old: "oldbox", pending: false, note: nil, tailscale: true)
        #expect(offer.primary == .tailscale)
        #expect(offer.secondary == .dismiss)
        #expect(offer.closesAfter == nil)
    }

    @Test func movingKeepsTheMoveSummary() {
        let note = PoolConfirmation.moved(host: nil, computers: [], old: "oldbox", pending: true, note: "Check this.", tailscale: false)
        #expect(note.title == "Your accounts now run on this Mac")
        #expect(note.detail == PoolMove.doneText(target: nil, computers: [], old: "oldbox", pending: true))
        #expect(note.warning == "Check this.")
    }
}
