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
    @Environment(\.openURL) private var openURL
    @StateObject private var client = MCClient.shared
    @StateObject private var resourcePack = MCResourcePackStore.shared

    @State private var screen: MCScreen = .chat
    @State private var input = ""
    @State private var inputFocused = false
    @State private var tooltipItem: MCItemSlot?
    @State private var tooltipWindowItem: MCOpenWindowItem?
    @State private var windowActionItem: MCOpenWindowItem?
    @State private var inventoryActionSlot: Int?
    @State private var showWindowItemActions = false
    @State private var showInventoryItemActions = false
    @State private var selectedItemActionTarget: ItemActionTarget?
    @State private var reliableActionTitle = "Item actions"
    @State private var reliableActionWindowItem: MCOpenWindowItem?
    @State private var reliableActionInventorySlot: Int?
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
    @State private var selectedChatURL: URL?
    @State private var showChatClickAction = false
    @State private var showTabSuggestions = false
    @State private var chatHoverItem: MCChatHoverItem?
    @State private var chatIsAtBottom = true
    @State private var lastChatVisibleCount = 0
    @State private var forceScrollToBottomToken = 0
    @State private var archivedVisibleLogIDs: Set<UUID> = []
    @StateObject private var keyboardObserver = MCKeyboardObserver()

    private var account: MCAccount? { accountStore.account(for: profile.accountId) }

    /// Chỉ tin nhắn chat/thông báo THẬT từ server mới hiện trong khung chat chính —
    /// các dòng info/error nội bộ (đang kết nối lại, timeout...) không được vẽ vào đây,
    /// mà đi qua `connectionNotice` ở dưới, giống hành vi ChatCraft (không lẫn log kỹ
    /// thuật vào chat thật).
    private var visibleLog: [MCLogEntry] {
        client.log.filter { entry in
            switch entry.kind {
            case .chat, .system:
                return true
            case .debug:
                return false
            default:
                return false
            }
        }
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
                             image: resourcePack.image(for: item))
        }
        .sheet(item: $chatHoverItem) { item in
            chatHoverItemSheet(item)
        }
        .sheet(item: $selectedItemActionTarget, onDismiss: {
            reliableActionWindowItem = nil
            reliableActionInventorySlot = nil
        }) { target in
            itemActionSheet(for: target)
                .presentationDetents([.height(300)])
                .presentationDragIndicator(.visible)
                .preferredColorScheme(.dark)
        }
        .onChange(of: input) { newValue in
            let token = newValue.split(whereSeparator: { $0.isWhitespace }).last.map(String.init) ?? ""
            if client.state == .connected, !token.isEmpty {
                client.requestTabCompletions(newValue)
            } else {
                client.tabCompletions = []
                showTabSuggestions = false
            }
            if isRecallingHistory {
                isRecallingHistory = false
            } else {
                historyIndex = nil // người dùng tự gõ -> thoát khỏi chế độ duyệt lịch sử
            }
        }
        // Không tự chuyển màn khi server mở 1 GUI (rương, bàn chế tạo...) nữa — giống
        // ChatCraft, người dùng phải tự bấm icon cặp sách (Inventory) mới xem được GUI.
        .alert("Connection", isPresented: $showStayConnectedPrompt) {
            Button("Stay connected", role: .cancel) {
                // Rời màn chat nhưng GIỮ nguyên socket hiện tại.
                // Server/account vẫn tiếp tục ở phiên này; người dùng có thể quay lại
                // hoặc thêm tài khoản/server khác ở giao diện bên ngoài.
                showStayConnectedPrompt = false
                inputFocused = false
                dismiss()
            }
            Button("Disconnect", role: .destructive) {
                // Disconnect là thao tác đồng bộ ở phía client: huỷ mọi task/reconnect,
                // cancel socket và đổi state ngay. Không dùng Task/await ở đây để tránh
                // trường hợp view đã dismiss nhưng callback của alert không còn chạy.
                showStayConnectedPrompt = false
                inputFocused = false
                input = ""
                historyIndex = nil
                screen = .chat
                client.disconnect(silent: true)
                client.clearCurrentChat()
                dismiss()
            }
        } message: {
            Text("Stay connected để giữ nguyên phiên. Disconnect để ngắt server và quay về Accounts / Servers.")
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

            // Toàn bộ transcript giờ nằm trong MỘT UITextView duy nhất.
            // Nhờ vậy iOS cho phép long-press -> Select All -> Copy trên toàn bộ chat,
            // thay vì chỉ bôi đen được từng dòng riêng lẻ như trước. Không có nút Copy riêng
            // nằm trong thanh chat; dùng menu chọn văn bản của iOS khi cần sao chép.
            ChatTranscriptTextView(
                entries: visibleLog,
                isAtBottom: $chatIsAtBottom,
                forceScrollToBottomToken: forceScrollToBottomToken,
                onURLTap: { url in
                    openURL(url)
                },
                onItemTap: { item in
                    chatHoverItem = item
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .onChange(of: keyboardObserver.height) { newHeight in
                // safeAreaInset already resizes the transcript above the keyboard.
                // Do not add keyboard height as bottom padding or we create a second
                // keyboard-sized black area. When the user is at the bottom, simply
                // re-scroll to the latest message after the viewport changes.
                if newHeight > 0 && chatIsAtBottom {
                    forceScrollToBottomToken &+= 1
                }
            }
            .onChange(of: visibleLog.count) { newCount in
                lastChatVisibleCount = newCount
            }
            .onChange(of: client.log) { entries in
                // Archive MỌI chat/system mới, không chỉ phần tử cuối.
                // Như vậy nếu server đẩy nhiều dòng trong cùng một update thì Logs vẫn giữ đủ.
                for entry in entries where (entry.kind == .chat || entry.kind == .system) {
                    guard !archivedVisibleLogIDs.contains(entry.id) else { continue }
                    historyStore.append(entry, username: account?.username, serverLabel: "\(profile.host):\(profile.port)")
                    archivedVisibleLogIDs.insert(entry.id)
                }
            }

            if showTabSuggestions && !client.tabCompletions.isEmpty {
                VStack(spacing: 0) {
                    ForEach(client.tabCompletions.prefix(8), id: \.self) { name in
                        Button {
                            input = replaceLastToken(in: input, with: name)
                            showTabSuggestions = true
                            inputFocused = true
                        } label: {
                            HStack(spacing: 10) {
                                playerHeadIcon(name)
                                Text(name)
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundStyle(.white)
                                Spacer()
                            }
                            .padding(.horizontal, 14)
                            .frame(height: 46)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider().overlay(Color.white.opacity(0.08))
                    }
                }
                .background(Color(red: 0.08, green: 0.08, blue: 0.09))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 14)
                .padding(.bottom, 6)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider().overlay(Color.white.opacity(0.12))
                chatInputBar
            }
            .background(Color.black)
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
        VStack(spacing: 5) {
            HStack(spacing: 6) {
                Button("TAB") { completeTab() }
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.blue)
                    .frame(width: 48)

                MCTabTextField(text: $input, isFocused: $inputFocused, placeholder: "Message...",
                               onSubmit: sendMessage, onTab: completeTab, movementEnabled: false,
                               onMoveKey: { _ in })
                    .frame(height: 48)
                    .disabled(client.state != .connected)

                Button { sendMessage() } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.blue)
                        .frame(width: 42, height: 48)
                }
                .disabled(client.state != .connected || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            HStack(spacing: 26) {
                Spacer(minLength: 0)
                Button { recallOlderMessage() } label: {
                    Image(systemName: "arrow.down")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(client.sentMessageHistory.isEmpty ? .gray : .blue)
                }
                .disabled(client.sentMessageHistory.isEmpty)
                Button { recallNewerMessage() } label: {
                    Image(systemName: "arrow.up")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(historyIndex == nil ? .gray : .blue)
                }
                .disabled(historyIndex == nil)
                Spacer(minLength: 0)
            }
            .padding(.bottom, 3)
        }
        .padding(.horizontal, 8)
        .padding(.top, 3)
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
            // Chạm trực tiếp vào item sẽ thực hiện click mặc định giống ChatCraft:
            // - nếu tên/lore có "chuột phải" (hoặc "right click") -> button 1
            // - nếu không ghi gì -> button 0 (chuột trái).
            Button {
                client.clickWindowSlot(item.slot, mouseButton: defaultMouseButton(for: item))
            } label: {
                HStack(spacing: 10) {
                    itemIcon(item)
                    VStack(alignment: .leading, spacing: 2) {
                        if let segments = item.nameSegments, !segments.isEmpty {
                            coloredText(segments).font(.system(size: 16, weight: .medium))
                        } else {
                            Text(item.plainName)
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(.blue)
                        }
                        Text("×\(item.count)")
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Một chạm vào ... mở tooltip/lore ngay, không mở menu trung gian.
            Button {
                reliableActionTitle = item.plainName
                selectedItemActionTarget = .window(item)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.blue)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 48)
    }

    private func defaultMouseButton(for item: MCOpenWindowItem) -> UInt8 {
        let name = item.plainName.lowercased()
        let lore = item.loreSegments
            .flatMap { $0 }
            .map(\.text)
            .joined(separator: " ")
            .lowercased()
        let hint = name + " " + lore
        if hint.contains("chuột phải") || hint.contains("chuot phai") ||
           hint.contains("right click") || hint.contains("right-click") {
            return 1
        }
        return 0
    }

    private struct MovementCoordinateLabel: View {
        let client: MCClient
        var body: some View {
            TimelineView(.periodic(from: .now, by: 0.10)) { _ in
                Text(String(format: "X=%.2f Y=%.2f Z=%.2f", client.playerX, client.playerY, client.playerZ))
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .transaction { tx in tx.animation = nil }
        }
    }

    /// Màn di chuyển thật bằng UIKit controls ổn định. Không có SwiftUI timer/state rebuild
    /// trong vùng WASD nên ngón tay giữ phím không bị mất touch.
    private var movementScreen: some View {
        StableMovementControllerView(client: client)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
    }

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
                            VStack(alignment: .leading, spacing: 2) {
                                if let segments = item.nameSegments, !segments.isEmpty {
                                    coloredText(segments).font(.system(size: 17))
                                } else {
                                    Text(item.plainName).foregroundStyle(.blue)
                                }
                                Text("×\(item.count)")
                                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                if let selected = client.playerInventory[slot] {
                                    reliableActionTitle = selected.plainName
                                    selectedItemActionTarget = .inventory(slot)
                                }
                            } label: {
                                Image(systemName: "ellipsis")
                                    .font(.headline.weight(.bold))
                                    .foregroundStyle(.blue)
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
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

    private enum ItemActionTarget: Identifiable {
        case window(MCOpenWindowItem)
        case inventory(Int)
        var id: String {
            switch self {
            case .window(let item): return "window-\(item.slot)"
            case .inventory(let slot): return "inventory-\(slot)"
            }
        }
    }

    private func itemActionSheet(for target: ItemActionTarget) -> some View {
        NavigationStack {
            VStack(spacing:0) {
                actionRow("Display lore", "text.book.closed") {
                    switch target {
                    case .window(let item): selectedItemActionTarget=nil; DispatchQueue.main.async { tooltipWindowItem=item }
                    case .inventory(let slot):
                        guard let item=client.playerInventory[slot] else { return }
                        selectedItemActionTarget=nil; DispatchQueue.main.async { tooltipItem=item }
                    }
                }
                Divider().overlay(Color.white.opacity(0.08))
                actionRow("Left click", "cursorarrow.click") {
                    switch target {
                    case .window(let item): client.clickWindowSlot(item.slot, mouseButton:0)
                    case .inventory(let slot): client.clickInventorySlot(slot, mouseButton:0)
                    }
                    selectedItemActionTarget=nil
                }
                Divider().overlay(Color.white.opacity(0.08))
                actionRow("Right click", "cursorarrow.click.2") {
                    switch target {
                    case .window(let item): client.clickWindowSlot(item.slot, mouseButton:1)
                    case .inventory(let slot): client.clickInventorySlot(slot, mouseButton:1)
                    }
                    selectedItemActionTarget=nil
                }
                Divider().overlay(Color.white.opacity(0.08))
                actionRow("Drop all", "arrow.down.to.line.compact", destructive:true) {
                    switch target {
                    case .window(let item): client.dropAllFromWindowSlot(item.slot)
                    case .inventory(let slot): client.dropAllFromInventorySlot(slot)
                    }
                    selectedItemActionTarget=nil
                }
                Spacer(minLength:0)
            }
            .background(Color(red:0.08,green:0.08,blue:0.09))
            .navigationTitle("Item actions")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func actionRow(_ title:String, _ icon:String, destructive:Bool=false, action:@escaping()->Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).frame(width: 24, height: 24)
                Text(title)
                    .font(.system(size: 17, weight: .medium))
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .foregroundStyle(destructive ? Color.red : Color.white)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .background(Color.white.opacity(0.001))
            .contentShape(Rectangle())
        }
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .contentShape(Rectangle())
        .buttonStyle(.plain)
    }

    private func chatHoverItemSheet(_ item: MCChatHoverItem) -> some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    if let legacy = item.legacyItemId, let image = resourcePack.image(for: MCItemSlot(hotbarIndex: -1, itemId: legacy, damage: item.damage, count: item.count, nameSegments: nil, loreSegments: [])) {
                        Image(uiImage: image)
                            .resizable()
                            .interpolation(.none)
                            .scaledToFit()
                            .frame(width: 56, height: 56)
                    } else {
                        Text(item.legacyItemId.map { mcItemEmoji(for: $0) } ?? "📦")
                            .font(.system(size: 42))
                            .frame(width: 56, height: 56)
                            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.displayName)
                            .font(.headline)
                            .foregroundStyle(.white)
                        Text("×\(item.count)")
                            .font(.subheadline.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(item.resourceName)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Divider().overlay(Color.white.opacity(0.12))
                if !item.enchantments.isEmpty {
                    Text("Enchantments")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                    ForEach(Array(item.enchantments.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.blue)
                    }
                }
                if item.lore.isEmpty {
                    Text("Không có Lore")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(item.lore.enumerated()), id: \.offset) { _, line in
                        coloredText(line)
                    }
                }
                Spacer()
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Đóng") { chatHoverItem = nil }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func itemTooltipSheet(name: String, segments: [MCChatSegment]?, lore: [[MCChatSegment]], image: UIImage?) -> some View {
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
                            Text(name).font(.headline).foregroundStyle(.white)
                        }
                    }
                    if lore.isEmpty {
                        Text("Không có Lore").foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(lore.enumerated()), id: \.offset) { _, line in
                            coloredText(line).foregroundStyle(.white)
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Display lore")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Đóng") { tooltipItem = nil; tooltipWindowItem = nil }
                }
            }
        }
        .preferredColorScheme(.dark)
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
        let token = input.split(whereSeparator: { $0.isWhitespace }).last.map(String.init) ?? ""
        guard !token.isEmpty else { return }
        client.requestTabCompletions(input)
        if let completed = client.completeWithNextPlayerName(input) {
            input = completed
        }
        showTabSuggestions = !client.tabCompletions.isEmpty
        inputFocused = true
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
        // Tin/lệnh do chính người dùng gửi luôn đưa transcript về cuối, kể cả trước đó
        // đang vuốt lên giữa chừng. Tin nhắn tự đến từ server thì vẫn chỉ auto-scroll
        // khi người dùng đang ở cuối.
        forceScrollToBottomToken &+= 1
    }

    @ViewBuilder
    private func logRow(_ entry: MCLogEntry) -> some View {
        ChatMessageText(
            text: entry.text,
            segments: entry.segments,
            onURLTap: { url in
                openURL(url)
            },
            onItemTap: { item in
                chatHoverItem = item
            }
        )
        .frame(maxWidth: .infinity, alignment: .leading)
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

final class MCKeyboardObserver: ObservableObject {
    @Published var height: CGFloat = 0
    private var tokens: [NSObjectProtocol] = []

    init() {
        let nc = NotificationCenter.default
        tokens.append(nc.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { [weak self] n in
            self?.update(n)
        })
        tokens.append(nc.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { [weak self] _ in
            self?.height = 0
        })
    }

    deinit {
        for t in tokens { NotificationCenter.default.removeObserver(t) }
    }

    private func update(_ notification: Notification) {
        guard let value = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue else { return }
        let frame = value.cgRectValue
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow }) else { return }
        let converted = window.convert(frame, from: nil)
        let overlap = max(0, window.bounds.maxY - converted.minY)
        height = max(0, overlap - window.safeAreaInsets.bottom)
    }
}

private struct ChatTranscriptTextView: UIViewRepresentable {
    let entries: [MCLogEntry]
    @Binding var isAtBottom: Bool
    let forceScrollToBottomToken: Int
    let onURLTap: (URL) -> Void
    let onItemTap: (MCChatHoverItem) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onURLTap: onURLTap, onItemTap: onItemTap)
    }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.backgroundColor = .black
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = true
        view.alwaysBounceVertical = true
        view.showsVerticalScrollIndicator = true
        view.indicatorStyle = .white
        view.scrollIndicatorInsets = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 1)
        view.showsHorizontalScrollIndicator = false
        view.textContainerInset = UIEdgeInsets(top: 4, left: 14, bottom: 4, right: 14)
        view.textContainer.lineFragmentPadding = 0
        view.textContainer.lineBreakMode = .byWordWrapping
        view.delegate = context.coordinator
        view.adjustsFontForContentSizeCategory = true
        view.linkTextAttributes = [:]
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)
        // Links keep the segment's original Minecraft color; only underline them.
        view.linkTextAttributes = [
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]
        return view
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.onURLTap = onURLTap
        context.coordinator.onItemTap = onItemTap
        let previousAtBottom = context.coordinator.isAtBottom
        let previousForceToken = context.coordinator.forceScrollToBottomToken
        context.coordinator.forceScrollToBottomToken = forceScrollToBottomToken
        let shouldForceScroll = previousForceToken != forceScrollToBottomToken
        let signature = transcriptSignature()
        let contentChanged = signature != context.coordinator.transcriptSignature

        // CRITICAL: do not rebuild UITextView text on every SwiftUI update (typing one
        // character in the input bar used to rebuild the entire transcript and made the
        // scrollbar jump/jitter). Only touch the text storage when the chat itself changed.
        guard contentChanged || shouldForceScroll else { return }

        let previousOffset = uiView.contentOffset
        let wasEmpty = uiView.textStorage.length == 0
        let oldHeight = uiView.contentSize.height
        uiView.attributedText = makeTranscriptAttributedString()
        context.coordinator.transcriptSignature = signature

        DispatchQueue.main.async {
            uiView.layoutIfNeeded()
            uiView.layoutManager.ensureLayout(for: uiView.textContainer)

            if wasEmpty || shouldForceScroll {
                context.coordinator.scrollToBottom(uiView, animated: false)
                context.coordinator.isAtBottom = true
                return
            }

            guard contentChanged else { return }

            // Reading older chat: keep the same visible text line. Do not snap to the
            // bottom and do not recreate the viewport. The existing offset remains stable;
            // only clamp it if the content shrank because the 500-line cap removed entries.
            if !previousAtBottom {
                let maxY = max(-uiView.adjustedContentInset.top, uiView.contentSize.height - uiView.bounds.height + uiView.adjustedContentInset.bottom)
                let clampedY = min(max(previousOffset.y, -uiView.adjustedContentInset.top), maxY)
                uiView.setContentOffset(CGPoint(x: previousOffset.x, y: clampedY), animated: false)
                context.coordinator.isAtBottom = false
                return
            }

            // At the bottom: new messages push older messages upward, exactly like a chat
            // transcript. Keep the scrollbar at the latest line.
            context.coordinator.scrollToBottom(uiView, animated: false)
            context.coordinator.isAtBottom = true
            _ = oldHeight
        }
    }

    private func transcriptSignature() -> String {
        entries.map { entry in
            let segmentText = entry.segments?.map { segment in
                "\(segment.text)|\(segment.colorHex ?? "")|\(segment.bold)|\(segment.italic)|\(segment.underline)|\(segment.strikethrough)|\(segment.linkURL ?? "")|\(segment.hoverItem?.resourceName ?? "")|\(segment.hoverItem?.count ?? 0)"
            }.joined(separator: "~") ?? entry.text
            return "\(entry.id.uuidString):\(entry.kind):\(segmentText)"
        }.joined(separator: "\n")
    }

    private func makeTranscriptAttributedString() -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (index, entry) in entries.enumerated() {
            let message = (entry.segments?.isEmpty == false) ? attributedMessage(entry.segments!) : NSAttributedString(string: entry.text, attributes: [
                .font: UIFont.systemFont(ofSize: 18),
                .foregroundColor: entry.kind == .error ? UIColor.systemRed : UIColor.white
            ])
            result.append(message)
            if index < entries.count - 1 {
                // ChatCraft-style separator between messages. Keep it thin and compact so
                // the transcript reads as one continuous chat list rather than separate cards.
                result.append(NSAttributedString(string: "\n────────────────────────────────────────\n", attributes: [
                    .font: UIFont.systemFont(ofSize: 9, weight: .regular),
                    .foregroundColor: UIColor.white.withAlphaComponent(0.14)
                ]))
            }
        }

        let fullText = result.string
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let range = NSRange(location: 0, length: (fullText as NSString).length)
            detector.enumerateMatches(in: fullText, options: [], range: range) { match, _, _ in
                guard let url = match?.url, let matchRange = match?.range else { return }
                if result.attribute(.link, at: matchRange.location, effectiveRange: nil) == nil {
                    result.addAttribute(.mcInteractive, value: url, range: matchRange)
                }
                result.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: matchRange)
                if let color = result.attribute(.foregroundColor, at: matchRange.location, effectiveRange: nil) {
                    result.addAttribute(.underlineColor, value: color, range: matchRange)
                }
            }
        }
        result.enumerateAttribute(.mcInteractive, in: NSRange(location: 0, length: result.length)) { value, range, _ in
            if value != nil {
                result.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
                if let color = result.attribute(.foregroundColor, at: range.location, effectiveRange: nil) {
                    result.addAttribute(.underlineColor, value: color, range: range)
                }
            }
        }
        return result
    }

    private func attributedMessage(_ segments: [MCChatSegment]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for segment in segments {
            var traits: UIFontDescriptor.SymbolicTraits = []
            if segment.bold { traits.insert(.traitBold) }
            if segment.italic { traits.insert(.traitItalic) }
            let descriptor = UIFont.systemFont(ofSize: 18).fontDescriptor.withSymbolicTraits(traits) ?? UIFont.systemFont(ofSize: 18).fontDescriptor
            var attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont(descriptor: descriptor, size: 18),
                .foregroundColor: UIColor(segment.colorHex.flatMap(Color.init(hex:)) ?? .white)
            ]
            if segment.underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if segment.strikethrough { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = segment.linkURL.flatMap(URL.init(string:)) {
                attrs[.mcInteractive] = link
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
                attrs[.underlineColor] = attrs[.foregroundColor] ?? UIColor.white
            } else if let hover = segment.hoverItem, let encoded = encodeHoverItemURL(hover) {
                attrs[.mcInteractive] = encoded
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
                attrs[.underlineColor] = attrs[.foregroundColor] ?? UIColor.white
            }
            result.append(NSAttributedString(string: segment.text, attributes: attrs))
        }
        return result
    }

    final class Coordinator: NSObject, UITextViewDelegate, UIScrollViewDelegate {
        var onURLTap: (URL) -> Void
        var onItemTap: (MCChatHoverItem) -> Void
        var isAtBottom = true
        var forceScrollToBottomToken = 0
        var transcriptSignature = ""

        init(onURLTap: @escaping (URL) -> Void, onItemTap: @escaping (MCChatHoverItem) -> Void) {
            self.onURLTap = onURLTap
            self.onItemTap = onItemTap
        }

        func scrollToBottom(_ textView: UITextView, animated: Bool) {
            let insetBottom = textView.adjustedContentInset.bottom
            let maxY = max(-textView.adjustedContentInset.top, textView.contentSize.height - textView.bounds.height + insetBottom)
            textView.setContentOffset(CGPoint(x: textView.contentOffset.x, y: maxY), animated: animated)
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            let visibleBottom = scrollView.contentOffset.y + scrollView.bounds.height - scrollView.adjustedContentInset.bottom
            let contentBottom = scrollView.contentSize.height
            isAtBottom = contentBottom <= 0 || visibleBottom >= contentBottom - 24
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            // Selection is intentionally left enabled across the whole transcript.
            // Native iOS Select All/Copy now works for every message at once.
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let textView = recognizer.view as? UITextView else { return }
            let location = recognizer.location(in: textView)
            let point = CGPoint(x: location.x - textView.textContainerInset.left,
                                 y: location.y - textView.textContainerInset.top)
            let charIndex = textView.layoutManager.characterIndex(for: point, in: textView.textContainer,
                                                                    fractionOfDistanceBetweenInsertionPoints: nil)
            guard charIndex < textView.attributedText.length else { return }
            if let value = textView.attributedText.attribute(.mcInteractive, at: charIndex, effectiveRange: nil) as? URL {
                if let item = decodeHoverItemURL(value) { onItemTap(item) } else { onURLTap(value) }
            }
        }

        func textView(_ textView: UITextView, shouldInteractWith URL: URL, in characterRange: NSRange) -> Bool {
            if let item = decodeHoverItemURL(URL) {
                onItemTap(item)
            } else {
                onURLTap(URL)
            }
            return false
        }

        @available(iOS 10.0, *)
        func textView(_ textView: UITextView, shouldInteractWith URL: URL, in characterRange: NSRange, interaction: UITextItemInteraction) -> Bool {
            if let item = decodeHoverItemURL(URL) {
                onItemTap(item)
            } else {
                onURLTap(URL)
            }
            return false
        }
    }
}

private func encodeHoverItemURL(_ item: MCChatHoverItem) -> URL? {
    var object: [String: Any] = [
        "resourceName": item.resourceName,
        "displayName": item.displayName,
        "count": item.count,
        "damage": Int(item.damage),
        "enchantments": item.enchantments,
        "lore": item.lore.map { line in
            line.map { seg in
                [
                    "text": seg.text,
                    "colorHex": seg.colorHex as Any,
                    "bold": seg.bold,
                    "italic": seg.italic,
                    "underline": seg.underline,
                    "strikethrough": seg.strikethrough
                ]
            }
        }
    ]
    if let legacy = item.legacyItemId { object["legacyItemId"] = Int(legacy) }
    if let raw = item.rawValue { object["rawValue"] = raw }
    guard let data = try? JSONSerialization.data(withJSONObject: object),
          let base64 = data.base64EncodedString().addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
    return URL(string: "minecraft-item://show/\(base64)")
}

private func decodeHoverItemURL(_ url: URL) -> MCChatHoverItem? {
    guard url.scheme == "minecraft-item", url.host == "show" else { return nil }
    let encoded = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard let decoded = encoded.removingPercentEncoding,
          let data = Data(base64Encoded: decoded),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let resourceName = object["resourceName"] as? String,
          let displayName = object["displayName"] as? String else { return nil }
    let count = object["count"] as? Int ?? 1
    let damage = Int16(object["damage"] as? Int ?? 0)
    let legacy = (object["legacyItemId"] as? Int).map(Int16.init)
    let enchantments = object["enchantments"] as? [String] ?? []
    var lore: [[MCChatSegment]] = []
    if let rawLore = object["lore"] as? [[String: Any]] {
        lore = rawLore.map { dict in
            [MCChatSegment(text: dict["text"] as? String ?? "",
                           colorHex: dict["colorHex"] as? String,
                           bold: dict["bold"] as? Bool ?? false,
                           italic: dict["italic"] as? Bool ?? false,
                           underline: dict["underline"] as? Bool ?? false,
                           strikethrough: dict["strikethrough"] as? Bool ?? false)]
        }
    } else if let rawLoreLines = object["lore"] as? [[[String: Any]]] {
        lore = rawLoreLines.map { line in
            line.map { dict in
                MCChatSegment(text: dict["text"] as? String ?? "", colorHex: dict["colorHex"] as? String,
                               bold: dict["bold"] as? Bool ?? false, italic: dict["italic"] as? Bool ?? false,
                               underline: dict["underline"] as? Bool ?? false, strikethrough: dict["strikethrough"] as? Bool ?? false)
            }
        }
    }
    return MCChatHoverItem(resourceName: resourceName, displayName: displayName, count: count, legacyItemId: legacy, damage: damage, lore: lore, enchantments: enchantments, rawValue: object["rawValue"] as? String)
}

private extension NSAttributedString.Key {
    static let mcInteractive = NSAttributedString.Key("MCInteractiveURL")
}

private struct ChatMessageText: UIViewRepresentable {
    let text: String
    let segments: [MCChatSegment]?
    let onURLTap: (URL) -> Void
    let onItemTap: (MCChatHoverItem) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onURLTap: onURLTap, onItemTap: onItemTap) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.backgroundColor = .clear
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.showsVerticalScrollIndicator = false
        view.showsHorizontalScrollIndicator = false
        view.linkTextAttributes = [:]
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.textContainer.lineBreakMode = .byWordWrapping
        view.delegate = context.coordinator
        view.adjustsFontForContentSizeCategory = true
        return view
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.onURLTap = onURLTap
        context.coordinator.onItemTap = onItemTap
        uiView.attributedText = makeAttributedString()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        return uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    }

    private func makeAttributedString() -> NSAttributedString {
        let result = NSMutableAttributedString()
        let baseSegments = (segments?.isEmpty == false) ? segments! : [MCChatSegment(text: text)]
        var fullText = ""

        for segment in baseSegments {
            let part = segment.text
            let nsRange = NSRange(location: result.length, length: (part as NSString).length)
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font(for: segment),
                .foregroundColor: UIColor(segment.colorHex.flatMap(Color.init(hex:)) ?? .white)
            ]
            if segment.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if segment.strikethrough { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let linkString = segment.linkURL, let link = URL(string: linkString) {
                attributes[.mcInteractive] = link
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                attributes[.underlineColor] = attributes[.foregroundColor] ?? UIColor.white
            } else if let hover = segment.hoverItem, let encoded = encodeHoverItemURL(hover) {
                attributes[.mcInteractive] = encoded
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                attributes[.underlineColor] = attributes[.foregroundColor] ?? UIColor.white
            }
            result.append(NSAttributedString(string: part, attributes: attributes))
            fullText += part
            _ = nsRange
        }

        // Tự nhận diện URL trong chat và gạch chân để người dùng biết có thể click.
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let range = NSRange(location: 0, length: (fullText as NSString).length)
            detector.enumerateMatches(in: fullText, options: [], range: range) { match, _, _ in
                guard let url = match?.url, let matchRange = match?.range else { return }
                result.addAttribute(.mcInteractive, value: url, range: matchRange)
                result.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: matchRange)
                if let color = result.attribute(.foregroundColor, at: matchRange.location, effectiveRange: nil) {
                    result.addAttribute(.underlineColor, value: color, range: matchRange)
                }
            }
        }
        return result
    }

    private func font(for segment: MCChatSegment) -> UIFont {
        var traits: UIFontDescriptor.SymbolicTraits = []
        if segment.bold { traits.insert(.traitBold) }
        if segment.italic { traits.insert(.traitItalic) }
        let descriptor = UIFont.systemFont(ofSize: 18).fontDescriptor.withSymbolicTraits(traits) ?? UIFont.systemFont(ofSize: 18).fontDescriptor
        return UIFont(descriptor: descriptor, size: 18)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var onURLTap: (URL) -> Void
        var onItemTap: (MCChatHoverItem) -> Void
        init(onURLTap: @escaping (URL) -> Void, onItemTap: @escaping (MCChatHoverItem) -> Void) {
            self.onURLTap = onURLTap
            self.onItemTap = onItemTap
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let textView = recognizer.view as? UITextView else { return }
            let location = recognizer.location(in: textView)
            let point = CGPoint(x: location.x - textView.textContainerInset.left,
                                 y: location.y - textView.textContainerInset.top)
            let charIndex = textView.layoutManager.characterIndex(for: point, in: textView.textContainer,
                                                                    fractionOfDistanceBetweenInsertionPoints: nil)
            guard charIndex < textView.attributedText.length else { return }
            if let value = textView.attributedText.attribute(.mcInteractive, at: charIndex, effectiveRange: nil) as? URL {
                if let item = decodeHoverItemURL(value) { onItemTap(item) } else { onURLTap(value) }
            }
        }

        func textView(_ textView: UITextView, shouldInteractWith URL: URL, in characterRange: NSRange) -> Bool {
            if let item = decodeHoverItemURL(URL) { onItemTap(item) } else { onURLTap(URL) }
            return false
        }

        @available(iOS 10.0, *)
        func textView(_ textView: UITextView, shouldInteractWith URL: URL, in characterRange: NSRange, interaction: UITextItemInteraction) -> Bool {
            if let item = decodeHoverItemURL(URL) { onItemTap(item) } else { onURLTap(URL) }
            return false
        }
    }
}

private struct HoldButton: UIViewRepresentable {
    let title: String
    let action: () -> Void
    var onHold: (() -> Void)? = nil
    var onRelease: (() -> Void)? = nil

    func makeUIView(context: Context) -> TouchHoldUIButton {
        let button = TouchHoldUIButton(type: .system)
        button.titleLabel?.font = .systemFont(ofSize: 18, weight: .bold)
        button.setTitle(title, for: .normal)
        button.setTitleColor(.systemBlue, for: .normal)
        button.backgroundColor = UIColor.white.withAlphaComponent(0.12)
        button.layer.cornerRadius = 12
        button.isUserInteractionEnabled = true
        button.isExclusiveTouch = true
        button.layer.borderWidth = 1
        button.layer.borderColor = UIColor.white.withAlphaComponent(0.18).cgColor
        button.clipsToBounds = true
        button.repeatInterval = 0.05
        button.onTouchDown = {
            if let onHold { onHold() } else { action() }
        }
        button.onRepeat = {
            onHold?()
        }
        button.onTouchUp = {
            onRelease?()
        }
        return button
    }

    func updateUIView(_ uiView: TouchHoldUIButton, context: Context) {
        uiView.setTitle(title, for: .normal)
        uiView.onTouchDown = {
            if let onHold { onHold() } else { action() }
        }
        uiView.onRepeat = { onHold?() }
        uiView.onTouchUp = { onRelease?() }
    }
}

/// UIKit touch-down/up control. SwiftUI DragGesture can lose a touch when the
/// view is inside ScrollView/Navigation containers; UIButton receives the actual
/// finger-down event reliably, which is important for WASD and Jump.
final class TouchHoldUIButton: UIButton {
    var onTouchDown: (() -> Void)?
    var onRepeat: (() -> Void)?
    var onTouchUp: (() -> Void)?
    var repeatInterval: TimeInterval = 0.05
    private var repeatTimer: Timer?
    private var isHolding = false

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        guard !isHolding else { return }
        isHolding = true
        backgroundColor = UIColor.systemBlue.withAlphaComponent(0.55)
        onTouchDown?()
        guard onRepeat != nil else { return }
        repeatTimer?.invalidate()
        let timer = Timer(timeInterval: repeatInterval, repeats: true) { [weak self] _ in
            self?.onRepeat?()
        }
        repeatTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        finishTouch()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        finishTouch()
    }

    private func finishTouch() {
        guard isHolding else { return }
        isHolding = false
        repeatTimer?.invalidate()
        repeatTimer = nil
        backgroundColor = UIColor.white.withAlphaComponent(0.12)
        onTouchUp?()
    }

    deinit {
        repeatTimer?.invalidate()
    }
}


// MARK: - Stable WASD / SPACE controller

private struct StableMovementControllerView: UIViewRepresentable {
    let client: MCClient

    func makeUIView(context: Context) -> StableMovementPad {
        let pad = StableMovementPad()
        pad.attach(client: client)
        return pad
    }

    func updateUIView(_ uiView: StableMovementPad, context: Context) {
        uiView.attach(client: client)
    }
}

private final class StableMovementPad: UIView {
    private weak var client: MCClient?
    private let stack = UIStackView()
    private let topRow = UIStackView()
    private let bottomRow = UIStackView()
    private let spaceButton = UIButton(type: .system)
    private let coordLabel = UILabel()
    private var buttons: [UIButton: (Double, Double)] = [:]
    private var repeatTimers: [UIButton: Timer] = [:]
    private var activeIDs = Set<ObjectIdentifier>()
    private var coordinateTimer: Timer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    deinit {
        coordinateTimer?.invalidate()
        repeatTimers.values.forEach { $0.invalidate() }
    }

    func attach(client: MCClient) {
        self.client = client
        if coordinateTimer == nil {
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.updateCoordinates() }
            coordinateTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        updateCoordinates()
    }

    private func setup() {
        backgroundColor = .black
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 8
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16)
        ])

        topRow.axis = .horizontal
        topRow.spacing = 8
        bottomRow.axis = .horizontal
        bottomRow.spacing = 8
        stack.addArrangedSubview(topRow)
        stack.addArrangedSubview(bottomRow)

        let w = makeMoveButton("↑", 1, 0)
        topRow.addArrangedSubview(spacer())
        topRow.addArrangedSubview(w)
        topRow.addArrangedSubview(spacer())

        bottomRow.addArrangedSubview(makeMoveButton("←", 0, -1))
        bottomRow.addArrangedSubview(makeMoveButton("↓", -1, 0))
        bottomRow.addArrangedSubview(makeMoveButton("→", 0, 1))

        style(spaceButton, title: "Jump", size: 18)
        spaceButton.widthAnchor.constraint(equalToConstant: 132).isActive = true
        spaceButton.heightAnchor.constraint(equalToConstant: 54).isActive = true
        spaceButton.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        spaceButton.addTarget(self, action: #selector(spaceDown), for: .touchDown)
        spaceButton.addTarget(self, action: #selector(spaceUp), for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
        stack.addArrangedSubview(spaceButton)

        coordLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        coordLabel.textColor = .secondaryLabel
        coordLabel.textAlignment = .center
        coordLabel.numberOfLines = 2
        stack.addArrangedSubview(coordLabel)

        let hint = UILabel()
        hint.text = "W A S D để di chuyển • SPACE để jump"
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .secondaryLabel
        hint.textAlignment = .center
        stack.addArrangedSubview(hint)
    }

    private func spacer() -> UIView {
        let v = UIView()
        v.widthAnchor.constraint(equalToConstant: 72).isActive = true
        return v
    }

    private func style(_ button: UIButton, title: String, size: CGFloat) {
        button.setTitle(title, for: .normal)
        button.setTitleColor(.white, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: size, weight: .semibold)
        button.backgroundColor = UIColor.clear
        button.layer.cornerRadius = 12
        button.layer.borderWidth = 0
        button.adjustsImageWhenHighlighted = false
    }

    private func makeMoveButton(_ title: String, _ forward: Double, _ strafe: Double) -> UIButton {
        let button = UIButton(type: .system)
        style(button, title: title, size: 22)
        button.widthAnchor.constraint(equalToConstant: 54).isActive = true
        button.heightAnchor.constraint(equalToConstant: 54).isActive = true
        buttons[button] = (forward, strafe)
        button.addTarget(self, action: #selector(moveDown(_:)), for: .touchDown)
        button.addTarget(self, action: #selector(moveUp(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
        return button
    }

    @objc private func moveDown(_ sender: UIButton) {
        guard let client, let vector = buttons[sender] else { return }
        let id = ObjectIdentifier(sender)
        guard activeIDs.insert(id).inserted else { return }
        sender.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.55)
        client.startMoving(forward: vector.0, strafe: vector.1)
    }

    @objc private func moveUp(_ sender: UIButton) {
        guard let client, let vector = buttons[sender] else { return }
        let id = ObjectIdentifier(sender)
        guard activeIDs.remove(id) != nil else { return }
        sender.backgroundColor = UIColor.white.withAlphaComponent(0.12)
        client.stopMoving(forward: vector.0, strafe: vector.1)
    }

    @objc private func spaceDown() {
        spaceButton.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.55)
        client?.jumpPlayer()
    }

    @objc private func spaceUp() {
        spaceButton.backgroundColor = UIColor.white.withAlphaComponent(0.12)
    }

    private func updateCoordinates() {
        guard let client else { return }
        coordLabel.text = String(format: "X=%.2f  Y=%.2f  Z=%.2f\nYaw=%.1f  Pitch=%.1f", client.playerX, client.playerY, client.playerZ, client.playerYaw, client.playerPitch)
    }
}
