# Minecraft-FIXED-UI-v27 — Chat scroll + 500 visible lines

- Không clear chat khi connect/reconnect/Join Game/timeout reconnect.
- Chat UI giữ tối đa 500 dòng để nhẹ máy.
- ChatLogs tiếp tục lưu lịch sử đầy đủ theo cơ chế archive hiện tại.
- Nếu đang ở sát đáy: chat mới tự cuộn xuống tin mới nhất.
- Nếu đang kéo lên đọc: chat mới không kéo viewport xuống.
- Gửi command (bắt đầu bằng `/`) luôn cuộn về tin mới nhất để thấy phản hồi.
- Không thay đổi protocol/network logic của v26.
- Chủ động Disconnect vẫn dùng flow clear phiên hiện tại như đã yêu cầu trước đó.
