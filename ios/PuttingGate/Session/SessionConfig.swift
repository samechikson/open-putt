import Foundation

/// A putter owned by the signed-in user, from `GET /api/putters`. Only the
/// fields the session-setup picker needs are decoded.
struct Putter: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let isActive: Bool

    enum CodingKeys: String, CodingKey {
        case id, name
        case isActive = "is_active"
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
/// (feet), and the break. Any field may be unset. Serializes to the
/// `PATCH /api/sessions/{id}` body — every key is always present, with `null`
/// clearing a field (matching how the backend applies the update wholesale).
struct SessionMetadata: Equatable {
    var putterId: String?
    var lengthFeet: Int?
    var breakType: String?

    var jsonBody: [String: Any] {
        [
            "putter_id": putterId.map { $0 as Any } ?? NSNull(),
            "length_feet": lengthFeet.map { $0 as Any } ?? NSNull(),
            "break_type": breakType.map { $0 as Any } ?? NSNull(),
        ]
    }
}
