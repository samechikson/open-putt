import SwiftUI

/// The "History" tab: a push/pull bias summary, an activity heatmap, and the
/// player's recent sessions. Read-only; data comes from `GET /api/sessions`.
struct HistoryView: View {
    @EnvironmentObject private var history: SessionHistoryStore
    @EnvironmentObject private var config: SessionConfigStore

    private static let weeks = 8
    private static let days = weeks * 7

    var body: some View {
        VStack(spacing: 0) {
            PGHeader("History")
            ScrollView {
                content
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                    .padding(.bottom, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .pgScreenBackground()
        .tint(.pgAccent)
        .task {
            if config.putters.isEmpty { await config.loadPutters() }
            await history.load()
        }
        .refreshable { await history.load() }
    }

    @ViewBuilder
    private var content: some View {
        if history.isLoading && history.sessions.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
        } else if let error = history.loadError, history.sessions.isEmpty {
            infoCard(icon: "exclamationmark.triangle", title: "Couldn't load history", detail: error)
        } else if history.sessions.isEmpty {
            infoCard(icon: "clock", title: "No sessions yet",
                     detail: "Roll putts through your gate and they'll show up here.")
        } else {
            VStack(alignment: .leading, spacing: 18) {
                summaryCard
                activitySection
                recentSection
            }
        }
    }

    // MARK: Summary

    private var summaryCard: some View {
        HStack(alignment: .top, spacing: 14) {
            statBlock(value: biasValue, caption: biasCaption)
            statBlock(value: "\(history.totalPutts)", caption: "total putts")
        }
        .frame(maxWidth: .infinity)
        .padding(18)
        .pgCard()
    }

    private func statBlock(value: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.pgHeading(28, relativeTo: .title))
                .foregroundStyle(Color.pgText)
            Text(caption)
                .font(.pgBody(12))
                .foregroundStyle(Color.pgNeutral700)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var biasValue: String {
        guard let mean = history.meanOffsetMm else { return "—" }
        return String(format: "%.1f mm", abs(mean))
    }

    private var biasCaption: String {
        guard let mean = history.meanOffsetMm else { return "avg bias" }
        // Positive stored offset = golfer's left (a pull); negative = right (push).
        if mean < -0.05 { return "avg push bias" }
        if mean > 0.05 { return "avg pull bias" }
        return "avg bias (centered)"
    }

    // MARK: Activity heatmap

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            PGSectionHeader("Last 8 weeks")
            let counts = dailyCounts()
            let maxCount = max(counts.max() ?? 0, 1)
            HStack(spacing: 4) {
                ForEach(0..<Self.weeks, id: \.self) { col in
                    VStack(spacing: 4) {
                        ForEach(0..<7, id: \.self) { row in
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(cellColor(counts[col * 7 + row], max: maxCount))
                                .aspectRatio(1, contentMode: .fit)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    /// Putt counts per day for the last 8 weeks, oldest first (index 0) to today
    /// (last index), so the grid fills left-to-right, top-to-bottom.
    private func dailyCounts() -> [Int] {
        var counts = [Int](repeating: 0, count: Self.days)
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        for session in history.sessions {
            guard let ts = session.timestamp else { continue }
            let day = cal.startOfDay(for: ts)
            guard let daysAgo = cal.dateComponents([.day], from: day, to: today).day,
                  daysAgo >= 0, daysAgo < Self.days
            else { continue }
            counts[Self.days - 1 - daysAgo] += session.puttCount
        }
        return counts
    }

    private func cellColor(_ count: Int, max: Int) -> Color {
        guard count > 0 else { return .pgNeutral300 }
        let ratio = Double(count) / Double(max)
        switch ratio {
        case ..<0.26: return .pgAccent2_200
        case ..<0.51: return .pgAccent2_300
        case ..<0.76: return .pgAccent2_500
        default: return .pgAccent2_700
        }
    }

    // MARK: Recent sessions

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            PGSectionHeader("Recent sessions")
            let recent = Array(history.sessions.prefix(6))
            VStack(spacing: 0) {
                ForEach(Array(recent.enumerated()), id: \.element.id) { index, session in
                    sessionRow(session)
                    if index < recent.count - 1 { PGDivider() }
                }
            }
            .pgCard()
        }
    }

    private func sessionRow(_ session: SessionRow) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(dateLabel(session.timestamp))
                    .font(.pgBody(15, weight: .semibold))
                    .foregroundStyle(Color.pgText)
                Text(subtitle(session))
                    .font(.pgBody(12))
                    .foregroundStyle(Color.pgNeutral700)
            }
            Spacer()
            Text("\(session.puttCount) putt\(session.puttCount == 1 ? "" : "s")")
                .font(.pgBody(15, weight: .semibold))
                .foregroundStyle(Color.pgText)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: Formatting

    private func dateLabel(_ date: Date?) -> String {
        guard let date else { return "—" }
        let f = DateFormatter()
        f.dateFormat = "MMM d, h:mm a"
        return f.string(from: date)
    }

    private func subtitle(_ session: SessionRow) -> String {
        var parts: [String] = []
        if let feet = session.lengthFeet { parts.append("\(feet) ft") }
        if let label = breakLabel(session.breakType) { parts.append(label) }
        if let name = putterName(session.putterId) { parts.append(name) }
        return parts.isEmpty ? "No details" : parts.joined(separator: " · ")
    }

    private func breakLabel(_ value: String?) -> String? {
        guard let value else { return nil }
        return BreakOption.all.first { $0.value == value }?.label ?? value
    }

    private func putterName(_ id: String?) -> String? {
        guard let id else { return nil }
        return config.putters.first { $0.id == id }?.name
    }

    // MARK: Empty / error state

    private func infoCard(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 34))
                .foregroundStyle(Color.pgAccent2_600)
            Text(title)
                .font(.pgHeading(20, relativeTo: .title3))
                .foregroundStyle(Color.pgText)
            Text(detail)
                .font(.pgBody(13))
                .foregroundStyle(Color.pgNeutral700)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.horizontal, 20)
        .pgCard()
    }
}
