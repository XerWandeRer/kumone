#if os(macOS)
import CoreAudio
import Foundation
import Testing
@testable import KumoneCore

// macOS output routing. The CoreAudio enumeration itself needs real hardware
// (and an AirPlay endpoint that may not exist on any given machine), so what
// is pinned here is everything downstream of it: how a device list becomes a
// menu, how a choice survives a relaunch, and what happens when the device the
// user picked walks out of range mid-song.
@Suite struct AudioOutputDeviceTests {

    // MARK: - Fixtures

    private func device(
        _ name: String, uid: String? = nil, id: AudioDeviceID = 1,
        transport: UInt32 = kAudioDeviceTransportTypeUSB
    ) -> AudioOutputDevice {
        AudioOutputDevice(
            id: id, uid: uid ?? "uid:\(name)", name: name, transport: transport)
    }

    private var builtIn: AudioOutputDevice {
        device("Mac mini Speakers", id: 72, transport: kAudioDeviceTransportTypeBuiltIn)
    }
    private var hdmi: AudioOutputDevice {
        device("OF27UT Pro", id: 90, transport: kAudioDeviceTransportTypeHDMI)
    }
    private var airPlay: AudioOutputDevice {
        device("客厅 HomePod", id: 200, transport: kAudioDeviceTransportTypeAirPlay)
    }

    // MARK: - Menu order

    @Test func airPlayEndpointsSortLastSoTheListDoesNotShiftUnderTheCursor() {
        let ordered = AudioOutputDevices.ordered([airPlay, hdmi, builtIn])
        #expect(ordered.map(\.name) == ["Mac mini Speakers", "OF27UT Pro", "客厅 HomePod"])
    }

    @Test func bluetoothSitsBetweenWiredAndAirPlay() {
        let bt = device("AirPods Pro", id: 5, transport: kAudioDeviceTransportTypeBluetooth)
        let ordered = AudioOutputDevices.ordered([airPlay, bt, hdmi, builtIn])
        #expect(ordered.map(\.name)
            == ["Mac mini Speakers", "OF27UT Pro", "AirPods Pro", "客厅 HomePod"])
    }

    @Test func sameRankSortsByNameAndTheListIsDedupedByUID() {
        let a = device("Zeta", uid: "u1", id: 1)
        let b = device("Alpha", uid: "u2", id: 2)
        // Same UID surfacing twice (a device seen through two enumerations)
        // must not produce two menu rows.
        let duplicate = device("Zeta", uid: "u1", id: 3)
        let ordered = AudioOutputDevices.ordered([a, b, duplicate])
        #expect(ordered.map(\.name) == ["Alpha", "Zeta"])
    }

    @Test func airPlayDevicesAreLabelledAndGetTheAirPlayGlyph() {
        #expect(airPlay.isAirPlay)
        #expect(airPlay.symbolName == "airplayaudio")
        #expect(!builtIn.isAirPlay)
        #expect(builtIn.symbolName == "speaker.wave.2")
    }

    // MARK: - Persistence round-trip

    @Test func selectionRoundTripsThroughItsStoredString() {
        let chosen = AudioOutputSelection.device(uid: "AirPlay:0xdeadbeef")
        #expect(AudioOutputSelection(storageValue: chosen.storageValue) == chosen)

        let followSystem = AudioOutputSelection.systemDefault
        #expect(followSystem.storageValue == "")
        #expect(AudioOutputSelection(storageValue: followSystem.storageValue) == followSystem)
    }

    @Test func aMissingOrEmptyStoredValueMeansFollowTheSystem() {
        #expect(AudioOutputSelection(storageValue: nil) == .systemDefault)
        #expect(AudioOutputSelection(storageValue: "") == .systemDefault)
    }

    // MARK: - Fallback state machine

    @Test func pickingAPresentDeviceRoutesToIt() {
        var state = AudioOutputSelectionState()
        let outcome = state.select(.device(uid: airPlay.uid), from: [builtIn, airPlay])
        #expect(outcome == .use(airPlay))
        #expect(state.selection == .device(uid: airPlay.uid))
    }

    @Test func theDeviceWalkingAwayMidSongFallsBackToDefaultAndNamesIt() {
        var state = AudioOutputSelectionState()
        _ = state.select(.device(uid: airPlay.uid), from: [builtIn, airPlay])

        // The HomePod goes out of range: CoreAudio drops it from the list.
        let outcome = state.reconcile(with: [builtIn])
        #expect(outcome == .lost(name: "客厅 HomePod"))
        #expect(state.selection == .systemDefault)
    }

    @Test func theLossIsAnnouncedOnceAndNotOnEveryLaterDeviceChange() {
        var state = AudioOutputSelectionState()
        _ = state.select(.device(uid: airPlay.uid), from: [builtIn, airPlay])
        _ = state.reconcile(with: [builtIn])

        // Plugging headphones in afterwards is not another loss.
        #expect(state.reconcile(with: [builtIn, hdmi]) == .followDefault)
    }

    @Test func unrelatedDeviceChangesLeaveALivingSelectionAlone() {
        var state = AudioOutputSelectionState()
        _ = state.select(.device(uid: airPlay.uid), from: [builtIn, airPlay])
        #expect(state.reconcile(with: [builtIn, hdmi, airPlay]) == .use(airPlay))
        #expect(state.selection == .device(uid: airPlay.uid))
    }

    @Test func restoringAChoiceWhoseDeviceIsNotHereYetIsSilent() {
        // Launching with the HomePod off is not an event worth a toast; it is
        // just the default route.
        var state = AudioOutputSelectionState()
        let outcome = state.restore(.device(uid: airPlay.uid), from: [builtIn])
        #expect(outcome == .followDefault)
        #expect(state.selection == .systemDefault)
    }

    @Test func restoringAChoiceWhoseDeviceIsPresentRoutesStraightToIt() {
        var state = AudioOutputSelectionState()
        #expect(state.restore(.device(uid: airPlay.uid), from: [builtIn, airPlay])
            == .use(airPlay))
    }

    @Test func choosingSystemDefaultForgetsTheRememberedDevice() {
        var state = AudioOutputSelectionState()
        _ = state.select(.device(uid: airPlay.uid), from: [builtIn, airPlay])
        #expect(state.select(.systemDefault, from: [builtIn, airPlay]) == .followDefault)
        // Nothing left to lose, so the endpoint disappearing is silent.
        #expect(state.reconcile(with: [builtIn]) == .followDefault)
    }
}
#endif
