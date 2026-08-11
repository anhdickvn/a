# a

Bản iOS chat client Minecraft Java 1.12.x.

## Bản sửa này
- WASD + Jump bố trí dạng D-pad nhỏ, nằm ở màn điều khiển riêng; icon 💬 quay về chat và icon ← quay lại server list.
- Hiển thị X/Y/Z và trạng thái mặt đất.
- Giữ kết nối khi đưa app xuống nền bằng cơ chế background hiện có; iOS vẫn có thể dừng tiến trình trong một số trường hợp.
- Server/account có nút ✏️ sửa và 🗑️ xóa; sửa IP/port/username cập nhật hồ sơ hiện tại.
- GUI server hiển thị dạng danh sách item giống inventory list, có icon thật, tên, số lượng và menu `...`.
- Giữ login tự động, compass hotbar 5 và click Diamond Axe slot 23.
- Giữ Logs chỉ lưu chat server và mã màu.

## UI / movement / packet update
- WASD is rendered as a fixed 3x2 D-pad with a separate Jump button.
- Server and username records remain editable with pencil buttons and deletable with confirmation.
- Background connection is kept while iOS allows the app to run in the audio background mode; if the socket is lost, the client reconnects automatically when possible.

- Không còn mini-map; màn điều khiển chỉ tập trung vào WASD/JUMP và tọa độ.
- Tab Complete phía server được tắt để tránh proxy/plugin làm hỏng packet; /w, /r, /msg vẫn hoàn thành tên từ Player List ở phía client.
- Packet compression được kiểm tra chặt theo Data Length + zlib; packet lỗi không được parse nhầm như packet chưa nén.
