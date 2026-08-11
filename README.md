# ChatMinecraft

Bản này giữ nguyên logic kết nối/server hiện tại. Chỉ sửa phần CI/Xcode project generation để khớp với lệnh build đang dùng.

- XcodeGen tạo `Minecraft.xcodeproj` từ `project.yml`.
- Workflow kiểm tra `Minecraft.xcodeproj/project.pbxproj` trước khi archive.
- Archive dùng `Minecraft.xcodeproj` và scheme `Minecraft`.
- Tên hiển thị ứng dụng vẫn là `ChatMinecraft`.
- Không thay đổi `MCClient.swift` hoặc logic protocol/đăng nhập/click GUI.


## v16 build fix
- Fixed MCServerStatus Data.append calls to use append(contentsOf:).
- Marked MCByteBuffer as @unchecked Sendable to avoid Swift 6 concurrency warning during Xcode 26 archive.
- CI verifies the exact source before generating Minecraft.xcodeproj, preventing an old MCServerStatus.swift from being built.
