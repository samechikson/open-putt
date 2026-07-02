import Foundation

/// The slope + break direction of a putt, combined into one selectable value.
/// (Slope: flat / uphill / downhill; direction: straight / left-to-right /
/// right-to-left.)
enum PuttBreak: String, CaseIterable, Identifiable, Codable {
    case straight
    case leftToRight
    case rightToLeft
    case uphillStraight
    case uphillLeftToRight
    case uphillRightToLeft
    case downhillStraight
    case downhillLeftToRight
    case downhillRightToLeft

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .straight: return "Flat / straight"
        case .leftToRight: return "Left-to-right"
        case .rightToLeft: return "Right-to-left"
        case .uphillStraight: return "Uphill / straight"
        case .uphillLeftToRight: return "Uphill / left-to-right"
        case .uphillRightToLeft: return "Uphill / right-to-left"
        case .downhillStraight: return "Downhill / straight"
        case .downhillLeftToRight: return "Downhill / left-to-right"
        case .downhillRightToLeft: return "Downhill / right-to-left"
        }
    }
}
