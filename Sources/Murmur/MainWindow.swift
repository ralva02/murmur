import SwiftUI
import MurmurCore

enum MainSection: String, CaseIterable, Identifiable {
    case home = "Home"
    case dictionary = "Dictionary"
    case snippets = "Snippets"
    case style = "Style"
    case scratchpad = "Scratchpad"
    case settings = "Settings"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .home: "square.grid.2x2"
        case .dictionary: "character.book.closed"
        case .snippets: "scissors"
        case .style: "textformat"
        case .scratchpad: "note.text"
        case .settings: "gearshape"
        }
    }
}

@MainActor @Observable
final class MainModel {
    var section: MainSection = .home
    var showOnboarding: Bool
    /// Re-arms the hotkey listener after permission grants (set by AppDelegate).
    var onPermissionsChanged: () -> Void = {}
    let store: AppStore
    let settingsModel: SettingsModel
    let onBindingsChanged: () -> Void
    weak var dictation: DictationController?

    init(store: AppStore, dictation: DictationController?, onBindingsChanged: @escaping () -> Void) {
        self.store = store
        self.dictation = dictation
        self.settingsModel = SettingsModel(store: store)
        self.onBindingsChanged = onBindingsChanged
        self.showOnboarding = !store.settings.onboardingCompleted
            || CommandLine.arguments.contains("--onboarding")
    }
}

struct MainView: View {
    @Bindable var model: MainModel

    var body: some View {
        Group {
            if model.showOnboarding {
                OnboardingView(model: model)
            } else {
                mainChrome
            }
        }
        .background(Theme.canvas)
        .frame(minWidth: 940, minHeight: 620)
    }

    private var mainChrome: some View {
        HStack(spacing: 0) {
            Sidebar(model: model)
                .frame(width: 208)
            contentPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.card)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Theme.cardBorder, lineWidth: 1))
                .padding(.vertical, 14)
                .padding(.trailing, 14)
        }
    }

    @ViewBuilder
    private var contentPane: some View {
        switch model.section {
        case .home: HomePage(model: model)
        case .dictionary: DictionaryPage(model: model.settingsModel)
        case .snippets: SnippetsPage(model: model.settingsModel)
        case .style: StylePage(model: model.settingsModel)
        case .scratchpad: ScratchpadPage(store: model.store)
        case .settings: SettingsPage(
            model: model.settingsModel,
            onBindingsChanged: model.onBindingsChanged,
            onRunSetup: { model.showOnboarding = true })
        }
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    @Bindable var model: MainModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(nsImage: MurmurIcon.idle)
                Text("Murmur")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.ink)
            }
            .padding(.horizontal, 12)
            .padding(.top, 18)
            .padding(.bottom, 20)

            ForEach([MainSection.home, .dictionary, .snippets, .style, .scratchpad]) { section in
                row(section)
            }

            Spacer()

            if !Permissions.allGranted {
                PermissionNudge()
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
            }

            row(.settings)
                .padding(.bottom, 14)
        }
        .padding(.horizontal, 10)
    }

    private func row(_ section: MainSection) -> some View {
        Button {
            model.section = section
        } label: {
            HStack(spacing: 10) {
                Image(systemName: section.icon)
                    .font(.system(size: 14))
                    .frame(width: 18)
                Text(section.rawValue)
                    .font(.system(size: 14, weight: .medium))
                Spacer()
            }
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(model.section == section ? Theme.sidebarSelection : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct PermissionNudge: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Permissions needed", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.ink)
            Text("Dictation needs Microphone, Accessibility and Input Monitoring.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.inkSecondary)
            Button("Open System Settings") {
                Permissions.openAccessibilitySettings()
            }
            .buttonStyle(.link)
            .font(.system(size: 11, weight: .medium))
        }
        .padding(12)
        .background(Theme.violet.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - Home

private struct HomePage: View {
    @Bindable var model: MainModel
    @State private var records: [TranscriptRecord] = []
    @State private var expanded: Set<UUID> = []

    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Welcome back, Raul")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Theme.ink)

                    HeroBanner(
                        headline: "Speak it. Murmur types it.",
                        emphasis: "Murmur",
                        subtitle: "Hold Fn and talk — polished text lands wherever your cursor is. Double-tap Fn for hands-free.") {
                        EmptyView()
                    }

                    activityList
                }

                statsColumn
                    .frame(width: 210)
            }
            .padding(28)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { records = model.store.history }
        .task {
            model.dictation?.onTranscriptRecorded = { record in
                records.append(record)
            }
        }
    }

    // Grouped-by-day recent activity, Flow style.
    private var activityList: some View {
        let groups = Dictionary(grouping: records.reversed()) {
            Calendar.current.startOfDay(for: $0.createdAt)
        }
        .sorted { $0.key > $1.key }

        return VStack(alignment: .leading, spacing: 18) {
            if groups.isEmpty {
                emptyActivity
            }
            ForEach(groups, id: \.key) { day, dayRecords in
                VStack(alignment: .leading, spacing: 8) {
                    Text(day.formatted(date: .long, time: .omitted).uppercased())
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.inkTertiary)
                        .kerning(0.8)
                    VStack(spacing: 0) {
                        ForEach(dayRecords) { record in
                            activityRow(record)
                            if record.id != dayRecords.last?.id {
                                Rectangle().fill(Theme.rowSeparator).frame(height: 1)
                            }
                        }
                    }
                    .card()
                }
            }
        }
    }

    private var emptyActivity: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Nothing dictated yet")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.ink)
            Text("Click into any text field, hold Fn, and speak. Your transcripts will appear here.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.inkSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .card()
    }

    private func activityRow(_ record: TranscriptRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                if expanded.contains(record.id) { expanded.remove(record.id) }
                else { expanded.insert(record.id) }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text(record.createdAt.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.inkTertiary)
                        .frame(width: 64, alignment: .leading)
                    Text(record.finalText.isEmpty ? "—" : record.finalText)
                        .font(.system(size: 13.5))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(expanded.contains(record.id) ? nil : 2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded.contains(record.id) {
                diffView(record)
                    .padding(.leading, 78)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func diffView(_ record: TranscriptRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("WHAT CHANGED")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.inkTertiary)
                .kerning(0.8)
            WordDiff.diff(old: record.rawText, new: record.finalText)
                .reduce(Text("")) { acc, segment in
                    switch segment {
                    case .same(let word): acc + Text(word + " ")
                    case .added(let word): acc + Text(word + " ").foregroundStyle(.teal).bold()
                    case .removed(let word): acc + Text(word + " ").foregroundStyle(Theme.inkTertiary).strikethrough()
                    }
                }
                .font(.system(size: 12.5))
                .textSelection(.enabled)
            HStack {
                Button("Copy final") { copyToPasteboard(record.finalText) }
                    .buttonStyle(GhostButtonStyle())
                Button("Copy raw") { copyToPasteboard(record.rawText) }
                    .buttonStyle(GhostButtonStyle())
            }
        }
        .padding(.bottom, 4)
    }

    private var statsColumn: some View {
        let totalWords = records.reduce(0) { $0 + $1.finalText.split(separator: " ").count }
        let week = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        let weekWords = records.filter { $0.createdAt > week }
            .reduce(0) { $0 + $1.finalText.split(separator: " ").count }

        return VStack(alignment: .leading, spacing: 18) {
            stat(value: totalWords.formatted(), label: "total words")
            stat(value: records.count.formatted(), label: "dictations")
            stat(value: weekWords.formatted(), label: "words this week")
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .padding(.top, 42)
    }

    private func stat(value: String, label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(value)
                .font(Theme.serif(26, .semibold))
                .foregroundStyle(Theme.ink)
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(Theme.inkSecondary)
        }
    }
}

// MARK: - Dictionary

private struct DictionaryPage: View {
    @Bindable var model: SettingsModel
    @State private var newTerm = ""
    @FocusState private var addFocused: Bool

    var body: some View {
        Page(title: "Dictionary") {
            Button("Add new") { addFocused = true }
                .buttonStyle(PrimaryPillButtonStyle())
        } content: {
            HeroBanner(
                headline: "Murmur spells the way you do.",
                emphasis: "you",
                subtitle: "Names, jargon, product terms — add them once and they're spelled right everywhere. Corrections you make are learned automatically.") {
                HStack(spacing: 8) {
                    ForEach(["Anaïs", "kubectl", "Wisprrr"], id: \.self) { chip in
                        Text(chip)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.white.opacity(0.16))
                            .clipShape(Capsule())
                    }
                }
                .padding(.top, 6)
            }

            Toggle("Learn spellings from my corrections automatically", isOn: $model.settings.autoAddDictionary)
                .toggleStyle(.switch)
                .font(.system(size: 13))
                .foregroundStyle(Theme.ink)

            VStack(spacing: 0) {
                ForEach(model.dictionary.indices, id: \.self) { i in
                    HStack {
                        Text(model.dictionary[i].term)
                            .font(.system(size: 13.5))
                            .foregroundStyle(Theme.ink)
                        Spacer()
                        Button {
                            model.dictionary.remove(at: i)
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.inkTertiary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)
                    Rectangle().fill(Theme.rowSeparator).frame(height: 1)
                }
                HStack {
                    TextField("Add a term…", text: $newTerm)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13.5))
                        .focused($addFocused)
                        .onSubmit(add)
                    Button("Add", action: add)
                        .buttonStyle(GhostButtonStyle())
                        .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .card()
        }
    }

    private func add() {
        let term = newTerm.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return }
        model.dictionary.append(DictionaryEntry(term: term))
        newTerm = ""
    }
}

// MARK: - Snippets

private struct SnippetsPage: View {
    @Bindable var model: SettingsModel
    @State private var newTrigger = ""
    @State private var newBody = ""
    @FocusState private var addFocused: Bool

    var body: some View {
        Page(title: "Snippets") {
            Button("Add new") { addFocused = true }
                .buttonStyle(PrimaryPillButtonStyle())
        } content: {
            HeroBanner(
                headline: "The stuff you shouldn't have to re-type.",
                emphasis: "you",
                subtitle: "Save text you use often — an email, a link, a template — then say the trigger phrase to drop it in instantly.") {
                HStack(spacing: 8) {
                    Text("“my email address”")
                        .font(.system(size: 12, weight: .medium)).italic()
                    Image(systemName: "arrow.right").font(.system(size: 10))
                    Text("ralvahi@proton.me").font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.white.opacity(0.14))
                .clipShape(Capsule())
                .padding(.top, 6)
            }

            VStack(spacing: 0) {
                ForEach(model.snippets.indices, id: \.self) { i in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(model.snippets[i].triggerPhrase)
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundStyle(Theme.ink)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.inkTertiary)
                        Text(model.snippets[i].body)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.inkSecondary)
                            .lineLimit(1)
                        Spacer()
                        Button {
                            model.snippets.remove(at: i)
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.inkTertiary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)
                    Rectangle().fill(Theme.rowSeparator).frame(height: 1)
                }
                VStack(spacing: 8) {
                    TextField("Trigger phrase (max 60 characters)", text: $newTrigger)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13.5))
                        .focused($addFocused)
                    Rectangle().fill(Theme.rowSeparator).frame(height: 1)
                    HStack(alignment: .bottom) {
                        TextField("Text to insert", text: $newBody, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13.5))
                            .lineLimit(1...4)
                        Button("Add", action: add)
                            .buttonStyle(GhostButtonStyle())
                            .disabled(Snippet(triggerPhrase: newTrigger, body: newBody) == nil || newBody.isEmpty)
                    }
                }
                .padding(16)
            }
            .card()
        }
    }

    private func add() {
        guard let snippet = Snippet(triggerPhrase: newTrigger, body: newBody), !newBody.isEmpty else { return }
        model.snippets.append(snippet)
        newTrigger = ""
        newBody = ""
    }
}

// MARK: - Style

private struct StylePage: View {
    @Bindable var model: SettingsModel
    @State private var tab = 0

    private var categories: [AppCategory] { AppCategory.allCases }

    var body: some View {
        Page(title: "Style") {
            EmptyView()
        } content: {
            UnderlineTabs(
                titles: categories.map { $0.rawValue.capitalized },
                selection: $tab)

            if let index = model.styles.firstIndex(where: { $0.appCategory == categories[tab] }) {
                styleEditor(index: index)
            }

            Text("Styles shape tone only — your words stay yours. English, desktop.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.inkTertiary)
        }
    }

    private func styleEditor(index: Int) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(model.styles[index].tone.isEmpty ? "Neutral" : model.styles[index].tone)
                    .font(Theme.serif(24))
                    .foregroundStyle(Theme.ink)
                Text("TONE FOR \(categories[tab].rawValue.uppercased()) APPS")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.inkTertiary)
                    .kerning(0.8)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Tone")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.inkSecondary)
                TextField("e.g. warm and professional", text: $model.styles[index].tone)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5))
                    .padding(12)
                    .background(Theme.canvas.opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Writing sample — the strongest tone signal")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.inkSecondary)
                TextField("Paste a few sentences you actually wrote in this kind of app…",
                          text: $model.styles[index].sample, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5))
                    .lineLimit(3...8)
                    .padding(12)
                    .background(Theme.canvas.opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

// MARK: - Scratchpad

private struct ScratchpadPage: View {
    let store: AppStore
    @State private var notes: [Note] = []
    @State private var selection: Note.ID?
    @State private var draft: String = ""

    var body: some View {
        Page(title: "Scratchpad") {
            Button("New note") {
                let note = store.addNote(text: "")
                notes = store.notes
                selection = note.id
                draft = ""
            }
            .buttonStyle(PrimaryPillButtonStyle())
        } content: {
            if notes.isEmpty {
                HeroBanner(
                    headline: "For quick thoughts you want to come back to",
                    emphasis: nil,
                    subtitle: "Brain-dump an idea, draft a message, keep a to-do — focus a note and dictate straight into it.") {
                    EmptyView()
                }
            } else {
                HStack(alignment: .top, spacing: 16) {
                    VStack(spacing: 0) {
                        ForEach(notes.sorted { $0.createdAt > $1.createdAt }) { note in
                            noteRow(note)
                            Rectangle().fill(Theme.rowSeparator).frame(height: 1)
                        }
                    }
                    .frame(width: 220)
                    .card()

                    editor
                }
            }
        }
        .onAppear {
            notes = store.notes
            if selection == nil, let latest = notes.max(by: { $0.createdAt < $1.createdAt }) {
                selection = latest.id
                draft = latest.text
            }
        }
    }

    private func noteRow(_ note: Note) -> some View {
        Button {
            selection = note.id
            draft = note.text
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(note.text.isEmpty ? "Empty note" : String(note.text.prefix(48)))
                    .font(.system(size: 13, weight: selection == note.id ? .semibold : .regular))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Text(note.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.inkTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(selection == note.id ? Theme.sidebarSelection.opacity(0.5) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var editor: some View {
        if let id = selection {
            VStack(alignment: .leading, spacing: 10) {
                TextEditor(text: $draft)
                    .font(.system(size: 13.5))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 260)
                    .onChange(of: draft) {
                        store.updateNote(id: id, text: draft)
                        notes = store.notes
                    }
                HStack {
                    Button("Copy") { copyToPasteboard(draft) }
                        .buttonStyle(GhostButtonStyle())
                    Button("Delete") {
                        store.deleteNote(id: id)
                        notes = store.notes
                        selection = nil
                        draft = ""
                    }
                    .buttonStyle(GhostButtonStyle())
                    Spacer()
                    Text("Focus here and hold Fn to dictate")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.inkTertiary)
                }
            }
            .padding(16)
            .card()
        } else {
            Text("Select or create a note")
                .font(.system(size: 13))
                .foregroundStyle(Theme.inkSecondary)
                .frame(maxWidth: .infinity, minHeight: 200)
                .card()
        }
    }
}

// MARK: - Shared helpers

@MainActor
func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}
