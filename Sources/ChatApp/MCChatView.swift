import SwiftUI
import UIKit

extension Color {
    init?(hex: String) {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        self = Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

/// Các "màn hình" con trong 1 phiên chat, y hệt bố cục ChatCraft: luôn có nút back
/// (thoát hẳn ra danh sách server, có hỏi "Stay connected?" nếu đang giữ kết nối) ở
/// bên trái, và bên phải luôn hiện đúng 4 icon — là 4 màn hình còn lại (không tính
/// màn đang đứng) — để chuyển qua lại. Khi server mở 1 GUI (rương, bàn chế tạo...),
/// GUI đó nằm sẵn trong màn Inventory nhưng người dùng phải tự bấm icon cặp sách mới
/// xem được, giống hệt ChatCraft (không tự nhảy màn).
enum MCScreen: CaseIterable {
    case chat, players, movement, inventory, health

    var icon: String {
        switch self {
        case .chat: return "message.fill"
        case .players: return "person.3.fill"
        case .movement: return "location.north.fill"
        case .inventory: return "briefcase.fill"
        case .health: return "cross.case.fill"
        }
    }
}

struct MCChatView: View {
    let profile: MCServerProfile
    @EnvironmentObject var accountStore: MCAccountStore
    @EnvironmentObject var historyStore: MCChatHistoryStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var client = MCClient.shared
    @StateObject private var resourcePack = MCResourcePackStore.shared

    @State private var screen: MCScreen = .chat
    @State private var input = ""
    @State private var inputFocused = false
    @State private var tooltipItem: MCItemSlot?
    @State private var tooltipWindowItem: MCOpenWindowItem?
    /// Hộp thoại "Stay connected / Disconnect" khi bấm nút back <- lúc còn đang giữ
    /// kết nối tới server, giống đúng hành vi ChatCraft.
    @State private var showStayConnectedPrompt = false
    /// Vị trí đang đứng trong `client.sentMessageHistory` khi dùng nút mũi tên lên/xuống
    /// để gọi lại tin/lệnh đã gửi trước đó (vd gõ "/back" -> gửi -> bấm mũi tên lên ->
    /// khung nhập tự điền lại "/back"). nil = đang không "duyệt" lịch sử.
    @State private var historyIndex: Int?
    /// true trong đúng 1 lần khi input được set TỪ việc bấm mũi tên (không phải người
    /// dùng tự gõ) — để onChange(of: input) không reset historyIndex nhầm ngay sau đó.
    @State private var isRecallingHistory = false

    private var account: MCAccount? { accountStore.account(for: profile.accountId) }

    /// Chỉ tin nhắn chat/thông báo THẬT từ server mới hiện trong khung chat chính —
    /// các dòng info/error nội bộ (đang kết nối lại, timeout...) không được vẽ vào đây,
    /// mà đi qua `connectionNotice` ở dưới, giống hành vi ChatCraft (không lẫn log kỹ
    /// thuật vào chat thật).
    private var visibleLog: [MCLogEntry] {
        client.log.filter { $0.kind == .chat || $0.kind == .system }
    }

    /// Dòng info/error nội bộ gần nhất — chỉ hiện thành 1 banner nhỏ khi kết nối
    /// không ổn định, không chèn vào giữa các tin nhắn chat thật.
    private var connectionNotice: MCLogEntry? {
        guard client.state != .connected else { return nil }
        return client.log.last(where: { $0.kind == .info || $0.kind == .error })
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch screen {
            case .chat: chatView
            case .players: playersScreen
            case .movement: movementScreen
            case .inventory: inventoryScreen
            case .health: healthScreen
            }
        }
        .preferredColorScheme(.dark)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbarBackground(Color.black, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    let isActive = client.state == .connected || client.state == .connecting || client.state == .loggingIn
                    if isActive {
                        showStayConnectedPrompt = true
                    } else {
                        dismiss()
                    }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white)
                }
            }
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                ForEach(MCScreen.allCases.filter { $0 != screen }, id: \.self) { destination in
                    Button { screen = destination } label: {
                        Image(systemName: destination.icon)
                    }
                    .disabled(destination != .chat && client.state != .connected)
                }
            }
        }
        .sheet(item: $tooltipItem) { item in
            itemTooltipSheet(name: item.plainName, segments: item.nameSegments, lore: item.loreSegments,
                             image: resourcePack.image(for: item))
        }
        .sheet(item: $tooltipWindowItem) { item in
            itemTooltipSheet(name: item.plainName, segments: item.nameSegments, lore: item.loreSegments,
                             image: resourcePack.image(for: item), windowAction: { button in
                                 client.clickWindowSlot(item.slot, mouseButton: button)
                                 tooltipWindowItem = nil
                             })
        }
        .onChange(of: input) { newValue in
            if !newValue.hasPrefix("/") { client.tabCompletions = [] }
            if isRecallingHistory {
                isRecallingHistory = false
            } else {
                historyIndex = nil // người dùng tự gõ -> thoát khỏi chế độ duyệt lịch sử
            }
        }
        // Không tự chuyển màn khi server mở 1 GUI (rương, bàn chế tạo...) nữa — giống
        // ChatCraft, người dùng phải tự bấm icon cặp sách (Inventory) mới xem được GUI.
        .confirmationDialog(
            "Do you want to stay connected?",
            isPresented: $showStayConnectedPrompt,
            titleVisibility: .visible
        ) {
            Button("Stay connected") { dismiss() }
            Button("Disconnect", role: .destructive) {
                client.disconnect()
                dismiss()
            }
        } message: {
            Text("Rời khỏi màn hình này vẫn giữ kết nối tới server ở nền. Bạn muốn giữ kết nối hay ngắt kết nối?")
        }
        .onAppear {
            guard let account else {
                client.appendUserInfo("Chưa chọn Minecraft username cho server này.")
                return
            }
            guard !client.isConnectedTo(host: profile.host, port: profile.port, username: account.username) else { return }
            client.connect(host: profile.host, port: profile.port, username: account.username, autoLogin: profile.autoLogin)
        }
        .task { await resourcePack.ensureVanillaAssets() }
    }

    private var chatView: some View {
        VStack(spacing: 0) {
            if let notice = connectionNotice {
                connectionNoticeBanner(notice)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(visibleLog) { entry in
                            logRow(entry).id(entry.id)
                                .padding(.vertical, 10)
                            if entry.id != visibleLog.last?.id {
                                Divider().overlay(Color.white.opacity(0.14))
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 4)
                }
                .background(Color.black)
                .onChange(of: client.log.count) { _ in
                    if let last = client.log.last, last.kind == .chat || last.kind == .system {
                        historyStore.append(last, username: account?.username, serverLabel: "\(profile.host):\(profile.port)")
                    }
                    if let lastVisible = visibleLog.last {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(lastVisible.id, anchor: .bottom)
                        }
                    }
                }
                .onAppear {
                    // Mở lại app / quay lại màn chat -> tự kéo xuống tin nhắn gần nhất,
                    // không bắt người dùng tự cuộn tay như trước.
                    if let lastVisible = visibleLog.last {
                        DispatchQueue.main.async {
                            proxy.scrollTo(lastVisible.id, anchor: .bottom)
                        }
                    }
                }

                if !visibleLog.isEmpty {
                    HStack(spacing: 40) {
                        Spacer()
                        Button {
                            recallOlderMessage()
                        } label: {
                            Image(systemName: "arrow.up")
                                .font(.title2.weight(.semibold))
                                .foregroundStyle(client.sentMessageHistory.isEmpty ? .gray : .blue)
                        }
                        .disabled(client.sentMessageHistory.isEmpty)
                        Button {
                            recallNewerMessage()
                        } label: {
                            Image(systemName: "arrow.down")
                                .font(.title2.weight(.semibold))
                                .foregroundStyle(historyIndex == nil ? .gray : .blue)
                        }
                        .disabled(historyIndex == nil)
                        Spacer()
                    }
                    .padding(.vertical, 10)
                    .background(Color.black)
                }
            }

            if !client.tabCompletions.isEmpty && input.hasPrefix("/") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(client.tabCompletions.prefix(12), id: \.self) { name in
                            Button(name) {
                                input = replaceLastToken(in: input, with: name)
                                inputFocused = true
                            }
                            .font(.caption)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Color.white.opacity(0.12), in: Capsule())
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                }
                .background(Color.black)
            }

            Divider().overlay(Color.white.opacity(0.12))
            chatInputBar
        }
    }

    /// Banner nhỏ, gọn cho các dòng info/error nội bộ (đang kết nối lại, timeout...)
    /// — không chèn lẫn vào giữa các tin nhắn chat thật nữa.
    private func connectionNoticeBanner(_ entry: MCLogEntry) -> some View {
        HStack(spacing: 8) {
            ProgressView().scaleEffect(0.7).tint(.white)
            Text(entry.text)
                .font(.caption)
                .foregroundStyle(entry.kind == .error ? Color.orange : Color.white.opacity(0.75))
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.08))
    }

    private var chatInputBar: some View {
        HStack(spacing: 8) {
            Button("TAB") { completeTab() }
                .font(.headline)
                .foregroundStyle(.blue)
                .frame(width: 48)

            MCTabTextField(text: $input, isFocused: $inputFocused, placeholder: "Message...",
                           onSubmit: sendMessage, onTab: completeTab, movementEnabled: false,
                           onMoveKey: { _ in })
                .frame(height: 48)
                .disabled(client.state != .connected)

            Button { sendMessage() } label: {
                Image(systemName: "paperplane.fill")
                    .font(.title2)
                    .foregroundStyle(.blue)
                    .frame(width: 40, height: 48)
            }
            .disabled(client.state != .connected || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(Color.black)
    }

    /// Cửa sổ GUI server (rương, bàn chế tạo...) — chiếm toàn màn Inventory, có nút
    /// đỏ "Close window" như ChatCraft; back <- và các icon chat/players/movement/health
    /// vẫn nằm trên toolbar chung của cả màn hình.
    private func serverWindowScreen(_ window: MCOpenWindow) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "shippingbox.fill")
                    .foregroundStyle(.blue)
                Text(window.title.isEmpty ? "GUI" : window.title)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer()
                Text("\(window.items.count) mục")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 6)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(window.items.values.sorted { $0.slot < $1.slot })) { item in
                        serverWindowRow(item)
                        Divider().overlay(Color.white.opacity(0.08))
                    }
                }
            }

            Button {
                client.closeCurrentWindow()
                screen = .chat
            } label: {
                Text("Close window")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }

    private func serverWindowRow(_ item: MCOpenWindowItem) -> some View {
        HStack(spacing: 8) {
            itemIcon(item)
            if let segments = item.nameSegments, !segments.isEmpty {
                coloredText(segments).font(.system(size: 16, weight: .medium))
            } else {
                Text(item.plainName)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.blue)
            }
            Spacer(minLength: 4)
            Menu {
                Button("Display lore") { tooltipWindowItem = item }
                Button("Left click") { client.clickWindowSlot(item.slot, mouseButton: 0) }
                Button("Right click") { client.clickWindowSlot(item.slot, mouseButton: 1) }
                Button("Drop all") { client.dropAllFromWindowSlot(item.slot) }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.blue)
                    .frame(width: 32, height: 40)
            }
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 48)
    }

    /// Màn di chuyển thật (WASD + Jump), KHÔNG có mini-map — bấm giữ là gửi packet di
    /// chuyển thật tới server qua client.startMoving/stopMoving, không phải hình minh hoạ.
    private var movementScreen: some View {
        VStack(spacing: 24) {
            Spacer()
            HStack(spacing: 26) {
                movementPad
                HoldButton(title: "JUMP") { client.jumpPlayer() }
                    .frame(width: 78, height: 78)
            }
            VStack(spacing: 4) {
                Text("Chạm và giữ W/A/S/D để di chuyển")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(String(format: "X=%.2f Y=%.2f Z=%.2f", client.playerX, client.playerY, client.playerZ))
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }

    private var movementPad: some View {
        let size: CGFloat = 48
        let gap: CGFloat = 5
        return VStack(spacing: gap) {
            HStack(spacing: gap) {
                Color.clear.frame(width: size, height: size)
                moveButton("W", forward: 1, strafe: 0, size: size)
                Color.clear.frame(width: size, height: size)
            }
            HStack(spacing: gap) {
                moveButton("A", forward: 0, strafe: -1, size: size)
                moveButton("S", forward: -1, strafe: 0, size: size)
                moveButton("D", forward: 0, strafe: 1, size: size)
            }
        }
    }

    private func moveButton(_ title: String, forward: Double, strafe: Double, size: CGFloat) -> some View {
        HoldButton(title: title) {
            client.movePlayer(forward: forward, strafe: strafe)
        } onHold: {
            client.startMoving(forward: forward, strafe: strafe)
        } onRelease: {
            client.stopMoving(forward: forward, strafe: strafe)
        }
        .frame(width: size, height: size)
    }

    /// Nếu server đang mở 1 GUI (rương, bàn chế tạo...) thì hiện GUI đó thay vì túi đồ
    /// của người chơi — đúng hành vi ChatCraft: cùng 1 icon "briefcase" nhưng nội dung
    /// đổi theo có/không có cửa sổ server đang mở.
    private var inventoryScreen: some View {
        Group {
            if let window = client.currentWindow {
                serverWindowScreen(window)
            } else {
                ownInventoryScreen
            }
        }
    }

    private var ownInventoryScreen: some View {
        ScrollView {
            VStack(spacing: 12) {
                inventorySection("HAND", slots: 36...44)
                inventorySection("INVENTORY", slots: 9...35)
                inventorySection("ARMOR", slots: 5...8)
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }

    private func inventorySection(_ title: String, slots: ClosedRange<Int>) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            LazyVStack(spacing: 0) {
                ForEach(Array(slots), id: \.self) { slot in
                    if let item = client.playerInventory[slot] {
                        HStack(spacing: 10) {
                            itemIcon(item)
                            if let segments = item.nameSegments, !segments.isEmpty {
                                coloredText(segments).font(.system(size: 17))
                            } else {
                                Text(item.plainName).foregroundStyle(.blue)
                            }
                            Spacer()
                            Menu {
                                Button("Display lore") { tooltipItem = item }
                                Button("Left click") { client.clickInventorySlot(slot, mouseButton: 0) }
                                Button("Right click") { client.clickInventorySlot(slot, mouseButton: 1) }
                                Button("Drop all") { client.dropAllFromInventorySlot(slot) }
                            } label: {
                                Image(systemName: "ellipsis").foregroundStyle(.blue)
                            }
                        }
                        .padding(.horizontal, 8)
                        .frame(minHeight: 50)
                        Divider().overlay(Color.white.opacity(0.08))
                    }
                }
            }
            .background(Color(red: 0.08, green: 0.08, blue: 0.09), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    @ViewBuilder
    private func itemIcon(_ item: MCItemSlot) -> some View {
        if let image = resourcePack.image(for: item) {
            Image(uiImage: image)
                .resizable()
                .interpolation(.none)
                .scaledToFit()
                .frame(width: 38, height: 38)
        } else {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.white.opacity(0.08))
                .frame(width: 38, height: 38)
        }
    }

    @ViewBuilder
    private func itemIcon(_ item: MCOpenWindowItem) -> some View {
        if let image = resourcePack.image(for: item) {
            Image(uiImage: image)
                .resizable()
                .interpolation(.none)
                .scaledToFit()
                .frame(width: 38, height: 38)
        } else {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.white.opacity(0.08))
                .frame(width: 38, height: 38)
        }
    }

    private func itemTooltipSheet(name: String, segments: [MCChatSegment]?, lore: [[MCChatSegment]], image: UIImage?, windowAction: ((UInt8) -> Void)? = nil) -> some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        if let image {
                            Image(uiImage: image)
                                .resizable()
                                .interpolation(.none)
                                .scaledToFit()
                                .frame(width: 64, height: 64)
                        }
                        if let segments, !segments.isEmpty {
                            coloredText(segments).font(.headline)
                        } else {
                            Text(name).font(.headline).foregroundStyle(.black)
                        }
                    }
                    if lore.isEmpty {
                        Text("Không có Lore").foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(lore.enumerated()), id: \.offset) { _, line in
                            coloredText(line).foregroundStyle(.black)
                        }
                    }
                    if let windowAction {
                        HStack {
                            Button("Left click") { windowAction(0) }.buttonStyle(.borderedProminent)
                            Button("Right click") { windowAction(1) }.buttonStyle(.bordered)
                        }
                    }
                }
                .padding()
            }
            .background(Color.white.ignoresSafeArea())
            .navigationTitle("Display lore")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Đóng") { tooltipItem = nil; tooltipWindowItem = nil }
                }
            }
        }
        .preferredColorScheme(.light)
    }

    /// "Player health" — tim đỏ = máu, đùi gà = thức ăn, giống hệt bố cục ChatCraft
    /// (mỗi icon = 2 điểm, làm tròn lên để không "mất" phần lẻ khi còn > 0).
    private var healthScreen: some View {
        VStack(spacing: 20) {
            Text("Player health")
                .font(.headline)
                .foregroundStyle(.white)
                .padding(.top, 24)
            HStack(spacing: 4) {
                ForEach(0..<10, id: \.self) { i in
                    Image(systemName: i < Int(ceil(client.health / 2)) ? "heart.fill" : "heart")
                        .foregroundStyle(.red)
                        .font(.title3)
                }
            }
            HStack(spacing: 4) {
                ForEach(0..<10, id: \.self) { i in
                    if i < Int(ceil(Double(client.food) / 2)) {
                        Image(systemName: "fork.knife.circle.fill")
                            .foregroundStyle(Color(red: 0.62, green: 0.42, blue: 0.24))
                            .font(.title3)
                    }
                }
            }
            Button { client.respawn() } label: {
                Text("Respawn")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(width: 210, height: 50)
                    .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.18)))
            }
            .disabled(client.health > 0)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }

    /// Danh sách người chơi online, hiện đầu skin thật (giống ChatCraft) thay vì icon
    /// chung chung — dùng AsyncImage tải từ dịch vụ render đầu skin công khai, có fallback
    /// icon người khi chưa tải xong / không có mạng.
    private var playersScreen: some View {
        List {
            Section("Online · \(client.onlinePlayerNames.count)") {
                ForEach(client.onlinePlayerNames.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }, id: \.self) { name in
                    HStack(spacing: 12) {
                        playerHeadIcon(name)
                        Text(name).textSelection(.enabled)
                    }
                }
                if client.onlinePlayerNames.isEmpty {
                    Text("Chưa nhận được danh sách người chơi từ server.").foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.black)
    }

    @ViewBuilder
    private func playerHeadIcon(_ name: String) -> some View {
        AsyncImage(url: URL(string: "https://mc-heads.net/avatar/\(name)/64")) { phase in
            if let image = phase.image {
                image.resizable().interpolation(.none)
            } else {
                Color.white.opacity(0.08)
            }
        }
        .frame(width: 32, height: 32)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    /// Mũi tên lên: lùi về tin/lệnh đã gửi CŨ hơn (giống Up trên client thật), không
    /// phải cuộn màn hình. Bấm liên tiếp tiếp tục lùi xa hơn cho tới tin đầu tiên.
    private func recallOlderMessage() {
        let history = client.sentMessageHistory
        guard !history.isEmpty else { return }
        let newIndex: Int
        if let current = historyIndex {
            newIndex = max(0, current - 1)
        } else {
            newIndex = history.count - 1
        }
        historyIndex = newIndex
        isRecallingHistory = true
        input = history[newIndex]
        inputFocused = true
    }

    /// Mũi tên xuống: tiến lại gần tin mới hơn; qua khỏi tin gần nhất thì trả khung
    /// nhập về rỗng (thoát chế độ duyệt lịch sử), giống Down trên client thật.
    private func recallNewerMessage() {
        guard let current = historyIndex else { return }
        let history = client.sentMessageHistory
        if current + 1 < history.count {
            historyIndex = current + 1
            isRecallingHistory = true
            input = history[current + 1]
        } else {
            historyIndex = nil
            isRecallingHistory = true
            input = ""
        }
        inputFocused = true
    }

    private func completeTab() {
        guard client.state == .connected else { return }
        if let completed = client.completeWithNextPlayerName(input) {
            input = completed
            inputFocused = true
        } else if input.hasPrefix("/") {
            client.requestTabCompletions(input)
            inputFocused = true
        }
    }

    private func replaceLastToken(in text: String, with value: String) -> String {
        guard let range = text.range(of: #"\S+$"#, options: .regularExpression) else { return text + value }
        return String(text[..<range.lowerBound]) + value
    }

    private func sendMessage() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        client.sendChat(text)
        input = ""
    }

    @ViewBuilder
    private func logRow(_ entry: MCLogEntry) -> some View {
        if let segments = entry.segments, !segments.isEmpty {
            coloredText(segments).font(.system(size: 18))
        } else {
            Text(entry.text)
                .font(.system(size: 18))
                .foregroundStyle(.white)
                .textSelection(.enabled)
        }
    }

    private func coloredText(_ segments: [MCChatSegment]) -> Text {
        segments.reduce(Text("")) { partial, seg in
            var t = Text(seg.text).foregroundColor(seg.colorHex.flatMap(Color.init(hex:)) ?? .white)
            if seg.bold { t = t.bold() }
            if seg.italic { t = t.italic() }
            if seg.strikethrough { t = t.strikethrough() }
            if seg.underline { t = t.underline() }
            return partial + t
        }
    }
}

private struct HoldButton: View {
    let title: String
    let action: () -> Void
    var onHold: (() -> Void)? = nil
    var onRelease: (() -> Void)? = nil

    @State private var isHolding = false
    @State private var repeatTask: Task<Void, Never>?

    var body: some View {
        Text(title)
            .font(.headline.weight(.bold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(isHolding ? Color.blue.opacity(0.55) : Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.18)))
            .contentShape(Rectangle())
            .onTapGesture {
                action()
            }
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.12)
                    .onEnded { _ in
                        beginHolding()
                    }
            )
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !isHolding && onHold != nil { beginHolding() }
                    }
                    .onEnded { _ in
                        endHolding()
                    }
            )
            .onDisappear { endHolding() }
    }

    private func beginHolding() {
        guard !isHolding, onHold != nil else { return }
        isHolding = true
        onHold?()
        repeatTask?.cancel()
        repeatTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
                if Task.isCancelled { break }
                onHold?()
            }
        }
    }

    private func endHolding() {
        guard isHolding else { return }
        isHolding = false
        repeatTask?.cancel()
        repeatTask = nil
        onRelease?()
    }
}
