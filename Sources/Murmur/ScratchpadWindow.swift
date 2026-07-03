import SwiftUI
import MurmurCore

/// Scratchpad / notes (spec §12): a "brain dump" surface that's always ready
/// for dictation — focus it and dictate as into any other text field.
struct ScratchpadView: View {
    let store: AppStore

    @State private var notes: [Note] = []
    @State private var selection: Note.ID?
    @State private var draft: String = ""

    var body: some View {
        NavigationSplitView {
            List(notes.sorted { $0.createdAt > $1.createdAt }, selection: $selection) { note in
                VStack(alignment: .leading, spacing: 2) {
                    Text(note.text.isEmpty ? "Empty note" : String(note.text.prefix(60)))
                        .lineLimit(1)
                    Text(note.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .tag(note.id)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220)
            .toolbar {
                ToolbarItem {
                    Button {
                        let note = store.addNote(text: "")
                        notes = store.notes
                        selection = note.id
                        draft = ""
                    } label: { Image(systemName: "square.and.pencil") }
                    .help("New note")
                }
            }
        } detail: {
            if let id = selection, let note = notes.first(where: { $0.id == id }) {
                VStack(alignment: .leading, spacing: 8) {
                    TextEditor(text: $draft)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .onChange(of: draft) {
                            store.updateNote(id: note.id, text: draft)
                            notes = store.notes
                        }
                    HStack {
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(draft, forType: .string)
                        }
                        Button("Delete", role: .destructive) {
                            store.deleteNote(id: note.id)
                            notes = store.notes
                            selection = nil
                        }
                        Spacer()
                        Text("Focus here and dictate — hold Fn.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding()
                .onChange(of: selection) {
                    draft = notes.first(where: { $0.id == selection })?.text ?? ""
                }
            } else {
                Text("Select or create a note").foregroundStyle(.secondary)
            }
        }
        .onAppear {
            notes = store.notes
            if selection == nil, let latest = notes.sorted(by: { $0.createdAt > $1.createdAt }).first {
                selection = latest.id
                draft = latest.text
            }
        }
    }
}
