import Foundation
import SwiftData

/// A practice session groups together the putt clips recorded between
/// tapping "Start Session" and "End Session".
@Model
final class Session {
    @Attribute(.unique) var id: UUID
    var name: String
    var startedAt: Date
    var endedAt: Date?

    /// Clips captured during this session. Deleting a session deletes its clips.
    @Relationship(deleteRule: .cascade, inverse: \Clip.session)
    var clips: [Clip]

    init(id: UUID = UUID(), name: String? = nil, startedAt: Date = .now) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = nil
        self.clips = []
        self.name = name ?? Session.defaultName(for: startedAt)
    }

    var isActive: Bool { endedAt == nil }

    /// Clips ordered by capture time (the order they were putt).
    var orderedClips: [Clip] {
        clips.sorted { $0.capturedAt < $1.capturedAt }
    }

    static func defaultName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "Session \(formatter.string(from: date))"
    }
}
