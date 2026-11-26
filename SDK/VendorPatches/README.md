# Lưu trữ lịch sử patch FFmpeg

Thư mục này lưu source, patch, metadata cấu hình/hash và license của các lượt build cũ. Các hash trong `metadata.json` mô tả binary lịch sử, không chứng nhận bản FFmpeg thuần mới do chủ project build.

Theo quy tắc hiện tại, không áp dụng các patch hoặc helper rebuild object/lib cũ để sửa lỗi SDK. Không tự sửa hay thay dependency. Script chính `SDK/Scripts/FFmpeg/ffmpeg-build-libs.sh` chỉ dùng source FFmpeg upstream do chủ project chọn và cấu hình/build/đóng gói chuẩn; không áp dụng `hls-seek-rounding.patch` hoặc `hls.c` trong thư mục này.

Lỗi mất IDR đầu khi seek HLS được xử lý trong `SDK/Sources/Demux/FFormatContext.swift` bằng keyframe DTS đã quan sát và preroll có giới hạn. Regression đọc packet trực tiếp trước decoder, gồm seek sau khi mới đọc một packet và seek ngay sau open chưa đọc packet. Kết quả với FFmpeg thuần mới được kiểm tra riêng; kết quả binary cũ không thay thế việc chạy lại.

HTTPS/TLS/HLS dùng tính năng chuẩn của FFmpeg. Nếu bản build thiếu tính năng SDK cần, báo chính xác cờ configure cho chủ project quyết định và tự build lại; không tự thêm cờ, build phiên bản khác hoặc chỉnh archive/header/source.

Các file license được giữ nguyên. Đây là tài liệu lịch sử, không phải hướng dẫn build dependency hiện tại; xem [hướng dẫn build chính](../Scripts/FFmpeg/README.md).
