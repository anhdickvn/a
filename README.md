# ChatMinecraft

Bản này giữ nguyên logic kết nối/server hiện tại. Chỉ sửa phần CI/Xcode project generation để khớp với lệnh build đang dùng.

- XcodeGen tạo `Minecraft.xcodeproj` từ `project.yml`.
- Workflow kiểm tra `Minecraft.xcodeproj/project.pbxproj` trước khi archive.
- Archive dùng `Minecraft.xcodeproj` và scheme `Minecraft`.
- Tên hiển thị ứng dụng vẫn là `ChatMinecraft`.
- Không thay đổi `MCClient.swift` hoặc logic protocol/đăng nhập/click GUI.
