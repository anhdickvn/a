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

// MARK: - Logs (gộp theo ngày, giữ nhiều ngày, giống ChatCraft)

struct MCArchivedLog: Identifiable, Codable, Equatable {
    var id = UUID()
    var date: Date
    var text: String
    var segments: [MCChatSegment]? = nil
    /// Username / server của phiên đã tạo ra dòng log này — dùng để hiện icon + tên
    /// "ở ngoài" mỗi nhóm ngày trong màn Logs, giống bố cục ChatCraft.
    var username: String? = nil
    var serverLabel: String? = nil
}

/// 1 nhóm "cả 1 ngày" trong màn Logs — tương đương 1 dòng trong danh sách log của
/// ChatCraft, nhưng gộp TẤT CẢ các phiên/kết nối trong cùng 1 ngày lại làm một,
/// thay vì tách riêng theo từng lần kết nối như ChatCraft gốc.
struct MCLogDay: Identifiable {
    var id: Date // ngày đã strip giờ/phút/giây, dùng làm key nhóm luôn
    var date: Date
    var username: String
    var serverLabel: String
    var entries: [MCArchivedLog]
}

@MainActor
final class MCChatHistoryStore: ObservableObject {
    @Published private(set) var entries: [MCArchivedLog] = [] {
        didSet { save() }
    }
    private let key = "mc_chat_history_all"
    /// Giữ log tối đa 60 ngày gần nhất để không phình UserDefaults vô hạn.
    private let maxDaysKept = 60

    init() { load() }

    /// Chỉ lưu tin nhắn CHAT thực sự nhận từ server. Không lưu info/debug/error nội
    /// bộ app, để Logs chỉ là lịch sử chat thật của server (giống hành vi ChatCraft).
    func append(_ entry: MCLogEntry, username: String? = nil, serverLabel: String? = nil) {
        guard entry.kind == .chat || entry.kind == .system else { return }

        let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        // Không ghi lại cùng một dòng liên tiếp do reconnect/callback trùng.
        if entries.last?.text == text &&
            Date().timeIntervalSince(entries.last?.date ?? .distantPast) < 1 {
            return
        }

        entries.append(
            MCArchivedLog(
                date: entry.timestamp,
                text: text,
                segments: entry.segments,
                username: username,
                serverLabel: serverLabel
            )
        )
        prune()
    }

    /// Toàn bộ log được gộp theo ngày (mới nhất trước), mỗi ngày = 1 "hàng" trong màn Logs.
    var groupedByDay: [MCLogDay] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: entries) { calendar.startOfDay(for: $0.date) }
        return groups.map { day, items in
            let sorted = items.sorted { $0.date < $1.date }
            let last = sorted.last
            return MCLogDay(
                id: day,
                date: day,
                username: last?.username ?? "—",
                serverLabel: last?.serverLabel ?? "",
                entries: sorted
            )
        }
        .sorted { $0.date > $1.date }
    }

    func clearAll() { entries.removeAll() }

    func delete(day: Date) {
        let calendar = Calendar.current
        entries.removeAll { calendar.isDate($0.date, inSameDayAs: day) }
    }

    private func prune() {
        let calendar = Calendar.current
        guard let cutoff = calendar.date(byAdding: .day, value: -maxDaysKept, to: Date()) else { return }
        entries.removeAll { $0.date < cutoff }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([MCArchivedLog].self, from: data) else {
            entries = []
            return
        }
        entries = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

/// Màn "Logs" — 1 hàng = 1 NGÀY (gộp tất cả phiên/kết nối của ngày đó lại làm một),
/// mỗi hàng hiện icon + username "ở ngoài" như danh sách log gốc của ChatCraft, thay vì
/// tách riêng theo từng lần kết nối.
struct MCLogsView: View {
    @EnvironmentObject var history: MCChatHistoryStore
    @State private var deleteDay: MCLogDay?
    @State private var searchText = ""

    private var filteredDays: [MCLogDay] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return history.groupedByDay }
        return history.groupedByDay.compactMap { day in
            let dayMatches = day.username.lowercased().contains(q) || day.serverLabel.lowercased().contains(q)
            let matchingEntries = day.entries.filter {
                $0.text.lowercased().contains(q) || ($0.username ?? "").lowercased().contains(q) || ($0.serverLabel ?? "").lowercased().contains(q)
            }
            guard dayMatches || !matchingEntries.isEmpty else { return nil }
            return MCLogDay(id: day.id, date: day.date, username: day.username, serverLabel: day.serverLabel, entries: dayMatches ? day.entries : matchingEntries)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                let days = filteredDays
                if days.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "shippingbox.fill").font(.largeTitle).foregroundStyle(.secondary)
                        Text("Chưa có lịch sử").font(.headline)
                        Text("Chat từ server sẽ được lưu tại đây, gộp theo từng ngày.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(days) { day in
                            NavigationLink {
                                MCLogDayDetailView(day: day)
                            } label: {
                                logDayRow(day)
                            }
                            .swipeActions {
                                Button(role: .destructive) { deleteDay = day } label: {
                                    Label("Xoá", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Logs")
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Tìm tin nhắn, username, server...")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Xoá tất cả", role: .destructive) { history.clearAll() }
                        .disabled(history.entries.isEmpty)
                }
            }
            .confirmationDialog(
                "Xoá log ngày này?",
                isPresented: Binding(get: { deleteDay != nil }, set: { if !$0 { deleteDay = nil } }),
                titleVisibility: .visible
            ) {
                Button("Xoá", role: .destructive) {
                    if let day = deleteDay { history.delete(day: day.date) }
                    deleteDay = nil
                }
                Button("Huỷ", role: .cancel) { deleteDay = nil }
            }
        }
    }

    /// Icon biểu tượng (hộp gỗ, như ChatCraft) + username hiện ngay bên ngoài hàng.
    private func logDayRow(_ day: MCLogDay) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "shippingbox.fill")
                .font(.title2)
                .foregroundStyle(.orange)
                .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 3) {
                Text(day.username)
                    .font(.body.weight(.semibold))
                Text(day.date, format: .dateTime.day().month().year())
                    .font(.subheadline)
                if !day.serverLabel.isEmpty {
                    Text(day.serverLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text("\(day.entries.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

/// Chi tiết log của 1 ngày — danh sách tin nhắn theo thời gian, giống chat gốc.
struct MCLogDayDetailView: View {
    let day: MCLogDay

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(day.entries) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        if let segments = entry.segments, !segments.isEmpty {
                            coloredArchivedText(segments).textSelection(.enabled)
                        } else {
                            Text(entry.text).textSelection(.enabled)
                        }
                        Text(entry.date, style: .time)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    Divider()
                }
            }
            .padding(.top, 8)
        }
        .navigationTitle(day.date.formatted(.dateTime.day().month().year()))
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func coloredArchivedText(_ segments: [MCChatSegment]) -> Text {
        segments.reduce(Text("")) { partial, segment in
            var part = Text(segment.text)
                .foregroundColor(segment.colorHex.flatMap(Color.init(hex:)) ?? .primary)
            if segment.bold { part = part.bold() }
            if segment.italic { part = part.italic() }
            if segment.strikethrough { part = part.strikethrough() }
            return partial + part
        }
    }
}

struct MCSettingsView: View {
    @EnvironmentObject var theme: MCThemeStore
    @StateObject private var client = MCClient.shared
    @AppStorage("mc_show_movement_debug") private var showMovementDebug = false

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

                Section("Debug WASD / Jump") {
                    Toggle("Ghi Debug WASD / Jump", isOn: $showMovementDebug)
                    NavigationLink("Debug WASD / Jump") {
                        MCMovementDebugView(client: client)
                    }
                    Text("Khi bật, app ghi riêng TOUCH DOWN/UP, W/A/S/D, JUMP, tọa độ trước/sau và packet movement để tìm lý do bấm nhưng không di chuyển.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
        }
    }
}



struct MCMovementDebugView: View {
    @ObservedObject var client: MCClient
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("WASD / Jump Debug")
                    .font(.headline)
                Spacer()
                Button("Copy") {
                    UIPasteboard.general.string = client.movementDebugLines.joined(separator: "\n")
                }
                Button("Clear") {
                    client.clearMovementDebug()
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)

            if client.movementDebugLines.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "gamecontroller")
                        .font(.system(size: 34))
                        .foregroundStyle(.secondary)
                    Text("Chưa có debug")
                        .font(.headline)
                    Text("Bật “Ghi Debug WASD / Jump”, vào server và bấm W/A/S/D hoặc JUMP.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(client.movementDebugLines.enumerated()), id: \.offset) { idx, line in
                                Text(line)
                                    .font(.system(.footnote, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(idx)
                            }
                        }
                        .padding(12)
                    }
                    .onChange(of: client.movementDebugLines.count) { _ in
                        if let last = client.movementDebugLines.indices.last {
                            withAnimation(.none) { proxy.scrollTo(last, anchor: .bottom) }
                        }
                    }
                }
            }
        }
        .background(Color.black.ignoresSafeArea())
        .foregroundStyle(.white)
        .navigationTitle("WASD / Jump Debug")
        .navigationBarTitleDisplayMode(.inline)
    }
}
