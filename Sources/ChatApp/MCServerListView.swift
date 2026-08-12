import SwiftUI

struct MCServerListView: View {
    @StateObject private var store = MCProfileStore()
    @EnvironmentObject var accountStore: MCAccountStore
    @State private var showAdd = false
    @State private var showAddAccount = false
    @State private var editingProfile: MCServerProfile?
    @State private var editingAccount: MCAccount?
    @State private var deleteProfile: MCServerProfile?
    @State private var statuses: [UUID: MCServerStatus] = [:]
    @State private var isRefreshing = false
    @State private var isEditingAccounts = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        titleHeader
                        accountSection
                        serverSection
                    }
                    .padding(.bottom, 96)
                }
                .scrollIndicators(.hidden)
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showAddAccount) {
                MCAccountEditView(account: MCAccount(username: "")) { newAccount in
                    accountStore.accounts.append(newAccount)
                }
            }
            .sheet(item: $editingAccount) { account in
                MCAccountEditView(account: account) { updated in
                    if let index = accountStore.accounts.firstIndex(where: { $0.id == updated.id }) {
                        accountStore.accounts[index] = updated
                    }
                }
            }
            .sheet(isPresented: $showAdd) {
                MCServerEditView(
                    profile: MCServerProfile(name: "Tôi Chơi Network", host: "proxy.toichoi.com", port: 54321,
                                             useLogin: false, protocolVersion: 760)
                ) { newProfile in
                    store.profiles.append(newProfile)
                    refresh(profile: newProfile)
                }
                .environmentObject(accountStore)
            }
            .sheet(item: $editingProfile) { profile in
                MCServerEditView(profile: profile) { updated in
                    if let index = store.profiles.firstIndex(where: { $0.id == updated.id }) {
                        store.profiles[index] = updated
                        refresh(profile: updated)
                    }
                }
                .environmentObject(accountStore)
            }
            .confirmationDialog("Xóa server này?", isPresented: Binding(
                get: { deleteProfile != nil }, set: { if !$0 { deleteProfile = nil } }
            ), titleVisibility: .visible) {
                Button("Xóa", role: .destructive) {
                    if let profile = deleteProfile {
                        store.profiles.removeAll { $0.id == profile.id }
                        statuses.removeValue(forKey: profile.id)
                    }
                    deleteProfile = nil
                }
                Button("Hủy", role: .cancel) { deleteProfile = nil }
            }
            .onAppear {
                store.ensureDefaultServer()
                refreshAll()
            }
        }
    }

    private var titleHeader: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("ChatMinecraft")
                .font(.system(size: 30, weight: .bold, design: .default))
                .foregroundStyle(.white)
            HStack {
                Text("Accounts")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(.white)
                Spacer()
                Button {
                    withAnimation { isEditingAccounts.toggle() }
                } label: {
                    if isEditingAccounts {
                        Text("Done").font(.system(size: 16, weight: .semibold))
                    } else {
                        Image(systemName: "pencil")
                            .font(.system(size: 18, weight: .regular))
                    }
                }
                .disabled(accountStore.accounts.isEmpty)
                Button { showAddAccount = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 19, weight: .regular))
                }
            }
            .foregroundStyle(.blue)
            .padding(.top, 2)
        }
        .padding(.horizontal, 20)
        .padding(.top, 22)
        .padding(.bottom, 14)
    }

    private var accountSection: some View {
        VStack(spacing: 0) {
            if accountStore.accounts.isEmpty {
                Button { showAddAccount = true } label: {
                    HStack(spacing: 14) {
                        MinecraftHeadView(username: "Steve")
                            .frame(width: 64, height: 64)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Add Minecraft account")
                                .font(.system(size: 17, weight: .semibold))
                            Text("Offline username")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                }
                .buttonStyle(.plain)
            } else {
                TabView(selection: Binding(
                    get: { accountStore.selectedAccountId ?? accountStore.accounts.first?.id },
                    set: { accountStore.selectedAccountId = $0 }
                )) {
                    ForEach(accountStore.accounts) { account in
                        accountCard(account).tag(Optional(account.id))
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: accountStore.accounts.count > 1 ? .automatic : .never))
                .frame(height: 100)
            }
        }
        .background(Color(red: 0.12, green: 0.12, blue: 0.13))
    }

    private func accountCard(_ account: MCAccount) -> some View {
        HStack(spacing: 14) {
            if isEditingAccounts {
                Button {
                    accountStore.accounts.removeAll { $0.id == account.id }
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
            MinecraftHeadView(username: account.username)
                .frame(width: 64, height: 64)
                .clipShape(Rectangle())
            VStack(alignment: .leading, spacing: 3) {
                Text(account.username)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                Text((accountStore.selectedAccountId ?? accountStore.accounts.first?.id) == account.id
                     ? "Đang dùng — vào server nào cũng dùng account này" : "Offline account")
                    .font(.system(size: 13))
                    .foregroundStyle((accountStore.selectedAccountId ?? accountStore.accounts.first?.id) == account.id ? .green : .secondary)
            }
            Spacer(minLength: 0)
            if isEditingAccounts {
                Button { editingAccount = account } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Color.blue, in: Circle())
                }
                .buttonStyle(.plain)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 24)
        .contentShape(Rectangle())
        .onTapGesture { if !isEditingAccounts { editingAccount = account } }
        .animation(.easeInOut(duration: 0.2), value: isEditingAccounts)
    }

    private var serverSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Servers")
                    .font(.system(size: 17))
                    .foregroundStyle(.white)
                Spacer()
                Button { editingProfile = store.profiles.first } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 18))
                }
                Button { showAdd = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 19))
                }
            }
            .foregroundStyle(.blue)
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)

            LazyVStack(spacing: 0) {
                ForEach(store.profiles) { profile in
                    SwipeToDeleteRow(onDelete: {
                        withAnimation {
                            store.profiles.removeAll { $0.id == profile.id }
                            statuses.removeValue(forKey: profile.id)
                        }
                    }) {
                        serverCard(profile)
                    }
                    Divider().overlay(Color.white.opacity(0.08))
                }
            }
        }
    }

    private func serverCard(_ profile: MCServerProfile) -> some View {
        let status = statuses[profile.id]
        return NavigationLink {
            MCChatView(profile: profile)
        } label: {
            HStack(alignment: .top, spacing: 14) {
                ServerFaviconView(image: status?.favicon)
                    .frame(width: 72, height: 72)
                    .padding(.top, 4)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(profile.name)
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                        if let status, status.online {
                            Text("Ping \(status.ping)  \(status.playersOnline)/\(status.playersMax)")
                                .font(.system(size: 12))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                        }
                    }

                    Text("\(profile.host):\(profile.port)")
                        .font(.system(size: 14))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)

                    if let status {
                        if status.online {
                            coloredMOTD(status.motd)
                                .font(.system(size: 13))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 1)
                        } else {
                            Text(status.error ?? "Server is offline.")
                                .font(.system(size: 13))
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        Text("Đang kiểm tra server…")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 6) {
                        if profile.useLogin {
                            Text("AUTO LOGIN")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.green)
                        }
                        if status?.online == true {
                            Text("ONLINE")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.green)
                        }
                    }
                    .padding(.top, 2)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 26)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { editingProfile = profile } label: { Label("Sửa server", systemImage: "pencil") }
            Button { refresh(profile: profile) } label: { Label("Kiểm tra lại", systemImage: "arrow.clockwise") }
            Button(role: .destructive) { deleteProfile = profile } label: { Label("Xóa", systemImage: "trash") }
        }
    }

    @ViewBuilder
    private func coloredMOTD(_ segments: [MCChatSegment]) -> some View {
        if segments.isEmpty {
            Text("")
        } else {
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

    private func refreshAll() {
        guard !isRefreshing else { return }
        isRefreshing = true
        let profiles = store.profiles
        Task {
            await withTaskGroup(of: (UUID, MCServerStatus).self) { group in
                for profile in profiles {
                    group.addTask {
                        (profile.id, await MCServerStatusService.shared.ping(profile: profile))
                    }
                }
                for await (id, status) in group {
                    await MainActor.run { statuses[id] = status }
                }
            }
            await MainActor.run { isRefreshing = false }
        }
    }

    private func refresh(profile: MCServerProfile) {
        Task {
            let status = await MCServerStatusService.shared.ping(profile: profile)
            await MainActor.run { statuses[profile.id] = status }
        }
    }
}

struct ServerFaviconView: View {
    let image: UIImage?
    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
            } else {
                Image(systemName: "shippingbox.fill")
                    .resizable()
                    .scaledToFit()
                    .padding(28)
                    .foregroundStyle(.secondary)
            }
        }
        .background(Color.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct MinecraftHeadView: View {
    let username: String
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().interpolation(.none).scaledToFit()
            } else {
                ZStack {
                    Rectangle().fill(Color(red: 0.48, green: 0.34, blue: 0.22))
                    HStack(spacing: 18) {
                        Rectangle().fill(.white).frame(width: 20, height: 20)
                            .overlay(Rectangle().fill(.black).frame(width: 8, height: 12))
                        Rectangle().fill(.white).frame(width: 20, height: 20)
                            .overlay(Rectangle().fill(.black).frame(width: 8, height: 12))
                    }
                }
            }
        }
        .task(id: username) {
            guard let encoded = username.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                  let url = URL(string: "https://mc-heads.net/avatar/\(encoded)/128") else { return }
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                if let decoded = UIImage(data: data) { image = decoded }
            } catch { }
        }
    }
}

struct MCServerEditView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var accountStore: MCAccountStore
    @State var profile: MCServerProfile
    let onSave: (MCServerProfile) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Thông tin server") {
                    TextField("Tên server", text: $profile.name)
                    TextField("Server IP / Domain", text: $profile.host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Port", value: $profile.port, format: .number)
                        .keyboardType(.numberPad)
                }
                Section {
                    Picker("Server version", selection: $profile.protocolVersion) {
                        ForEach(MCVersionOption.all) { option in
                            Text(option.label).tag(option.protocolVersion)
                        }
                    }
                } footer: {
                    Text("Nhiều server/proxy Việt Nam (BungeeCord/Waterfall + ViaVersion) chấp nhận nhiều version cùng lúc và tự dịch giao thức — MOTD/mcstatus có thể hiện version cũ (vd 1.7.x-1.9.x) chỉ mang tính hiển thị, không phải version bắt buộc phải chọn. Nếu không chắc, cứ để 1.19.2 (mặc định) vì đó là bản app hỗ trợ đầy đủ nhất; chỉ đổi sang version khác nếu 1.19.2 bị kick do sai protocol.")
                }
                Section("Đăng nhập tự động") {
                    Toggle("Sử dụng /login khi vào server", isOn: $profile.useLogin)
                    Text(profile.useLogin
                         ? "Bật: sau khi vào server app sẽ tự gửi /login bằng mật khẩu đã lưu, rồi chạy flow chuột phải la bàn / GUI."
                         : "Tắt: app chỉ kết nối và chờ server; không tự gửi lệnh đăng nhập hay tự click.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("Username dùng khi vào server này") {
                    if let current = accountStore.currentAccount {
                        Text("\(current.username) (account đang chọn ở màn danh sách server)")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Chưa có account nào — thêm ở màn danh sách server trước.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(profile.name.isEmpty ? "Thêm server" : "Sửa server")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Hủy") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Lưu") {
                        profile.name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
                        profile.host = profile.host.trimmingCharacters(in: .whitespacesAndNewlines)
                        onSave(profile)
                        dismiss()
                    }
                    .disabled(profile.name.isEmpty || profile.host.isEmpty)
                }
            }
        }
    }
}

// MARK: - Vuốt trái để hiện nút Delete (giống UITableView swipe-to-delete)

private struct SwipeToDeleteRow<Content: View>: View {
    let onDelete: () -> Void
    @ViewBuilder var content: () -> Content

    @State private var offset: CGFloat = 0
    @GestureState private var dragTranslation: CGFloat = 0

    private let deleteWidth: CGFloat = 90

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(role: .destructive, action: {
                withAnimation(.easeOut(duration: 0.2)) { offset = 0 }
                onDelete()
            }) {
                VStack(spacing: 4) {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 20))
                    Text("Delete")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.white)
                .frame(width: deleteWidth)
                .frame(maxHeight: .infinity)
                .background(Color.red)
            }
            .buttonStyle(.plain)

            content()
                .background(Color(red: 0.12, green: 0.12, blue: 0.13))
                .offset(x: min(0, offset + dragTranslation))
                .simultaneousGesture(
                    DragGesture(minimumDistance: 12)
                        .updating($dragTranslation) { value, state, _ in
                            // Chỉ cho vuốt sang trái, không cho kéo quá xa
                            guard value.translation.width < 0 else { return }
                            state = value.translation.width
                        }
                        .onEnded { value in
                            withAnimation(.easeOut(duration: 0.2)) {
                                if offset + value.translation.width < -deleteWidth / 2 {
                                    offset = -deleteWidth
                                } else {
                                    offset = 0
                                }
                            }
                        }
                )
        }
        .clipped()
    }
}
