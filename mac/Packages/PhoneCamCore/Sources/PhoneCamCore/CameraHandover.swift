/// Where this Mac's link to the phone stands (what the menu and the placeholder show).
public enum LinkPhase: Equatable, Sendable {
    case unpaired                 // no trusted phone yet
    case waiting                  // paired, phone not connected
    case standby                  // phone connected, camera off until an app uses Phone Camera
    case connecting
    case live
    case reconnecting             // had live video, lost it, waiting for the phone to come back
    case paused                   // stopped from the Mac
}

/// How this Mac reacts when the phone's camera is in use on another paired Mac. The phone streams to one Mac at a
/// time; a Mac that wants video while another has it gets `state.busy` = that Mac's name and is queued.
public enum CameraHandover {
    /// The other Mac's name from `state.busy`; blank counts as not busy.
    public static func busyName(_ raw: String?) -> String? {
        guard let name = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        return name
    }

    /// Menu note under the phone: the busy message wins over the phone's own note.
    public static func note(busy: String?, phoneNote: String?) -> String? {
        busyName(busy).map { "Camera in use on \($0); switches here when it’s free" } ?? phoneNote
    }

    /// The few words meeting apps show while this Mac waits for video.
    public static func placeholderTitle(_ phase: LinkPhase, busy: String?, saidBye: Bool) -> String {
        switch phase {
        case .unpaired: return "Not paired"
        case .waiting: return saidBye ? "Stopped on phone" : "No phone"
        case .standby, .connecting: return busyName(busy) != nil ? "In use on other Mac" : "Starting…"
        case .live: return "Connected"
        case .reconnecting: return "Reconnecting…"
        case .paused: return "Paused"
        }
    }

    /// The phone said it is not streaming to this Mac. Returns the phase to move to, or nil to stay.
    /// After a handover to another Mac the frames stop first, which may already have flipped this Mac to
    /// `.reconnecting`; with `busy` set that is not a lost connection, so it goes back to waiting for its turn.
    public static func phaseWhenNotStreaming(_ current: LinkPhase, busy: String?, running: Bool, wanted: Bool) -> LinkPhase? {
        let leaves = current == .live || current == .connecting || (busyName(busy) != nil && current == .reconnecting)
        guard leaves else { return nil }
        let next: LinkPhase = !running ? .paused : wanted ? .connecting : .standby
        return next == current ? nil : next
    }

    /// "Use on this Mac" is offered only while another Mac has the camera and the phone is connected here.
    public static func canTakeOver(busy: String?, connected: Bool) -> Bool {
        busyName(busy) != nil && connected
    }
}
