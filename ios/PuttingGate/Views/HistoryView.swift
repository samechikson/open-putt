import SwiftUI
import SwiftData

struct HistoryView: View {
    @EnvironmentObject private var coordinator: RecordingCoordinator
    @Environment(\.modelContext) private var context
    @Query(sort: \Recording.capturedAt, order: .reverse) private var recordings: [Recording]

    var body: some View {
        NavigationStack {
            Group {
                if recordings.isEmpty {
                    ContentUnavailableView(
                        "No recordings yet",
                        systemImage: "video",
                        description: Text("Recorded videos will appear here.")
                    )
                } else {
                    List {
                        ForEach(recordings) { recording in
                            recordingRow(recording)
                        }
                        .onDelete(perform: deleteRecordings)
                    }
                }
            }
            .navigationTitle("History")
        }
    }

    private func recordingRow(_ recording: Recording) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(recording.capturedAt, format: .dateTime.month().day().hour().minute())
                    .font(.headline)
                Text(String(format: "%.1fs", recording.duration))
                    .font(.caption).foregroundStyle(.secondary)
                if let error = recording.lastUploadError, recording.uploadState == .failed {
                    Text(error).font(.caption2).foregroundStyle(.red)
                }
            }
            Spacer()
            uploadBadge(recording)
        }
    }

    @ViewBuilder
    private func uploadBadge(_ recording: Recording) -> some View {
        switch recording.uploadState {
        case .uploaded:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .uploading:
            ProgressView()
        case .pending:
            Image(systemName: "clock").foregroundStyle(.secondary)
        case .failed:
            Button {
                coordinator.uploads.upload(recording)
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
        }
    }

    private func deleteRecordings(at offsets: IndexSet) {
        for index in offsets {
            let recording = recordings[index]
            try? FileManager.default.removeItem(at: recording.fileURL)
            context.delete(recording)
        }
        try? context.save()
    }
}
