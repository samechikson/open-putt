import SwiftUI

/// Pushed from the History tab: the individual putts of one session, with the
/// ability to remove a stray one. Putts are read from Firestore; a delete removes
/// the putt's Firestore doc (keeping the session's putt_count in sync) and the
/// History list is reloaded so its counts stay in sync.
///
/// Laid out as an inset-grouped `List` (styled to the "Organic" palette) so each
/// putt supports the standard swipe-left-to-delete gesture.
struct SessionDetailView: View {
    let session: SessionRow

    @EnvironmentObject private var service: SessionMetadataService
    @EnvironmentObject private var config: SessionConfigStore
    @EnvironmentObject private var history: SessionHistoryStore
    @Environment(\.dismiss) private var dismiss

    @State private var putts: [SessionPutt] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var deleteError: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            list
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .pgScreenBackground()
        .tint(.pgAccent)
        .navigationBarHidden(true)
        .task { await load() }
        .alert(
            "Couldn't delete putt",
            isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deleteError ?? "")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.pgText)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Text("Session")
                .font(.pgHeading(26, relativeTo: .title))
                .foregroundStyle(Color.pgText)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    // MARK: List

    private var list: some View {
        List {
            Section {
                summaryRow.listRowBackground(Color.pgCardBg)
            }
            puttsSection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .listSectionSpacing(18)
    }

    private var summaryRow: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(dateLabel(session.timestamp))
                .font(.pgBody(16, weight: .semibold))
                .foregroundStyle(Color.pgText)
            Text(subtitle)
                .font(.pgBody(13))
                .foregroundStyle(Color.pgNeutral700)
            HStack(spacing: 8) {
                Text("\(putts.count) putt\(putts.count == 1 ? "" : "s")")
                if let bias = biasSummary {
                    Text("·").foregroundStyle(Color.pgNeutral400)
                    Text(bias)
                }
            }
            .font(.pgBody(13))
            .foregroundStyle(Color.pgNeutral700)
            .padding(.top, 2)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var puttsSection: some View {
        if isLoading && putts.isEmpty {
            Section {
                HStack { Spacer(); ProgressView(); Spacer() }
                    .padding(.vertical, 8)
                    .listRowBackground(Color.pgCardBg)
            }
        } else if let loadError, putts.isEmpty {
            Section {
                infoRow(icon: "exclamationmark.triangle", title: "Couldn't load putts", detail: loadError)
                    .listRowBackground(Color.pgCardBg)
            }
        } else if putts.isEmpty {
            Section {
                infoRow(icon: "circle.slash", title: "No putts",
                        detail: "This session doesn't have any putts.")
                    .listRowBackground(Color.pgCardBg)
            }
        } else {
            Section {
                ForEach(putts) { putt in
                    puttRow(putt)
                        .listRowBackground(Color.pgCardBg)
                        .listRowSeparatorTint(Color.pgDivider)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                Task { await deletePutt(putt) }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                }
            } header: {
                PGSectionHeader("Putts")
            }
        }
    }

    private func puttRow(_ putt: SessionPutt) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(putt.golferSideLabel) · \(putt.magnitudeMm, specifier: "%.1f") mm")
                    .font(.pgBody(15, weight: .semibold))
                    .foregroundStyle(Color.pgText)
                if let speed = putt.speedMps {
                    Text("\(speed, specifier: "%.2f") m/s")
                        .font(.pgBody(12))
                        .foregroundStyle(Color.pgNeutral700)
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    // MARK: Data

    private func load() async {
        isLoading = true
        loadError = nil
        do {
            putts = try await service.fetchPutts(sessionId: session.id)
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    private func deletePutt(_ putt: SessionPutt) async {
        do {
            try await service.deletePutt(sessionId: session.id, puttIndex: putt.puttIndex)
            putts.removeAll { $0.puttIndex == putt.puttIndex }
            // Keep the History tab's counts / bias summary in sync.
            await history.load()
        } catch {
            deleteError = error.localizedDescription
        }
    }

    // MARK: Formatting

    private func dateLabel(_ date: Date?) -> String {
        guard let date else { return "—" }
        let f = DateFormatter()
        f.dateFormat = "MMM d, h:mm a"
        return f.string(from: date)
    }

    private var subtitle: String {
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

    /// Average bias across the loaded putts, worded from the golfer's view.
    /// Mirrors the History summary: a left miss is a pull, a right miss a push.
    private var biasSummary: String? {
        let offsets = putts.compactMap { $0.offsetMm }
        guard !offsets.isEmpty else { return nil }
        let mean = offsets.reduce(0, +) / Double(offsets.count)
        // Stored positive = the golfer's left (a pull); negative = right (a push).
        let word: String
        if mean > 0.05 { word = "pull" }
        else if mean < -0.05 { word = "push" }
        else { return "centered" }
        return String(format: "%.1f mm %@", abs(mean), word)
    }

    // MARK: Empty / error state

    private func infoRow(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 30))
                .foregroundStyle(Color.pgAccent2_600)
            Text(title)
                .font(.pgHeading(18, relativeTo: .title3))
                .foregroundStyle(Color.pgText)
            Text(detail)
                .font(.pgBody(13))
                .foregroundStyle(Color.pgNeutral700)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}
