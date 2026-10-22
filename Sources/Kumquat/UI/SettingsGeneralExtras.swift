import AppKit
import SwiftUI

/// Settings for the job runner ("Parallel jobs") and history. UserDefaults-backed.
final class JobSettings: ObservableObject {
    static let shared = JobSettings()
    private let d = UserDefaults.standard

    /// 0 = Automatic, otherwise 1...8 jobs at once.
    @Published var parallelJobs: Int { didSet { d.set(parallelJobs, forKey: "parallelJobs") } }
    @Published var keepHistory: Bool { didSet { d.set(keepHistory, forKey: "keepHistory") } }

    static let maxParallelJobs = 8

    private init() {
        parallelJobs = min(max(d.object(forKey: "parallelJobs") as? Int ?? 0, 0), Self.maxParallelJobs)
        keepHistory = d.object(forKey: "keepHistory") as? Bool ?? true
    }

    /// Automatic limit for these inputs: 2 for video/audio (ffmpeg is already multi-threaded),
    /// min(4, cores) for images and documents.
    static func automaticLimit(for urls: [URL]) -> Int {
        let heavy = urls.contains { url in
            guard let g = FileFormat.detect(url)?.group else { return false }
            return g == .video || g == .audio
        }
        return heavy ? 2 : min(4, max(1, ProcessInfo.processInfo.activeProcessorCount))
    }

    /// Effective number of concurrent jobs for `urls`.
    func limit(for urls: [URL]) -> Int {
        let n = parallelJobs == 0 ? Self.automaticLimit(for: urls) : parallelJobs
        return min(max(n, 1), Self.maxParallelJobs)
    }
}

/// Extra rows for the General settings tab: parallel jobs and history.
/// Embed inside the General tab's `Form` (it returns `Section`s).
struct GeneralExtrasSettingsSection: View {
    @ObservedObject var jobs = JobSettings.shared
    @ObservedObject var history = HistoryStore.shared

    var body: some View {
        Section {
            Picker("Parallel jobs", selection: $jobs.parallelJobs) {
                Text("Automatic").tag(0)
                Divider()
                ForEach(1...JobSettings.maxParallelJobs, id: \.self) { n in
                    Text(verbatim: "\(n)").tag(n)
                }
            }
        } footer: {
            Text(parallelHint)
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        Section {
            Toggle("Keep a history of recent operations", isOn: $jobs.keepHistory)
            HStack {
                Text(L("%d of %d entries", history.entries.count, HistoryStore.limit))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Clear History") { history.clear() }
                    .controlSize(.small)
                    .disabled(history.entries.isEmpty)
            }
        } footer: {
            Text("Recent results appear in the menu bar under Recent.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private var parallelHint: String {
        if jobs.parallelJobs == 0 {
            let cores = ProcessInfo.processInfo.activeProcessorCount
            return L("Automatic runs 2 video or audio files at a time and up to %d images or documents.", min(4, cores))
        }
        return Lp("Runs up to %d files at a time.", jobs.parallelJobs)
    }
}
