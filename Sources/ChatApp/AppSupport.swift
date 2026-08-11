import SwiftUI
import Foundation

// MARK: - App theme

enum MCThemeMode: String, CaseIterable, Identifiable {
    case dark = "dark"
    case light = "light"
    case auto = "auto"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .dark: return "Tối"
        case .light: return "Sáng"
        case .auto: return "Tự động"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .dark: return .dark
        case .light: return .light
        case .auto: return nil
        }
    }
}

@MainActor
final class MCThemeStore: ObservableObject {
    @Published var mode: MCThemeMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "mc_theme_mode") }
    }
    init() {
        mode = MCThemeMode(rawValue: UserDefaults.standard.string(forKey: "mc_theme_mode") ?? "dark") ?? .dark
    }
}

// MARK: - Logs: gom toàn bộ chat theo ngày

struct MCArchivedLog: Identifiable, Codable, Equatable {
    var id = UUID()
    var date: Date
    var text: String
    var segments: [MCChatSegment]? = nil
    // Optional để tương thích dữ liệu Logs cũ đã lưu từ các bản trước.
    var serverLabel: String? = nil
}

@MainActor
final class MCChatHistoryStore: ObservableObject {
    @Published private(set) var entries: [MCArchivedLog] = [] {
        didSet { save() }
    }
    private let key = "mc_chat_history_today"

    init() { loadAndPrune() }

    /// Chỉ lưu chat thực sự từ server. Debug/reconnect/packet errors không vào Logs.
    func append(_ entry: MCLogEntry, serverLabel: String? = nil) {
        guard entry.kind == .chat else { return }
        pruneIfNeeded()

        let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        if entries.last?.text == text,
           Date().timeIntervalSince(entries.last?.date ?? .distantPast) < 1 {
            return
        }

        entries.append(MCArchivedLog(
            date: entry.timestamp,
            text: text,
            segments: entry.segments,
            serverLabel: serverLabel
        ))
    }

    func clearToday() { entries.removeAll() }

    private func isToday(_ date: Date) -> Bool { Calendar.current.isDateInToday(date) }

    private func pruneIfNeeded() {
        entries.removeAll { !isToday($0.date) }
    }

    private func loadAndPrune() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([MCArchivedLog].self, from: data) else {
            entries = []
            return
        }
        entries = decoded.filter { isToday($0.date) }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

struct MCLogsView: View {
    @EnvironmentObject var history: MCChatHistoryStore

    private var dayEntries: [MCArchivedLog] {
        history.entries.sorted { $0.date < $1.date }
    }

    var body: some View {
        NavigationStack {
            Group {
                if dayEntries.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "archivebox.fill")
                            .font(.system(size: 42))
                            .foregroundStyle(.secondary)
                        Text("Chưa có Logs hôm nay")
                            .font(.headline)
                        Text("Tất cả chat trong cùng một ngày sẽ được gom vào một Logs.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        Section {
                            NavigationLink {
                                MCLogDayDetailView(entries: dayEntries)
                            } label: {
                                HStack(spacing: 16) {
                                    Image(systemName: "archivebox.fill")
                                        .font(.system(size: 38))
                                        .frame(width: 66, height: 66)
                                        .foregroundStyle(.white)
                                        .background(Color.gray.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))

                                    VStack(alignment: .leading, spacing: 5) {
                                        Text("Chat hôm nay")
                                            .font(.headline)
                                        Text(Date(), style: .date)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                        Text("\(dayEntries.count) tin nhắn")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                                .padding(.vertical, 8)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Logs")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    EditButton().disabled(history.entries.isEmpty)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(role: .destructive) { history.clearToday() } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(history.entries.isEmpty)
                }
            }
        }
    }
}

struct MCLogDayDetailView: View {
    let entries: [MCArchivedLog]

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        Text(entries.first.map { DateFormatter.mcFullDate.string(from: $0.date) } ?? "Hôm nay")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.top, 16)
                            .padding(.bottom, 8)

                        ForEach(entries) { entry in
                            VStack(alignment: .leading, spacing: 4) {
                                if let segments = entry.segments, !segments.isEmpty {
                                    archivedColoredText(segments)
                                        .textSelection(.enabled)
                                } else {
                                    Text(entry.text)
                                        .foregroundStyle(.white)
                                        .textSelection(.enabled)
                                }
                                HStack(spacing: 6) {
                                    Text(entry.date, style: .time)
                                    if let server = entry.serverLabel, !server.isEmpty {
                                        Text("•")
                                        Text(server)
                                    }
                                }
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .id(entry.id)
                            Divider().overlay(Color.white.opacity(0.08))
                        }
                    }
                    .padding(.bottom, 24)
                }
                .onAppear {
                    if let last = entries.last {
                        DispatchQueue.main.async { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
        }
        .navigationTitle("Chat Logs")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func archivedColoredText(_ segments: [MCChatSegment]) -> Text {
        segments.reduce(Text("")) { partial, segment in
            var part = Text(segment.text)
                .foregroundColor(segment.colorHex.flatMap(Color.init(hex:)) ?? .white)
            if segment.bold { part = part.bold() }
            if segment.italic { part = part.italic() }
            if segment.underline { part = part.underline() }
            if segment.strikethrough { part = part.strikethrough() }
            return partial + part
        }
    }
}

private extension DateFormatter {
    static let mcFullDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        return formatter
    }()
}

struct MCSettingsView: View {
    @EnvironmentObject var theme: MCThemeStore

    var body: some View {
        NavigationStack {
            Form {
                Section("Giao diện") {
                    Picker("Chế độ", selection: $theme.mode) {
                        ForEach(MCThemeMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.inline)
                    Text("Tự động sẽ theo giao diện sáng/tối của iPhone.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
        }
    }
}
