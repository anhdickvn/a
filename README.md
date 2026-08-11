# ChatMinecraft

Bản này giữ nguyên toàn bộ logic kết nối/server của bản trước. Chỉ sửa lỗi CI/Xcode project generation:

- `project.yml` tạo project tên `ChatMinecraft.xcodeproj`.
- Workflow dùng đúng `ChatMinecraft.xcodeproj` thay vì `Minecraft.xcodeproj`.
- Sau khi chạy XcodeGen, workflow kiểm tra project và `project.pbxproj` tồn tại trước khi archive.
- Target/scheme vẫn là `Minecraft`; tên hiển thị ứng dụng vẫn là `ChatMinecraft`.
- Không thay đổi `MCClient.swift` hay logic protocol/đăng nhập/click GUI.
