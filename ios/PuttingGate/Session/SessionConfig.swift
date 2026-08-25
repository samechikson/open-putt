import Foundation
import FirebaseFirestore

/// A putter owned by the signed-in user, read from the `putters` Firestore
/// collection. Only the fields the session-setup picker needs are kept. Putters
/// are managed (created/edited) in the web app; iOS only reads them.
struct Putter: Identifiable, Hashable {
    let id: String
    let name: String
    let isActive: Bool
}

extension Putter {
    init(doc: DocumentSnapshot) {
        id = doc.documentID
        name = doc.get("name") as? String ?? ""
        isActive = doc.get("is_active") as? Bool ?? false
    }
}

/// A break-type option for a session. `value` is the backend `putt_break` enum
/// value; `label` is what the picker shows. Mirrors the web app's `BREAK_TYPES`
/// and the backend's `_BREAK_TYPES`.
struct BreakOption: Identifiable, Hashable {
    let value: String
    let label: String
    var id: String { value }

    static let all: [BreakOption] = [
        .init(value: "straight", label: "Straight"),
        .init(value: "leftToRight", label: "Left to right"),
        .init(value: "rightToLeft", label: "Right to left"),
        .init(value: "uphillStraight", label: "Uphill · straight"),
        .init(value: "uphillLeftToRight", label: "Uphill · left to right"),
        .init(value: "uphillRightToLeft", label: "Uphill · right to left"),
        .init(value: "downhillStraight", label: "Downhill · straight"),
        .init(value: "downhillLeftToRight", label: "Downhill · left to right"),
        .init(value: "downhillRightToLeft", label: "Downhill · right to left"),
    ]
}

/// Length options for the picker, in feet.
let sessionLengthOptionsFeet: [Int] = Array(1...40)

/// The metadata a player sets for a session: which putter, the putt length
/// (feet), and the break. Any field may be unset. Applied to the session's
/// Firestore doc by `SessionMetadataService.apply`, where a nil field is written
/// as null to clear it.
struct SessionMetadata: Equatable {
    var putterId: String?
    var lengthFeet: Int?
    var breakType: String?
}
