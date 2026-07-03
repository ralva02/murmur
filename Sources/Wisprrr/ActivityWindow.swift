import SwiftUI
import WisprrrCore

/// Recent activity with View Diff (spec §12): what the cleanup changed.
struct ActivityView: View {
    let store: AppStore
    let dictation: DictationController

    @State private var records: [TranscriptRecord] = []
    @State private var selection: TranscriptRecord.ID?
    @State private var showDiff = true

    var body: some View {
        NavigationSplitView {
            List(records.reversed(), selection: $selection) { record in
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.finalText).lineLimit(2)
                    Text("\(record.appBundleId ?? "unknown app") · \(record.mode) · \(record.createdAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .tag(record.id)
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 300)
        } detail: {
            if let record = records.first(where: { $0.id == selection }) {
                detail(for: record)
            } else {
                Text("Select a transcript").foregroundStyle(.secondary)
            }
        }
        .onAppear { records = store.history }
        .task {
            dictation.onTranscriptRecorded = { record in
                records.append(record)
            }
        }
    }

    @ViewBuilder
    private func detail(for record: TranscriptRecord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("View Diff (raw → final)", isOn: $showDiff)
                .toggleStyle(.switch)

            ScrollView {
                if showDiff {
                    diffText(old: record.rawText, new: record.finalText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(record.finalText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            HStack {
                Button("Copy Final") { copy(record.finalText) }
                Button("Copy Raw") { copy(record.rawText) }
                Spacer()
            }
        }
        .padding()
    }

    private func diffText(old: String, new: String) -> Text {
        WordDiff.diff(old: old, new: new).reduce(Text("")) { acc, segment in
            switch segment {
            case .same(let word):
                acc + Text(word + " ")
            case .added(let word):
                acc + Text(word + " ").foregroundStyle(.green).bold()
            case .removed(let word):
                acc + Text(word + " ").foregroundStyle(.red).strikethrough()
            }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
