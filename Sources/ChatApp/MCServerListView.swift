import UIKit
import SwiftUI

struct MCServerListView: View {
    @StateObject private var store = MCProfileStore()
    @StateObject private var statusStore = MCServerStatusStore()
    @EnvironmentObject var accountStore: MCAccountStore
    @State private var showAdd = false
    @State private var showAddAccount = false
    @State private var editingProfile: MCServerProfile?
    @State private var editingAccount: MCAccount?
    @State private var deleteProfile: MCServerProfile?
    @State private var deleteAccount: MCAccount?
    @State private var selectedAccountId: UUID?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if accountStore.accounts.isEmpty {
                        HStack(spacing: 12) {
                            Image(systemName: "person.crop.circle.badge.plus")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                            Text("Chưa có username")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Thêm") { showAddAccount = true }
                        }
                    } else {
                        TabView(selection: $selectedAccountId) {
                            ForEach(accountStore.accounts) { account in
                                VStack(spacing: 8) {
                                    HStack(spacing: 12) {
                                        accountHeadIcon(account.username)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(account.username).font(.body.weight(.semibold))
                                            Text("Minecraft username")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Button { editingAccount = account } label: { Image(systemName: "pencil") }
                                            .buttonStyle(.borderless)
                                        Button(role: .destructive) { deleteAccount = account } label: { Image(systemName: "trash") }
                                            .buttonStyle(.borderless)
                                    }
                                    Text("Kéo ngang để chọn username • Trang \(max(1, accountStore.accounts.firstIndex(of: account) ?? 0) + 1)/\(accountStore.accounts.count)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 6)
                                .tag(Optional(account.id))
                            }
                        }
                        .tabViewStyle(.page(indexDisplayMode: accountStore.accounts.count > 1 ? .automatic : .never))
                        .frame(height: 92)
                    }
                } header: {
                    HStack {
                        Text("Username")
                        Spacer()
                        Button { showAddAccount = true } label: { Image(systemName: "plus") }
                            .buttonStyle(.borderless)
                    }
                }

                Section {
                    if store.profiles.isEmpty {
                        Text("Chưa có server. Nhấn + để thêm.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(store.profiles) { profile in
                            HStack(spacing: 10) {
                                NavigationLink {
                                    MCChatView(profile: profileForSelectedAccount(profile))
                                } label: {
                                    serverRow(profile)
                                }
                                .buttonStyle(.plain)

                                Button { editingProfile = profile } label: {
                                    Image(systemName: "pencil")
                                        .font(.body.weight(.semibold))
                                }
                                .buttonStyle(.borderless)

                                Button(role: .destructive) {
                                    deleteProfile = profile
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("Servers")
                        Spacer()
                        Button { showAdd = true } label: { Image(systemName: "plus") }
                            .buttonStyle(.borderless)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("ChatCraft")
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
                    profile: MCServerProfile(
                        name: "Tôi Chơi NetWork",
                        host: "proxy.toichoi.com",
                        port: 54321,
                        accountId: accountStore.accounts.first?.id
                    )
                ) { newProfile in
                    store.profiles.append(newProfile)
                }
                .environmentObject(accountStore)
            }
            .sheet(item: $editingProfile) { profile in
                MCServerEditView(profile: profile) { updated in
                    if let index = store.profiles.firstIndex(where: { $0.id == updated.id }) {
                        store.profiles[index] = updated
                    }
                }
                .environmentObject(accountStore)
            }
            .confirmationDialog(
                "Xóa username này?",
                isPresented: Binding(
                    get: { deleteAccount != nil },
                    set: { if !$0 { deleteAccount = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Xóa", role: .destructive) {
                    if let account = deleteAccount {
                        accountStore.accounts.removeAll { $0.id == account.id }
                        for index in store.profiles.indices where store.profiles[index].accountId == account.id {
                            store.profiles[index].accountId = nil
                        }
                    }
                    deleteAccount = nil
                }
                Button("Hủy", role: .cancel) { deleteAccount = nil }
            }
            .confirmationDialog(
                "Xóa server này?",
                isPresented: Binding(
                    get: { deleteProfile != nil },
                    set: { if !$0 { deleteProfile = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Xóa", role: .destructive) {
                    if let profile = deleteProfile {
                        store.profiles.removeAll { $0.id == profile.id }
                    }
                    deleteProfile = nil
                }
                Button("Hủy", role: .cancel) { deleteProfile = nil }
            }
            .onAppear {
                store.ensureDefaultServer()
                if selectedAccountId == nil { selectedAccountId = accountStore.accounts.first?.id }
                statusStore.refreshAll(store.profiles)
            }
            .onChange(of: accountStore.accounts) { accounts in
                if let selectedAccountId, accounts.contains(where: { $0.id == selectedAccountId }) { }
                else { selectedAccountId = accounts.first?.id }
            }
            .onChange(of: store.profiles.count) { _ in
                statusStore.refreshAll(store.profiles)
            }
            .refreshable {
                statusStore.refreshAll(store.profiles)
            }
        }
    }

    /// Icon username "ở ngoài" — đầu skin thật (giống ChatCraft) thay vì chữ cái đầu,
    /// có fallback khi chưa tải xong / mất mạng.
    @ViewBuilder
    private func accountHeadIcon(_ username: String) -> some View {
        AsyncImage(url: URL(string: "https://mc-heads.net/avatar/\(username)/84")) { phase in
            if let image = phase.image {
                image.resizable().interpolation(.none)
            } else {
                Color.accentColor.opacity(0.18)
                    .overlay(Text(username.first.map(String.init)?.uppercased() ?? "?").font(.headline))
            }
        }
        .frame(width: 42, height: 42)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func profileForSelectedAccount(_ profile: MCServerProfile) -> MCServerProfile {
        var copy = profile
        if let selectedAccountId { copy.accountId = selectedAccountId }
        return copy
    }

    private func serverRow(_ profile: MCServerProfile) -> some View {
        let status = statusStore.status(for: profile.id)
        return HStack(alignment: .top, spacing: 12) {
            serverIcon(status)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(profile.name).font(.body.weight(.semibold))
                    Spacer()
                    pingBadge(status)
                }
                Text("\(profile.host):\(profile.port)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // "Tooltip" thông tin server: MOTD + số người chơi online, giống màn chọn
                // server thật, lấy từ 1 lần Status Ping riêng (statusStore), không đụng gì
                // tới phiên đăng nhập thật của MCClient.
                switch status?.phase {
                case .online:
                    if let status, !status.motd.isEmpty {
                        Text(status.motd)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                case .offline(let reason):
                    Text(reason)
                        .font(.caption2)
                        .foregroundStyle(.red.opacity(0.8))
                case .loading, nil:
                    Text("Đang lấy thông tin server...")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if let account = accountStore.account(for: profile.accountId) {
                    Text("👤 \(account.username)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Chưa chọn username")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func serverIcon(_ status: MCServerStatus?) -> some View {
        if let data = status?.faviconData, let uiImage = UIImage(data: data) {
            Image(uiImage: uiImage)
                .resizable()
                .interpolation(.none)
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            Image(systemName: "server.rack")
                .font(.title2)
                .frame(width: 48, height: 48)
                .foregroundStyle(.orange)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    /// Badge nhỏ góc phải kiểu "Ping 166   53/6767" trong tooltip server list thật.
    @ViewBuilder
    private func pingBadge(_ status: MCServerStatus?) -> some View {
        switch status?.phase {
        case .online:
            if let status {
                HStack(spacing: 6) {
                    Text("Ping \(status.pingMs)")
                    Text("\(status.onlinePlayers)/\(status.maxPlayers)")
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(pingColor(status.pingMs))
            }
        case .offline:
            Text("Offline")
                .font(.caption2)
                .foregroundStyle(.red)
        case .loading, nil:
            ProgressView()
                .scaleEffect(0.6)
        }
    }

    private func pingColor(_ ms: Int) -> Color {
        switch ms {
        case ..<100: return .green
        case ..<300: return .yellow
        default: return .red
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
                Section("Username dùng cho server này") {
                    if accountStore.accounts.isEmpty {
                        Text("Hãy thêm username trước.")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Username", selection: $profile.accountId) {
                            Text("Chưa chọn").tag(UUID?.none)
                            ForEach(accountStore.accounts) { account in
                                Text(account.username).tag(Optional(account.id))
                            }
                        }
                    }
                    Text("Bạn có thể sửa IP hoặc username của server hiện tại; app sẽ cập nhật hồ sơ này, không tạo server mới.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section {
                    Toggle("Autologin", isOn: $profile.autoLogin)
                    Text("Bật: vào server này xong app tự gửi \"/dn\", chờ rồi tự mở la bàn và chọn item cho bạn. Tắt: chỉ kết nối bình thường, không tự làm gì cả.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
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

struct MinecraftSkinView: View {
    let username: String
    var body: some View {
        ZStack {
            Color.brown.opacity(0.35)
            Image(systemName: "person.fill")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
        }
    }
}
