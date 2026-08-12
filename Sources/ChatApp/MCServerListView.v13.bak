import UIKit
import SwiftUI

/// ChatCraft-style home screen: accounts and servers are plain rows, no horizontal
/// paging UI. The selected account is the one used when a server row is opened.
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

    private var selectedAccount: MCAccount? {
        accountStore.account(for: selectedAccountId) ?? accountStore.accounts.first
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if accountStore.accounts.isEmpty {
                        HStack(spacing: 16) {
                            Image(systemName: "person.crop.circle.badge.plus")
                                .font(.system(size: 42))
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Chưa có tài khoản")
                                    .font(.headline)
                                Text("Nhấn + để thêm username")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .frame(minHeight: 150)
                    } else {
                        ForEach(accountStore.accounts) { account in
                            accountRow(account, isSelected: account.id == selectedAccount?.id)
                                .contentShape(Rectangle())
                                .onTapGesture { selectedAccountId = account.id }
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) { deleteAccount = account } label: {
                                        Label("Xóa", systemImage: "trash")
                                    }
                                    Button { editingAccount = account } label: {
                                        Label("Sửa", systemImage: "pencil")
                                    }
                                    .tint(.blue)
                                }
                        }
                    }
                } header: {
                    HStack {
                        Text("Accounts")
                        Spacer()
                        Button { showAddAccount = true } label: {
                            Image(systemName: "plus")
                        }
                    }
                }

                Section {
                    if store.profiles.isEmpty {
                        Text("Chưa có server. Nhấn + để thêm.")
                            .foregroundStyle(.secondary)
                            .frame(minHeight: 90)
                    } else {
                        ForEach(store.profiles) { profile in
                            NavigationLink {
                                MCChatView(profile: profileForSelectedAccount(profile))
                            } label: {
                                serverRow(profile)
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) { deleteProfile = profile } label: {
                                    Label("Xóa", systemImage: "trash")
                                }
                                Button { editingProfile = profile } label: {
                                    Label("Sửa", systemImage: "pencil")
                                }
                                .tint(.blue)
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("Servers")
                        Spacer()
                        Button { showAdd = true } label: {
                            Image(systemName: "plus")
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("ChatCraft")
            .sheet(isPresented: $showAddAccount) {
                MCAccountEditView(account: MCAccount(username: "")) { newAccount in
                    accountStore.accounts.append(newAccount)
                    selectedAccountId = newAccount.id
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
                        name: "Server",
                        host: "",
                        port: 25565,
                        accountId: selectedAccount?.id,
                        autoLogin: false
                    )
                ) { newProfile in
                    store.profiles.append(newProfile)
                    statusStore.refresh(newProfile)
                }
                .environmentObject(accountStore)
            }
            .sheet(item: $editingProfile) { profile in
                MCServerEditView(profile: profile) { updated in
                    if let index = store.profiles.firstIndex(where: { $0.id == updated.id }) {
                        store.profiles[index] = updated
                        statusStore.refresh(updated)
                    }
                }
                .environmentObject(accountStore)
            }
            .confirmationDialog("Xóa username này?", isPresented: Binding(
                get: { deleteAccount != nil }, set: { if !$0 { deleteAccount = nil } }
            ), titleVisibility: .visible) {
                Button("Xóa", role: .destructive) {
                    if let account = deleteAccount {
                        accountStore.accounts.removeAll { $0.id == account.id }
                        if selectedAccountId == account.id { selectedAccountId = accountStore.accounts.first?.id }
                        for index in store.profiles.indices where store.profiles[index].accountId == account.id {
                            store.profiles[index].accountId = nil
                        }
                    }
                    deleteAccount = nil
                }
                Button("Hủy", role: .cancel) { deleteAccount = nil }
            }
            .confirmationDialog("Xóa server này?", isPresented: Binding(
                get: { deleteProfile != nil }, set: { if !$0 { deleteProfile = nil } }
            ), titleVisibility: .visible) {
                Button("Xóa", role: .destructive) {
                    if let profile = deleteProfile { store.profiles.removeAll { $0.id == profile.id } }
                    deleteProfile = nil
                }
                Button("Hủy", role: .cancel) { deleteProfile = nil }
            }
            .onAppear {
                // Migrate the exact proxy entry that older builds injected automatically.
                store.removeLegacyInjectedServer()
                if selectedAccountId == nil { selectedAccountId = accountStore.accounts.first?.id }
                statusStore.refreshAll(store.profiles)
            }
            .onChange(of: accountStore.accounts) { accounts in
                if let id = selectedAccountId, accounts.contains(where: { $0.id == id }) { return }
                selectedAccountId = accounts.first?.id
            }
            .onChange(of: store.profiles.count) { _ in statusStore.refreshAll(store.profiles) }
            .refreshable { statusStore.refreshAll(store.profiles) }
        }
    }

    private func accountRow(_ account: MCAccount, isSelected: Bool) -> some View {
        HStack(spacing: 18) {
            AsyncImage(url: URL(string: "https://mc-heads.net/avatar/\(account.username)/128")) { phase in
                if let image = phase.image {
                    image.resizable().interpolation(.none)
                } else {
                    Color.gray.opacity(0.25)
                }
            }
            .frame(width: 128, height: 128)
            .clipShape(RoundedRectangle(cornerRadius: 2))

            VStack(alignment: .leading, spacing: 6) {
                Text(account.username)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
            }
            Spacer()
        }
        .frame(minHeight: 158)
        .listRowInsets(EdgeInsets(top: 10, leading: 18, bottom: 10, trailing: 18))
        .listRowBackground(Color(uiColor: .secondarySystemGroupedBackground))
    }

    private func profileForSelectedAccount(_ profile: MCServerProfile) -> MCServerProfile {
        var copy = profile
        copy.accountId = selectedAccount?.id
        return copy
    }

    private func serverRow(_ profile: MCServerProfile) -> some View {
        let status = statusStore.status(for: profile.id)
        return HStack(alignment: .top, spacing: 18) {
            serverIcon(status)
                .frame(width: 128, height: 128)

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(profile.name)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    pingBadge(status)
                }

                // Keep the address internal to the saved profile. The home screen
                // follows ChatCraft's clean server tooltip: name + ping/player count + MOTD.
                switch status?.phase {
                case .online:
                    if let status, !status.motd.isEmpty {
                        Text(status.motd)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                case .offline(let reason):
                    Text(reason)
                        .font(.body)
                        .foregroundStyle(.red.opacity(0.85))
                        .lineLimit(2)
                case .loading, nil:
                    Text("Đang tải thông tin server…")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 158)
        .listRowInsets(EdgeInsets(top: 10, leading: 18, bottom: 10, trailing: 12))
        .listRowBackground(Color(uiColor: .secondarySystemGroupedBackground))
    }

    @ViewBuilder
    private func serverIcon(_ status: MCServerStatus?) -> some View {
        if let data = status?.faviconData, let uiImage = UIImage(data: data) {
            Image(uiImage: uiImage)
                .resizable()
                .interpolation(.none)
                .scaledToFill()
                .clipShape(RoundedRectangle(cornerRadius: 2))
        } else {
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 54))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.gray.opacity(0.22), in: RoundedRectangle(cornerRadius: 2))
        }
    }

    @ViewBuilder
    private func pingBadge(_ status: MCServerStatus?) -> some View {
        switch status?.phase {
        case .online:
            if let status {
                Text("Ping \(status.pingMs)   \(status.onlinePlayers)/\(status.maxPlayers)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(pingColor(status.pingMs))
            }
        case .offline:
            Text("Ping -1")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        case .loading, nil:
            ProgressView().scaleEffect(0.65)
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
                        Text("Hãy thêm username trước.").foregroundStyle(.secondary)
                    } else {
                        Picker("Username", selection: $profile.accountId) {
                            Text("Chưa chọn").tag(UUID?.none)
                            ForEach(accountStore.accounts) { account in
                                Text(account.username).tag(Optional(account.id))
                            }
                        }
                    }
                }
                Section {
                    Toggle("Autologin", isOn: $profile.autoLogin)
                    Text("Bật thì app mới tự gửi lệnh đăng nhập và chạy automation. Tắt thì server quyết định toàn bộ GUI/event.")
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
