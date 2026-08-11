import SwiftUI
import UIKit

extension Color {
    init?(hex: String) {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        self = Color(red: r, green: g, blue: b)
    }
}

struct MCChatView: View {
    let profile: MCServerProfile
    @EnvironmentObject var accountStore: MCAccountStore
    @EnvironmentObject var historyStore: MCChatHistoryStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var client = MCClient()
    @StateObject private var resourcePack = MCResourcePackStore.shared
    @State private var input = ""
    @State private var inputFocused = false
    @State private var showPlayers = false
    @State private var showTools = false
    @State private var showControls = false
    @State private var showStatus = false
    @State private var tooltipItem: MCItemSlot?
    @State private var tooltipWindowItem: MCOpenWindowItem?

    private var account: MCAccount? { accountStore.account(for: profile.accountId) }

    var body: some View {
        VStack(spacing: 0) {
            if showControls {
                controlsView
            } else {
                chatView
            }
        }
        .background(Color(.systemBackground).ignoresSafeArea())
        .navigationTitle(profile.name)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.headline.weight(.semibold))
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 14) {
                    // Chat = quay về màn chat từ màn điều khiển.
                    if showControls {
                        Button { showControls = false } label: {
                            Image(systemName: "message.fill")
                        }
                    } else {
                        // Gamepad = mở WASD/JUMP ở màn hình riêng, không chiếm chỗ chat.
                        Button { showControls = true } label: {
                            Image(systemName: "gamecontroller.fill")
                        }
                    }

                    Button { showPlayers = true } label: {
                        Image(systemName: "person.3.fill")
                    }
                    .disabled(client.state != .connected)

                    Button { showStatus = true } label: {
                        Image(systemName: "cross.case.fill")
                    }
                    .disabled(client.state != .connected)

                    Button { showTools = true } label: {
                        Image(systemName: "briefcase.fill")
                    }
                    .disabled(client.state != .connected)
                }
            }
        }
        .sheet(isPresented: $showPlayers) { playerListSheet }
        .sheet(isPresented: $showStatus) { statusSheet }
        .sheet(isPresented: $showTools) { toolsSheet }
        .sheet(item: $tooltipItem) { item in
            itemTooltipSheet(name: item.plainName, segments: item.nameSegments,
                             lore: item.loreSegments, image: resourcePack.image(for: item))
        }
        .sheet(item: $tooltipWindowItem) { item in
            itemTooltipSheet(name: item.plainName, segments: item.nameSegments,
                             lore: item.loreSegments, image: resourcePack.image(for: item),
                             windowAction: { mouseButton in
                                 client.clickWindowSlot(item.slot, mouseButton: mouseButton)
                                 tooltipWindowItem = nil
                             })
        }
        .onChange(of: input) { newValue in
            // Không gửi Tab-Complete packet mỗi lần người dùng gõ ký tự.
            // Một số proxy/plugin server xử lý Tab Complete rất chặt và có thể
            // ngắt kết nối nếu nhận liên tiếp khi lệnh chưa hoàn chỉnh.
            // Chỉ yêu cầu completion khi người dùng thật sự bấm TAB.
            if !newValue.hasPrefix("/") {
                client.tabCompletions = []
            }
        }
        .onAppear {
            guard client.state == .disconnected else { return }
            guard let account else {
                client.appendUserInfo("Chưa chọn Minecraft username cho server này.")
                return
            }
            client.connect(host: profile.host, port: profile.port, username: account.username)
        }
        .task {
            await resourcePack.ensureVanillaAssets()
        }
        .onDisappear {
            // Không disconnect khi quay về danh sách/app xuống nền. Chỉ disconnect khi người dùng bấm Ngắt.
        }
    }

    private var chatView: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(client.log) { entry in
                            logRow(entry).id(entry.id)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)
                    .padding(.bottom, 8)
                }
                .background(Color(.systemBackground))
                .onChange(of: client.log.count) { _ in
                    if let last = client.log.last {
                        historyStore.append(last)
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            Divider()

            VStack(spacing: 5) {
                if client.state == .connected && !client.tabCompletions.isEmpty && input.hasPrefix("/") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(client.tabCompletions.prefix(10), id: \.self) { name in
                                Button(name) {
                                    input = replaceLastToken(in: input, with: name)
                                    inputFocused = true
                                }
                                .buttonStyle(.bordered)
                                .font(.caption)
                            }
                        }
                        .padding(.horizontal, 8)
                    }
                }

                HStack(spacing: 8) {
                    Button("TAB") { completeTab() }
                        .font(.headline)
                        .foregroundStyle(.blue)

                    MCTabTextField(text: $input, isFocused: $inputFocused,
                                   placeholder: "Message...",
                                   onSubmit: sendMessage,
                                   onTab: completeTab,
                                   movementEnabled: false,
                                   onMoveKey: { _ in })
                        .disabled(client.state != .connected)
                        .frame(height: 40)

                    Button { sendMessage() } label: {
                        Image(systemName: "paperplane.fill")
                            .font(.title3)
                    }
                    .disabled(client.state != .connected || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
            .background(Color(.systemBackground))
        }
    }

    private var controlsView: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 22) {
                Text("Điều khiển")
                    .font(.title2.weight(.bold))

                HStack(alignment: .center, spacing: 22) {
                    movementPad
                    Button { client.jumpPlayer() } label: {
                        Text("JUMP")
                            .font(.subheadline.weight(.bold))
                            .frame(width: 76, height: 76)
                    }
                    .buttonStyle(.borderedProminent)
                }

                VStack(spacing: 4) {
                    Text(String(format: "X=%.2f   Y=%.2f   Z=%.2f", client.playerX, client.playerY, client.playerZ))
                        .font(.system(.callout, design: .monospaced))
                    Text("\(client.currentDimension) · \(client.isOnGroundLabel)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }

    private var movementPad: some View {
        // D-pad cố định 3x2 để W/A/S/D luôn thẳng hàng trên mọi iPhone.
        let keySize: CGFloat = 36
        let gap: CGFloat = 4
        return VStack(spacing: gap) {
            HStack(spacing: gap) {
                Color.clear.frame(width: keySize, height: keySize)
                moveButton("W", forward: 1, strafe: 0, size: keySize)
                Color.clear.frame(width: keySize, height: keySize)
            }
            HStack(spacing: gap) {
                moveButton("A", forward: 0, strafe: -1, size: keySize)
                moveButton("S", forward: -1, strafe: 0, size: keySize)
                moveButton("D", forward: 0, strafe: 1, size: keySize)
            }
        }
        .frame(width: keySize * 3 + gap * 2, height: keySize * 2 + gap)
    }

    private func moveButton(_ title: String, forward: Double, strafe: Double, size: CGFloat) -> some View {
        Button { client.movePlayer(forward: forward, strafe: strafe) } label: {
            Text(title)
                .font(.subheadline.weight(.bold))
                .frame(width: size, height: size)
                .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
    }

    // MARK: - Briefcase: inventory / GUI / vị trí

    private var toolsSheet: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    chatCraftInventorySection(title: "HAND", slots: 0..<9) { index in
                        client.hotbar[index]
                    } action: { index, item in
                        client.useHotbarItem(index)
                    }

                    chatCraftInventorySection(title: "INVENTORY", slots: 9..<36) { slot in
                        client.playerInventory[slot]
                    } action: { _, item in
                        tooltipItem = item
                    }

                    chatCraftInventorySection(title: "ARMOR", slots: 5..<9) { slot in
                        client.playerInventory[slot]
                    } action: { _, item in
                        tooltipItem = item
                    }

                    if let window = client.currentWindow {
                        chatCraftWindowSection(window)
                    }

                    positionSummary
                        .padding(.bottom, 18)
                }
                .padding(.horizontal, 34)
                .padding(.top, 12)
            }
            .scrollIndicators(.visible)
        }
        .preferredColorScheme(.dark)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("‹") { showTools = false }
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(.white)
            }
            ToolbarItem(placement: .principal) {
                Text("Tôi Chơi Network")
                    .font(.headline)
                    .foregroundStyle(.white)
            }
        }
    }

    @ViewBuilder
    private func chatCraftInventorySection(
        title: String,
        slots: Range<Int>,
        itemAt: @escaping (Int) -> MCItemSlot?,
        action: @escaping (Int, MCItemSlot) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Color(white: 0.68))
                .padding(.leading, 34)

            VStack(spacing: 0) {
                ForEach(Array(slots), id: \.self) { slot in
                    chatCraftItemRow(itemAt(slot), action: action, slot: slot)
                    if slot != slots.upperBound - 1 {
                        Rectangle()
                            .fill(Color(white: 0.18))
                            .frame(height: 1)
                            .padding(.leading, 68)
                    }
                }
            }
            .background(Color(red: 0.115, green: 0.115, blue: 0.125))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    @ViewBuilder
    private func chatCraftWindowSection(_ window: MCOpenWindow) -> some View {
        let count = max(window.slotCount, (window.items.keys.max() ?? -1) + 1)
        VStack(alignment: .leading, spacing: 10) {
            Text(window.title.isEmpty ? "GUI" : window.title)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Color(white: 0.68))
                .padding(.leading, 34)

            VStack(spacing: 0) {
                ForEach(0..<count, id: \.self) { slot in
                    let item = window.items[slot]
                    chatCraftWindowItemRow(item, slot: slot)
                    if slot != count - 1 {
                        Rectangle()
                            .fill(Color(white: 0.18))
                            .frame(height: 1)
                            .padding(.leading, 68)
                    }
                }
            }
            .background(Color(red: 0.115, green: 0.115, blue: 0.125))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    @ViewBuilder
    private func chatCraftItemRow(
        _ item: MCItemSlot?,
        action: @escaping (Int, MCItemSlot) -> Void,
        slot: Int
    ) -> some View {
        HStack(spacing: 16) {
            if let item {
                Button {
                    action(slot, item)
                } label: {
                    chatCraftItemIcon(item)
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 2) {
                    if let segments = item.nameSegments, !segments.isEmpty {
                        coloredText(segments)
                            .font(.system(size: 20, weight: .medium))
                    } else {
                        Text(item.plainName)
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(.blue)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(red: 0.19, green: 0.19, blue: 0.21))
                    .frame(width: 68, height: 68)
                Spacer()
            }

            Menu {
                if let item {
                    Button("Chuột trái") { action(slot, item) }
                    Button("Chuột phải") { tooltipItem = item }
                    Button("Xem tooltip / Lore") { tooltipItem = item }
                } else {
                    Button("Ô trống") {}
                        .disabled(true)
                }
            } label: {
                Text("•••")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.blue)
                    .frame(width: 42, height: 68)
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 82)
    }

    @ViewBuilder
    private func chatCraftWindowItemRow(_ item: MCOpenWindowItem?, slot: Int) -> some View {
        HStack(spacing: 16) {
            if let item {
                Button {
                    client.clickWindowSlot(item.slot, mouseButton: 0)
                } label: {
                    chatCraftWindowItemIcon(item)
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 2) {
                    if let segments = item.nameSegments, !segments.isEmpty {
                        coloredText(segments)
                            .font(.system(size: 20, weight: .medium))
                    } else {
                        Text(item.plainName)
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(.blue)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(red: 0.19, green: 0.19, blue: 0.21))
                    .frame(width: 68, height: 68)
                Spacer()
            }

            Menu {
                if let item {
                    Button("Chuột trái") { client.clickWindowSlot(item.slot, mouseButton: 0) }
                    Button("Chuột phải") { client.clickWindowSlot(item.slot, mouseButton: 1) }
                    Button("Xem tooltip / Lore") { tooltipWindowItem = item }
                } else {
                    Button("Ô trống") {}.disabled(true)
                }
            } label: {
                Text("•••")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.blue)
                    .frame(width: 42, height: 68)
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 82)
    }

    @ViewBuilder
    private func chatCraftWindowItemIcon(_ item: MCOpenWindowItem) -> some View {
        ZStack(alignment: .bottomTrailing) {
            if let image = resourcePack.image(for: item) {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .frame(width: 68, height: 68)
            } else {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(red: 0.19, green: 0.19, blue: 0.21))
                    .frame(width: 68, height: 68)
            }
        }
        .frame(width: 68, height: 68)
    }

    @ViewBuilder
    private func chatCraftItemIcon(_ item: MCItemSlot) -> some View {
        ZStack(alignment: .bottomTrailing) {
            if let image = resourcePack.image(for: item) {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .frame(width: 68, height: 68)
            } else {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(red: 0.19, green: 0.19, blue: 0.21))
                    .frame(width: 68, height: 68)
            }

            if item.count > 1 {
                Text("\(item.count)")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .black, radius: 1, x: 0, y: 1)
                    .padding(.trailing, 3)
                    .padding(.bottom, 1)
            }
        }
        .frame(width: 68, height: 68)
    }

    private var positionSummary: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Vị trí")
                .font(.headline)
                .foregroundStyle(.white)
            Text(String(format: "X=%.2f   Y=%.2f   Z=%.2f", client.playerX, client.playerY, client.playerZ))
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(.white)
            Text("Map: \(client.currentDimension) · \(client.isOnGroundLabel)")
                .font(.footnote)
                .foregroundStyle(.gray)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(red: 0.115, green: 0.115, blue: 0.125), in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Inventory + GUI rows

    @ViewBuilder
    private func inventoryRows(slots: ClosedRange<Int>, emptyText: String) -> some View {
        let items = slots.compactMap { slot in client.playerInventory[slot].map { (slot, $0) } }
        if items.isEmpty {
            Text(emptyText).foregroundStyle(.secondary)
        } else {
            ForEach(items, id: \.0) { _, item in
                itemActionRow(item: item) {
                    tooltipItem = item
                } rightClick: {
                    tooltipItem = item
                } more: {
                    tooltipItem = item
                }
            }
        }
    }

    @ViewBuilder
    private func itemActionRow(item: MCItemSlot,
                               leftClick: @escaping () -> Void,
                               rightClick: @escaping () -> Void,
                               more: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Button(action: leftClick) { itemVisual(item: item) }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Chuột trái") { leftClick() }
                    Button("Chuột phải") { rightClick() }
                    Button("Xem tooltip / Lore") { more() }
                }
            Spacer()
            Menu {
                Button("Chuột trái") { leftClick() }
                Button("Chuột phải") { rightClick() }
                Button("Xem tooltip / Lore") { more() }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .foregroundStyle(.blue)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func itemActionRow(item: MCOpenWindowItem,
                               leftClick: @escaping () -> Void,
                               rightClick: @escaping () -> Void,
                               more: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Button(action: leftClick) {
                itemVisual(itemId: item.itemId, damage: item.damage,
                           segments: item.nameSegments, plainName: item.plainName)
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("Chuột trái") { leftClick() }
                Button("Chuột phải") { rightClick() }
                Button("Xem tooltip / Lore") { more() }
            }
            Spacer()
            Menu {
                Button("Chuột trái") { leftClick() }
                Button("Chuột phải") { rightClick() }
                Button("Xem tooltip / Lore") { more() }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .foregroundStyle(.blue)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func itemVisual(item: MCItemSlot) -> some View {
        itemVisual(itemId: item.itemId, damage: item.damage,
                   segments: item.nameSegments, plainName: item.plainName, count: item.count)
    }

    @ViewBuilder
    private func itemVisual(itemId: Int16, damage: Int16,
                            segments: [MCChatSegment]?, plainName: String,
                            count: Int? = nil) -> some View {
        HStack(spacing: 10) {
            if let image = resourcePack.image(for: MCItemSlot(hotbarIndex: -1, itemId: itemId, damage: damage,
                                                              count: count ?? 1, nameSegments: segments)) {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .frame(width: 42, height: 42)
            } else {
                Image(systemName: "cube.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(width: 42, height: 42)
            }
            VStack(alignment: .leading, spacing: 2) {
                if let segments, !segments.isEmpty { coloredText(segments) } else { Text(plainName) }
                if let count, count > 1 {
                    Text("x\(count)").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func itemTooltipSheet(name: String, segments: [MCChatSegment]?, lore: [[MCChatSegment]], image: UIImage?, windowAction: ((UInt8) -> Void)? = nil) -> some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        if let image {
                            Image(uiImage: image).resizable().interpolation(.none).scaledToFit().frame(width: 64, height: 64)
                        } else {
                            Image(systemName: "cube.fill").font(.largeTitle).foregroundStyle(.secondary).frame(width: 64, height: 64)
                        }
                        if let segments, !segments.isEmpty { coloredText(segments).font(.headline) } else { Text(name).font(.headline) }
                    }
                    if lore.isEmpty {
                        Text("Không có Lore").foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(lore.enumerated()), id: \.offset) { _, line in coloredText(line) }
                    }
                    if let windowAction {
                        HStack {
                            Button("Chuột trái") { windowAction(0) }.buttonStyle(.borderedProminent)
                            Button("Chuột phải") { windowAction(1) }.buttonStyle(.bordered)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Tooltip")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) { Button("Đóng") { tooltipItem = nil; tooltipWindowItem = nil } }
            }
        }
    }

    // MARK: - Trạng thái người chơi

    private var statusSheet: some View {
        NavigationStack {
            VStack(spacing: 22) {
                VStack(spacing: 10) {
                    Text("Máu").font(.headline)
                    HStack(spacing: 4) {
                        ForEach(0..<10, id: \.self) { index in
                            Image(systemName: heartSymbol(index: index, value: client.health))
                                .foregroundStyle(.red)
                                .font(.title3)
                        }
                    }
                    Text(String(format: "%.1f / 20 HP", client.health))
                        .font(.caption).foregroundStyle(.secondary)
                }

                VStack(spacing: 10) {
                    Text("Thức ăn").font(.headline)
                    HStack(spacing: 4) {
                        ForEach(0..<10, id: \.self) { index in
                            Image(systemName: foodSymbol(index: index, value: client.food))
                                .foregroundStyle(.orange)
                                .font(.title3)
                        }
                    }
                    Text("\(client.food) / 20 · saturation \(String(format: "%.1f", client.foodSaturation))")
                        .font(.caption).foregroundStyle(.secondary)
                }

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
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Đóng") { showStatus = false }
                }
            }
        }
    }

    private func heartSymbol(index: Int, value: Float) -> String {
        let hearts = max(0, min(10, Int(ceil(value / 2.0))))
        return index < hearts ? "heart.fill" : "heart"
    }

    private func foodSymbol(index: Int, value: Int) -> String {
        let meat = max(0, min(10, Int(ceil(Double(value) / 2.0))))
        return index < meat ? "fork.knife.circle.fill" : "fork.knife.circle"
    }

    // MARK: - Players / connection / chat

    private var playerListSheet: some View {
        NavigationStack {
            List {
                Section("Online · \(client.onlinePlayerNames.count)") {
                    ForEach(client.onlinePlayerNames.sorted { $0.lowercased() < $1.lowercased() }, id: \.self) { name in
                        HStack {
                            Image(systemName: "person.fill").foregroundStyle(.secondary)
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
    }

    private func completeTab() {
        guard client.state == .connected else { return }
        if let completed = client.completeWithNextPlayerName(input) {
            input = completed
            inputFocused = true
            client.requestTabCompletions(input)
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
            coloredText(segments).font(.system(.subheadline))
        } else {
            Text(entry.text)
                .font(.system(.subheadline))
                .foregroundStyle(entry.kind == .info ? .secondary : .primary)
                .textSelection(.enabled)
        }
    }

    private func coloredText(_ segments: [MCChatSegment]) -> Text {
        segments.reduce(Text("")) { partial, seg in
            var t = Text(seg.text).foregroundColor(seg.colorHex.flatMap(Color.init(hex:)) ?? .primary)
            if seg.bold { t = t.bold() }
            if seg.italic { t = t.italic() }
            if seg.strikethrough { t = t.strikethrough() }
            if seg.underline { t = t.underline() }
            return partial + t
        }
    }
}

