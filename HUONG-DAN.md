# Cây Kí Ức

Project [caykyuc-d5k63](https://supabase.com/dashboard/project/gjgmtvsikpycathqjeef) đã có cơ sở dữ liệu và kho ảnh riêng tư. Bản web đã điền URL và Publishable key của project.

## Mở cây bằng mã riêng

Bốn cô dùng chung địa chỉ website. Mỗi cô nhập mã được gửi riêng để mở đúng cây của mình. Mã chấp nhận chữ hoa, chữ thường và có thể nhập liền hoặc có dấu gạch ngang. Tải lại trang hoặc bấm **Thoát** sẽ trở về màn hình nhập mã.

Người quản lý bấm **Trang quản lý** hoặc mở địa chỉ website với đuôi `?admin=1`, rồi nhập mã quản lý. Trong **Tên cô và thư mở đầu**, đổi tên hiển thị của bốn hồ sơ `co-1` đến `co-4`. Mã đã cấp tiếp tục đi theo hồ sơ tương ứng.

## Cài đặt và đưa web lên hosting

1. Nếu chuyển sang project Supabase mới, chạy lần lượt `cay-ki-uc.sql`, `ma-truy-cap.sql`, `ma-quan-ly.sql`, `ma-ngan.sql` và `loi-chuc-cong-khai.sql` trong SQL Editor. Chạy thêm `luu-danh-sach-lop.sql` để lưu danh sách với mã học sinh ổn định. Cập nhật URL và **Publishable key** của project mới trong `public/cay-config.js`.
2. Trong Supabase **Authentication → Sign In / Providers**, bật **Allow anonymous sign-ins** để web tạo phiên khách. Phiên khách chỉ đọc được dữ liệu cây sau khi xác minh mã.
3. Chạy `tao-ma-cho-bon-co.sql` nếu các hồ sơ chưa có mã. Chép lại mã vừa cấp từ kết quả và gửi riêng từng cô. Lệnh giữ các mã đã cấp.
4. Chạy `tao-ma-quan-ly.sql` nếu project chưa có mã quản lý. Chép lại mã được trả về và giữ riêng. Lệnh giữ mã đã cấp.
5. Đưa `index.html`, `cay-config.js`, `cay-data.js` và `cay-portal.css` vào cùng một thư mục trên hosting HTTPS. Gửi cùng địa chỉ website và mã tương ứng cho từng cô.

## Đưa nội dung lên cây

Mục **Xem lời chúc** trên trang chủ cho khách chọn cây, đọc thư mở đầu của lớp và xem thiệp trên cây 3D. Cây của giáo viên cũng dùng thư mở đầu đã lưu trong trang quản lý. Khi trang quản lý chưa có thư, cả hai chế độ dùng lời tri ân mặc định. Lời nhắn cá nhân và ảnh đính kèm có quyền xem riêng.

- **Tên cô và thư mở đầu**. Điền tên dùng sau chữ “Cô”, tên lớp và thư mở đầu gửi từng cô. Xuống hai dòng để tách đoạn.
- **Danh sách lớp**. Mỗi dòng gồm mã số, dấu phẩy và tên. Khi thêm hoặc đổi thứ tự danh sách, hệ thống ghép học sinh theo họ tên và giữ mã đã liên kết với tài khoản, bài gửi. Sau khi lưu, dùng mã hệ thống hiển thị để nhập lời chúc. Khi sửa cách viết tên, giữ mã hiện tại của học sinh.
- **Ảnh lớp**. Chọn cả bốn cây hoặc một cây, giá ảnh từ 1 đến 14 và mùa. Mục “Cả bốn mùa” là ảnh mặc định cho giá. Ảnh riêng của một cô ưu tiên trên cây của cô đó. Dùng **Thư mục ảnh chung** để tải nhiều ảnh theo thứ tự tên tệp lên các giá còn trống cho cả bốn cây. Khung tự đổi theo tỷ lệ và giữ trọn ảnh.
- **Bài gửi**. Từ bảng câu trả lời Google Form, chuẩn bị CSV UTF-8 theo cột trong `mau-bai-gui.csv`. Mã học sinh có thể là số hoặc dạng `HS01`. Cột `co` nhận `co-1` đến `co-4`. Ô cô trống dùng cây đã chọn trước khi nhập. Mỗi CSV chỉ chứa một dòng cho mỗi cặp cô–học sinh.
- **Ảnh cá nhân**. Tải ảnh từ Drive về rồi chọn các tệp đó trong phần nhập. Điền đúng tên tệp ở `anh_1`, `anh_2`, `anh_3`. Ảnh chấp nhận JPG, PNG hoặc WebP, tối đa 10 MB. Nếu bỏ ba cột ảnh khỏi CSV, lần nhập sẽ giữ ảnh đã có. Nếu giữ cột ảnh và để trống ở một dòng, lần nhập thay ảnh của bài đó bằng danh sách trống.

Sau khi nhập, dùng mã từng cô để đối chiếu thư, lời chúc, bông hoa, ảnh cá nhân và giá ảnh. Admin quản lý nội dung. Mỗi mã chỉ cho xem bài gửi và ảnh của cây tương ứng, cùng ảnh lớp dùng chung.
