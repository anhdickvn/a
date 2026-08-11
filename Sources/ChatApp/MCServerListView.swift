import SwiftUI

struct MCServerListView: View {
    @StateObject private var store = MCProfileStore()
    @EnvironmentObject var accountStore: MCAccountStore
    @State private var showAdd = false
    @State private var showAddAccount = false
    @State private var editingProfile: MCServerProfile?
    @State private var editingAccount: MCAccount?
    @State private var deleteProfile: MCServerProfile?
    @State private var deleteAccount: MCAccount?

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
                        ForEach(accountStore.accounts) { account in
                            HStack(spacing: 12) {
                                Circle()
                                    .fill(Color.accentColor.opacity(0.18))
                                    .frame(width: 42, height: 42)
                                    .overlay(Text(account.initials).font(.headline))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(account.username).font(.body.weight(.semibold))
                                    Text("Minecraft username")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button { editingAccount = account } label: {
                                    Image(systemName: "pencil")
                                }
                                .buttonStyle(.borderless)
                                Button(role: .destructive) {
                                    deleteAccount = account
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                            }
                            .padding(.vertical, 4)
                        }
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
                                    MCChatView(profile: profile)
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
                        accountId: accountStore.accounts.first?.id,
                        useLogin: false
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
            .onAppear { store.ensureDefaultServer() }
        }
    }

    private func serverRow(_ profile: MCServerProfile) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "server.rack")
                .font(.title2)
                .frame(width: 42, height: 42)
                .foregroundStyle(.orange)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                Text(profile.name).font(.body.weight(.semibold))
                Text("\(profile.host):\(profile.port)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let account = accountStore.account(for: profile.accountId) {
                    Text("👤 \(account.username) • \(profile.useLogin ? "Auto /login" : "Không auto login")")
                        .font(.caption2)
                        .foregroundStyle(profile.useLogin ? .green : .secondary)
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
                Section("Đăng nhập tự động") {
                    Toggle("Sử dụng /login khi vào server", isOn: $profile.useLogin)
                    if profile.useLogin {
                        Text("Bật: sau khi vào server app sẽ tự gửi /login bằng mật khẩu đã lưu cho username này, rồi mới chạy flow chuột phải la bàn / GUI. Tắt: app không tự gửi /login và không tự click gì.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Tắt: app chỉ kết nối và chờ server; không tự gửi lệnh đăng nhập hay chuột phải.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
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
