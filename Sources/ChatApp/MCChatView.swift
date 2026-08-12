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

    private var account: MCAccount? { accountStore.account(for: profile.accountId) }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if showControls {
                controlsView
            } else {
                chatView
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
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white)
                }
            }
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button { showControls.toggle() } label: {
                    Image(systemName: showControls ? "message.fill" : "gamecontroller.fill")
                }
                Button { showPlayers = true } label: {
                    Image(systemName: "person.3.fill")
                }
                .disabled(client.state != .connected)
                Button { showStatus = true } label: {
                    Image(systemName: "cross.case.fill")
                }
                .disabled(client.state != .connected)
                Button { showInventory = true } label: {
                    Image(systemName: "briefcase.fill")
                }
                .disabled(client.state != .connected)
            }
        }
        .sheet(isPresented: $showPlayers) { playerListSheet }
        .sheet(isPresented: $showStatus) { statusSheet }
        .sheet(isPresented: $showInventory) { inventorySheet }
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
            guard !client.isConnectedTo(host: profile.host, port: profile.port, username: account.username) else { return }
            client.connect(host: profile.host, port: profile.port, username: account.username, autoLogin: profile.autoLogin)
        }
        .task { await resourcePack.ensureVanillaAssets() }
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
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
                    .padding(.bottom, 8)
                }
                .background(Color.black)
                .onChange(of: client.log.count) { _ in
                    if let last = client.log.last {
                        if last.kind == .chat { historyStore.append(last) }
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            if let window = client.currentWindow {
                serverWindowOverlay(window)
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

    private func serverWindowOverlay(_ window: MCOpenWindow) -> some View {
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
                Button("Close window") {
                    client.closeCurrentWindow()
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(Color.red.opacity(0.9), in: RoundedRectangle(cornerRadius: 8))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(window.items.values.sorted { $0.slot < $1.slot })) { item in
                        serverWindowRow(item)
                        Divider().overlay(Color.white.opacity(0.08))
                    }
                }
            }
            .frame(maxHeight: 280)
        }
        .background(Color(red: 0.08, green: 0.08, blue: 0.09))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.08)))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 8)
        .padding(.bottom, 5)
    }

    private func serverWindowRow(_ item: MCOpenWindowItem) -> some View {
        HStack(spacing: 10) {
            itemIcon(item)
            if let segments = item.nameSegments, !segments.isEmpty {
                coloredText(segments).font(.system(size: 17, weight: .medium))
            } else {
                Text(item.plainName)
                    .font(.system(size: 17, weight: .medium))
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
                    .frame(width: 36, height: 44)
            }
        }
        .padding(.horizontal, 10)
        .frame(minHeight: 56)
    }

    private var controlsView: some View {
        VStack(spacing: 24) {
            Spacer()
            HStack(spacing: 26) {
                movementPad
                HoldButton(title: "JUMP") { client.jumpPlayer() }
                    .frame(width: 78, height: 78)
            }
            Text("Chạm và giữ W/A/S/D để di chuyển")
                .font(.caption)
                .foregroundStyle(.secondary)
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

    private var inventorySheet: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 12) {
                        inventorySection("HOTBAR", slots: 36...44)
                        inventorySection("INVENTORY", slots: 9...35)
                        inventorySection("ARMOR", slots: 5...8)
                    }
                    .padding(12)
                }
            }
            .navigationTitle("Inventory")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Đóng") { showInventory = false }
                }
            }
        }
        .preferredColorScheme(.dark)
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
                        .frame(minHeight: 58)
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
                .frame(width: 48, height: 48)
        } else {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.white.opacity(0.08))
                .frame(width: 48, height: 48)
        }
    }

    @ViewBuilder
    private func itemIcon(_ item: MCOpenWindowItem) -> some View {
        if let image = resourcePack.image(for: item) {
            Image(uiImage: image)
                .resizable()
                .interpolation(.none)
                .scaledToFit()
                .frame(width: 48, height: 48)
        } else {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.white.opacity(0.08))
                .frame(width: 48, height: 48)
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

    private var statusSheet: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("Máu").font(.headline)
                HStack(spacing: 4) {
                    ForEach(0..<10, id: \.self) { i in
                        Image(systemName: i < Int(ceil(client.health / 2)) ? "heart.fill" : "heart")
                            .foregroundStyle(.red)
                    }
                }
                Text(String(format: "%.1f / 20 HP", client.health)).foregroundStyle(.secondary)
                Text("Thức ăn").font(.headline)
                Text("\(client.food) / 20").foregroundStyle(.secondary)
                Button { client.respawn() } label: {
                    Label("Respawn", systemImage: "arrow.clockwise.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(client.health > 0)
                Spacer()
            }
            .padding()
            .navigationTitle("Sinh tồn")
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Đóng") { showStatus = false } } }
        }
        .preferredColorScheme(.dark)
    }

    private var playerListSheet: some View {
        NavigationStack {
            List {
                Section("Online · \(client.onlinePlayerNames.count)") {
                    ForEach(client.onlinePlayerNames.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }, id: \.self) { name in
                        HStack {
                            Image(systemName: "person.fill").foregroundStyle(.blue)
                            Text(name).textSelection(.enabled)
                        }
                    }
                    if client.onlinePlayerNames.isEmpty {
                        Text("Chưa nhận được danh sách người chơi từ server.").foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Người chơi")
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Đóng") { showPlayers = false } } }
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
