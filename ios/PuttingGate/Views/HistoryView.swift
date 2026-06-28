import SwiftUI
import SwiftData

struct HistoryView: View {
    @EnvironmentObject private var coordinator: SessionCoordinator
    @Environment(\.modelContext) private var context
    @Query(sort: \Session.startedAt, order: .reverse) private var sessions: [Session]

    var body: some View {
        NavigationStack {
            Group {
                if sessions.isEmpty {
                    ContentUnavailableView(
                        "No sessions yet",
                        systemImage: "list.bullet",
                        description: Text("Recorded putts will appear here.")
                    )
                } else {
                    List {
                        ForEach(sessions) { session in
                            NavigationLink {
                                ClipListView(session: session)
                            } label: {
                                sessionRow(session)
                            }
                        }
                        .onDelete(perform: deleteSessions)
                    }
                }
            }
            .navigationTitle("History")
        }
    }

    private func sessionRow(_ session: Session) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.name).font(.headline)
            HStack(spacing: 8) {
                Text("\(session.clips.count) putt\(session.clips.count == 1 ? "" : "s")")
                let pending = session.clips.filter { $0.uploadState != .uploaded }.count
                if pending > 0 {
                    Text("\(pending) to upload").foregroundStyle(.orange)
                } else if !session.clips.isEmpty {
                    Text("Uploaded").foregroundStyle(.green)
                }
            }
            .font(.caption)
        }
    }

    private func deleteSessions(at offsets: IndexSet) {
        for index in offsets {
            let session = sessions[index]
            for clip in session.clips {
                try? FileManager.default.removeItem(at: clip.fileURL)
            }
            context.delete(session)
        }
        try? context.save()
    }
}

struct ClipListView: View {
    @EnvironmentObject private var coordinator: SessionCoordinator
    let session: Session

    var body: some View {
        List {
            ForEach(session.orderedClips) { clip in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Putt \(clip.clipIndex + 1)").font(.headline)
                        Text(String(format: "%.1fs", clip.duration))
                            .font(.caption).foregroundStyle(.secondary)
                        if let error = clip.lastUploadError, clip.uploadState == .failed {
                            Text(error).font(.caption2).foregroundStyle(.red)
                        }
                    }
                    Spacer()
                    uploadBadge(clip)
                }
            }
        }
        .navigationTitle(session.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func uploadBadge(_ clip: Clip) -> some View {
        switch clip.uploadState {
        case .uploaded:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .uploading:
            ProgressView()
        case .pending:
            Image(systemName: "clock").foregroundStyle(.secondary)
        case .failed:
            Button {
                coordinator.uploads.upload(clip)
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
        }
    }
}
