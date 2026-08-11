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

struct MCChatView: View {
    let profile: MCServerProfile
    @EnvironmentObject var accountStore: MCAccountStore
    @EnvironmentObject var historyStore: MCChatHistoryStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var client = MCClient.shared
    @StateObject private var resourcePack = MCResourcePackStore.shared

    @State private var input = ""
    @State private var inputFocused = false
    @State private var showPlayers = false
    @State private var showControls = false
    @State private var showStatus = false
    @State private var showInventory = false
    @State private var tooltipItem: MCItemSlot?
    @State private var tooltipWindowItem: MCOpenWindowItem?
    @State private var sentMessages: [String] = []
    @State private var historyCursor: Int?

    private var account: MCAccount? { accountStore.account(for: profile.accountId) }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            mainContent
        }
        .preferredColorScheme(.dark)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbarBackground(Color.black, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white)
                }
            }
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button {
                    showControls.toggle()
                    if showControls { showPlayers = false; showStatus = false; showInventory = false }
                } label: {
                    Image(systemName: showControls ? "message.fill" : "gamecontroller.fill")
                }
                .accessibilityLabel("WASD và Jump")

                Button {
                    showPlayers.toggle()
                    if showPlayers { showControls = false; showStatus = false; showInventory = false }
                } label: {
                    Image(systemName: "person.3.fill")
                }
                .disabled(client.state != .connected)
                .accessibilityLabel("Player list")

                Button {
                    showStatus.toggle()
                    if showStatus { showControls = false; showPlayers = false; showInventory = false }
                } label: {
                    Image(systemName: "cross.case.fill")
                }
                .disabled(client.state != .connected)
                .accessibilityLabel("Máu, thức ăn và Respawn")

                Button {
                    showInventory.toggle()
                    if showInventory { showControls = false; showPlayers = false; showStatus = false }
                } label: {
                    Image(systemName: "briefcase.fill")
                }
                .disabled(client.state != .connected)
                .accessibilityLabel("Hotbar, Inventory và GUI server")
            }
        }
        // Display Lore là view phụ đúng kiểu ChatCraft: chỉ tên + icon + lore,
        // tuyệt đối không có nút Left/Right click ở dưới.
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
        }
        .onAppear {
            guard let account else {
                client.appendUserInfo("Chưa chọn Minecraft username cho server này.")
                return
            }
            // MCClient là singleton nên khi quay lại từ nút <, chat/player/inventory
            // và socket cũ vẫn còn nguyên. Không tạo kết nối thứ hai nếu phiên vẫn sống.
            guard !client.isConnectedTo(host: profile.host, port: profile.port, username: account.username) else { return }
            client.connect(host: profile.host, port: profile.port, username: account.username, useLogin: profile.useLogin)
        }
        // Chỉ khởi động tác vụ cache; tuyệt đối không await trước khi connect.
        .task(priority: .utility) { await resourcePack.ensureVanillaAssets() }
    }

    @ViewBuilder
    private var mainContent: some View {
        if showControls {
            controlsView
        } else if showPlayers {
            playerListView
        } else if showStatus {
            statusView
        } else if showInventory {
            inventoryView
        } else {
            chatView
        }
    }

    private var chatView: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(client.log) { entry in
                            logRow(entry).id(entry.id)
                        }
                    }
                    .padding(.horizontal, 30)
                    .padding(.top, 6)
                    .padding(.bottom, 8)
                }
                .background(Color.black)
                .onChange(of: client.log.last?.id) { _ in
                    if let last = client.log.last {
                        if last.kind == .chat {
                            historyStore.append(last, serverLabel: "\(profile.host):\(profile.port)")
                        }
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
                .onAppear {
                    // Re-entry từ < luôn kéo tới dòng chat mới nhất đang tồn tại,
                    // không bắt người dùng kéo lại từ đầu.
                    if let last = client.log.last {
                        DispatchQueue.main.async { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
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

    private var chatInputBar: some View {
        VStack(spacing: 4) {
            HStack(spacing: 42) {
                Button { showPreviousMessage() } label: {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 25, weight: .medium))
                        .foregroundStyle(.blue)
                        .frame(width: 44, height: 30)
                }
                .disabled(sentMessages.isEmpty)

                Button { showNextMessage() } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 25, weight: .medium))
                        .foregroundStyle(.blue)
                        .frame(width: 44, height: 30)
                }
                .disabled(sentMessages.isEmpty)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 1)

            HStack(spacing: 8) {
                Button("TAB") { completeTab() }
                    .font(.headline)
                    .foregroundStyle(.blue)
                    .frame(width: 48)

                MCTabTextField(text: $input, isFocused: $inputFocused, placeholder: "Message...",
                               onSubmit: sendMessage, onTab: completeTab, movementEnabled: false,
                               onMoveKey: { _ in })
                    .frame(height: 52)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.16), lineWidth: 1))
                    .disabled(client.state != .connected)

                Button { sendMessage() } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.blue)
                        .frame(width: 42, height: 52)
                }
                .disabled(client.state != .connected || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 2)
        .padding(.bottom, 6)
        .background(Color.black)
    }

    // MARK: - WASD + Jump

    private var controlsView: some View {
        VStack(spacing: 22) {
            HStack {
                Text("WASD + JUMP")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                Spacer()
                Text(client.isOnGroundLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)

            Spacer()

            HStack(spacing: 26) {
                movementPad
                HoldButton(title: "JUMP") { client.jumpPlayer() }
                    .frame(width: 86, height: 86)
            }

            Text("Chạm và giữ W/A/S/D để di chuyển. JUMP gửi packet nhảy thật.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }

    private var movementPad: some View {
        let size: CGFloat = 52
        let gap: CGFloat = 6
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

    // MARK: - Player list — nằm ngay trong màn ChatCraft, không mở sheet GUI riêng

    private var playerListView: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Players")
                                .font(.system(size: 24, weight: .bold))
                                .foregroundStyle(.white)
                            Text("Tổng online: \(client.onlinePlayerNames.count)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)

                    ForEach(client.onlinePlayerNames.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }, id: \.self) { name in
                        HStack(spacing: 14) {
                            MCPlayerAvatarView(uuid: client.playerUUIDByName[name], username: name)
                                .frame(width: 56, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: 5))

                            Text(name)
                                .font(.system(size: 19, weight: .regular))
                                .foregroundStyle(.white)
                                .textSelection(.enabled)
                            Spacer()
                        }
                        .padding(.horizontal, 18)
                        .frame(minHeight: 72)
                        Divider().overlay(Color.white.opacity(0.08))
                    }

                    if client.onlinePlayerNames.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "person.3.fill")
                                .font(.system(size: 32))
                                .foregroundStyle(.secondary)
                            Text("Chưa nhận được danh sách người chơi từ server.")
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 70)
                    }
                }
            }
        }
    }

    // MARK: - Health / food / respawn — cùng màn, không sheet

    private var statusView: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 8)
            Text("Player health")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(.white)

            HStack(spacing: 7) {
                ForEach(0..<10, id: \.self) { index in
                    Image(systemName: index < Int(ceil(client.health / 2)) ? "heart.fill" : "heart")
                        .font(.system(size: 26))
                        .foregroundStyle(.red)
                }
            }

            HStack(spacing: 9) {
                ForEach(0..<10, id: \.self) { index in
                    Text(index < Int(ceil(Double(client.food) / 2.0)) ? "🍗" : "·")
                        .font(.system(size: 24))
                        .opacity(index < Int(ceil(Double(client.food) / 2.0)) ? 1 : 0.25)
                }
            }

            Text(String(format: "%.1f / 20 HP", client.health))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Thức ăn: \(client.food) / 20")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button { client.respawn() } label: {
                Text("Respawn")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 14)
                    .background(Color.white.opacity(0.12), in: Rectangle())
            }
            .disabled(client.health > 0)
            .opacity(client.health > 0 ? 0.45 : 1)

            if client.health > 0 {
                Text("Respawn chỉ bật khi nhân vật đã chết.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }

    // MARK: - Backpack / hotbar / inventory / server GUI

    private var inventoryView: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ScrollView {
                if let window = client.currentWindow {
                    serverGUIContent(window)
                } else {
                    VStack(spacing: 12) {
                        inventorySection("HOTBAR", slots: 36...44)
                        inventorySection("INVENTORY", slots: 9...35)
                        inventorySection("ARMOR", slots: 5...8)
                    }
                    .padding(12)
                }
            }
        }
    }

    private func serverGUIContent(_ window: MCOpenWindow) -> some View {
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
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            LazyVStack(spacing: 0) {
                ForEach(Array(window.items.values.sorted { $0.slot < $1.slot })) { item in
                    serverWindowRow(item)
                    Divider().overlay(Color.white.opacity(0.08))
                }
            }
        }
        .background(Color(red: 0.08, green: 0.08, blue: 0.09), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.08)))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private func serverWindowRow(_ item: MCOpenWindowItem) -> some View {
        HStack(spacing: 10) {
            itemIcon(item)
            if let segments = item.nameSegments, !segments.isEmpty {
                coloredText(segments).font(.system(size: 16, weight: .medium))
            } else {
                Text(item.plainName)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.blue)
            }
            Spacer(minLength: 4)
            Button { tooltipWindowItem = item } label: {
                Image(systemName: "ellipsis")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.blue)
                    .frame(width: 32, height: 38)
            }
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 46)
        .contentShape(Rectangle())
        .onTapGesture {
            // GUI chọn server (Diamond Axe / Ice / hub...) = LEFT click.
            // Không cần mở "..."; "..." chỉ dành cho thao tác nâng cao.
            client.smartClickWindowItem(item)
        }
    }

    private func inventorySection(_ title: String, slots: ClosedRange<Int>) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
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
                        .frame(minHeight: 46)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            // Hotbar là thao tác gameplay: chạm item sẽ Use Item
                            // (RIGHT click). Các thao tác LEFT/Drop vẫn ở "...".
                            if (36...44).contains(slot) {
                                client.smartActivateHotbarItem(slot - 36)
                            }
                        }
                        Divider().overlay(Color.white.opacity(0.08))
                    }
                }
            }
            .background(Color(red: 0.08, green: 0.08, blue: 0.09), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    @ViewBuilder
    private func itemIcon(_ item: MCItemSlot) -> some View {
        if let image = resourcePack.image(for: item) {
            Image(uiImage: image)
                .resizable()
                .interpolation(.none)
                .scaledToFit()
                .frame(width: 36, height: 36)
        } else {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.white.opacity(0.08))
                .frame(width: 36, height: 36)
                .overlay {
                    if !resourcePack.vanillaReady { ProgressView().tint(.white) }
                }
        }
    }

    @ViewBuilder
    private func itemIcon(_ item: MCOpenWindowItem) -> some View {
        if let image = resourcePack.image(for: item) {
            Image(uiImage: image)
                .resizable()
                .interpolation(.none)
                .scaledToFit()
                .frame(width: 36, height: 36)
        } else {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.white.opacity(0.08))
                .frame(width: 36, height: 36)
                .overlay {
                    if !resourcePack.vanillaReady { ProgressView().tint(.white) }
                }
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
                            Text(name).font(.headline).foregroundStyle(.white)
                        }
                    }
                    if lore.isEmpty {
                        Text("Không có Lore").foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(lore.enumerated()), id: \.offset) { _, line in
                            coloredText(line)
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
        if sentMessages.last != text {
            sentMessages.append(text)
            if sentMessages.count > 100 { sentMessages.removeFirst(sentMessages.count - 100) }
        }
        historyCursor = nil
        input = ""
    }

    private func showPreviousMessage() {
        guard !sentMessages.isEmpty else { return }
        let next = max((historyCursor ?? sentMessages.count) - 1, 0)
        historyCursor = next
        input = sentMessages[next]
        inputFocused = true
    }

    private func showNextMessage() {
        guard !sentMessages.isEmpty else { return }
        guard let cursor = historyCursor else { return }
        if cursor + 1 < sentMessages.count {
            historyCursor = cursor + 1
            input = sentMessages[cursor + 1]
        } else {
            historyCursor = nil
            input = ""
        }
        inputFocused = true
    }

    @ViewBuilder
    private func logRow(_ entry: MCLogEntry) -> some View {
        if let segments = entry.segments, !segments.isEmpty {
            chatRichText(segments)
        } else {
            chatRichText([MCChatSegment(text: entry.text)])
        }
    }

    /// Hiển thị chat có màu Minecraft + link.
    /// URL được gắn bằng AttributedString nên chỉ phần URL mới có hit-area;
    /// chạm vào phần chat thường không mở bất kỳ action sheet nào.
    private func chatRichText(_ segments: [MCChatSegment]) -> some View {
        Text(makeChatAttributedString(segments))
            .font(.system(size: 17, weight: .regular))
            .lineSpacing(0.5)
            .textSelection(.enabled)
            .environment(\.openURL, OpenURLAction { url in
                guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
                    return .discarded
                }
                UIApplication.shared.open(url)
                return .handled
            })
    }

    private func makeChatAttributedString(_ segments: [MCChatSegment]) -> AttributedString {
        var result = AttributedString()
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

        for segment in segments {
            let text = segment.text
            guard !text.isEmpty else { continue }

            // Tôn trọng clickEvent=open_url của server. Nếu server chỉ gửi URL dạng text
            // (không có clickEvent), tự nhận diện http/https để vẫn mở được bằng một chạm.
            let explicitURL = segment.linkURL.flatMap(URL.init(string:))
            let matches: [NSTextCheckingResult] = {
                guard explicitURL == nil, let detector else { return [] }
                let ns = text as NSString
                return detector.matches(in: text, options: [], range: NSRange(location: 0, length: ns.length))
            }()

            if let explicitURL, let scheme = explicitURL.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                appendAttributedPart(text, to: &result, segment: segment, link: explicitURL)
            } else if !matches.isEmpty {
                let ns = text as NSString
                var cursor = 0
                for match in matches {
                    let range = match.range
                    if range.location > cursor {
                        appendAttributedPart(ns.substring(with: NSRange(location: cursor, length: range.location - cursor)),
                                              to: &result, segment: segment, link: nil)
                    }
                    if let url = match.url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                        appendAttributedPart(ns.substring(with: range), to: &result, segment: segment, link: url)
                    } else {
                        appendAttributedPart(ns.substring(with: range), to: &result, segment: segment, link: nil)
                    }
                    cursor = range.location + range.length
                }
                if cursor < ns.length {
                    appendAttributedPart(ns.substring(from: cursor), to: &result, segment: segment, link: nil)
                }
            } else {
                appendAttributedPart(text, to: &result, segment: segment, link: nil)
            }
        }
        return result
    }

    private func appendAttributedPart(_ text: String, to result: inout AttributedString,
                                      segment: MCChatSegment, link: URL?) {
        guard !text.isEmpty else { return }
        var part = AttributedString(text)
        var attrs = AttributeContainer()
        attrs.foregroundColor = segment.colorHex.flatMap(Color.init(hex:)) ?? .white
        if segment.bold { attrs.inlinePresentationIntent = .stronglyEmphasized }
        if segment.italic { attrs.inlinePresentationIntent = .emphasized }
        if segment.underline { attrs.underlineStyle = .single }
        if segment.strikethrough { attrs.strikethroughStyle = .single }
        if let link { attrs.link = link }
        part.mergeAttributes(attrs)
        result.append(part)
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

private struct MCPlayerAvatarView: View {
    let uuid: String?
    let username: String
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.white.opacity(0.08)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFill()
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: uuid ?? username) {
            let identifier = uuid ?? username
            let safeName = identifier.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "_", options: .regularExpression)
            let base = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("MCPlayerAvatars", isDirectory: true)
            if let base {
                try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
                let cached = base.appendingPathComponent(safeName + ".png")
                if let data = try? Data(contentsOf: cached), let decoded = UIImage(data: data) {
                    image = decoded
                    return
                }

                guard let encoded = identifier.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                      let url = URL(string: "https://mc-heads.net/avatar/\(encoded)/64") else { return }
                do {
                    let (data, _) = try await URLSession.shared.data(from: url)
                    guard let decoded = UIImage(data: data) else { return }
                    try? data.write(to: cached, options: .atomic)
                    image = decoded
                } catch { }
            }
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
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in beginHoldingOrTap() }
                    .onEnded { _ in endHolding() }
            )
            .onDisappear { endHolding() }
    }

    private func beginHoldingOrTap() {
        guard !isHolding else { return }
        if onHold == nil {
            action()
            return
        }
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
