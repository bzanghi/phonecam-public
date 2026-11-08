import XCTest
@testable import PhoneCamCore

/// One phone, several Macs: what this Mac shows and does when the phone's camera is in use on another Mac.
final class CameraHandoverTests: XCTestCase {
    func testBusyNoteNamesTheOtherMacAndWinsOverThePhoneNote() {
        XCTAssertEqual(CameraHandover.note(busy: "Office Studio", phoneNote: "Camera in use by another app"),
                       "Camera in use on Office Studio; switches here when it’s free")
        XCTAssertEqual(CameraHandover.note(busy: nil, phoneNote: "Camera in use by another app"), "Camera in use by another app")
        XCTAssertNil(CameraHandover.note(busy: nil, phoneNote: nil))
    }

    func testBlankBusyIsNotBusy() {
        XCTAssertNil(CameraHandover.busyName(""))
        XCTAssertNil(CameraHandover.busyName("  \n"))
        XCTAssertEqual(CameraHandover.busyName(" Home Studio "), "Home Studio")
        XCTAssertEqual(CameraHandover.note(busy: " ", phoneNote: "x"), "x")
        XCTAssertEqual(CameraHandover.placeholderTitle(.standby, busy: " ", saidBye: false), "Starting…")
        XCTAssertNil(CameraHandover.phaseWhenNotStreaming(.reconnecting, busy: "", running: true, wanted: true))
        XCTAssertFalse(CameraHandover.canTakeOver(busy: "", connected: true))
    }

    func testPlaceholderSaysInUseOnlyWhileWaitingForVideo() {
        XCTAssertEqual(CameraHandover.placeholderTitle(.standby, busy: "A", saidBye: false), "In use on other Mac")
        XCTAssertEqual(CameraHandover.placeholderTitle(.connecting, busy: "A", saidBye: false), "In use on other Mac")
        XCTAssertEqual(CameraHandover.placeholderTitle(.connecting, busy: nil, saidBye: false), "Starting…")
        XCTAssertEqual(CameraHandover.placeholderTitle(.live, busy: "A", saidBye: false), "Connected")
        XCTAssertEqual(CameraHandover.placeholderTitle(.paused, busy: "A", saidBye: false), "Paused")
        XCTAssertEqual(CameraHandover.placeholderTitle(.waiting, busy: nil, saidBye: true), "Stopped on phone")
        XCTAssertEqual(CameraHandover.placeholderTitle(.waiting, busy: nil, saidBye: false), "No phone")
        XCTAssertEqual(CameraHandover.placeholderTitle(.unpaired, busy: nil, saidBye: false), "Not paired")
    }

    func testLiveMacThatLosesTheCameraWaitsForItsTurn() {
        // An app here still uses Phone Camera: keep asking (connecting) rather than claim the phone is gone.
        XCTAssertEqual(CameraHandover.phaseWhenNotStreaming(.live, busy: "Office", running: true, wanted: true), .connecting)
        // Frames stopped first and flipped this Mac to reconnecting; busy says it was a handover, not a lost link.
        XCTAssertEqual(CameraHandover.phaseWhenNotStreaming(.reconnecting, busy: "Office", running: true, wanted: true), .connecting)
        XCTAssertEqual(CameraHandover.phaseWhenNotStreaming(.live, busy: "Office", running: true, wanted: false), .standby)
        XCTAssertEqual(CameraHandover.phaseWhenNotStreaming(.live, busy: "Office", running: false, wanted: true), .paused)
    }

    func testReconnectingWithoutBusyStaysReconnecting() {
        XCTAssertNil(CameraHandover.phaseWhenNotStreaming(.reconnecting, busy: nil, running: true, wanted: true))
    }

    func testPhasesThatDoNotDependOnTheStreamAreLeftAlone() {
        for phase in [LinkPhase.unpaired, .waiting, .standby, .paused] {
            XCTAssertNil(CameraHandover.phaseWhenNotStreaming(phase, busy: "Office", running: true, wanted: true), "\(phase)")
        }
        XCTAssertNil(CameraHandover.phaseWhenNotStreaming(.connecting, busy: "Office", running: true, wanted: true), "already there")
    }

    func testTakeOverNeedsBusyAndAConnectedPhone() {
        XCTAssertTrue(CameraHandover.canTakeOver(busy: "Office", connected: true))
        XCTAssertFalse(CameraHandover.canTakeOver(busy: "Office", connected: false))
        XCTAssertFalse(CameraHandover.canTakeOver(busy: nil, connected: true))
    }

    /// The exact shape the Android app sends (`StreamController.MacLink.sendState`) and the Mac's takeover control.
    func testWireFormat() throws {
        let busy = try JSONDecoder().decode(SignalBody.self, from: Data(#"{"t":"state","streaming":false,"busy":"Office Studio","fps":30}"#.utf8))
        XCTAssertEqual(busy.busy, "Office Studio")
        XCTAssertEqual(busy.streaming, false)
        let free = try JSONDecoder().decode(SignalBody.self, from: Data(#"{"t":"state","streaming":true,"fps":30}"#.utf8))
        XCTAssertNil(free.busy, "phone omits busy when the camera is free or this Mac has it")

        var takeover = SignalBody(t: "control"); takeover.action = "takeover"
        XCTAssertEqual(takeover.encoded(), #"{"action":"takeover","t":"control"}"#)
    }
}
