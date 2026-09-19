# PanicAnalyzer — iOSVN

Ứng dụng iOS đọc log `panic-full`, `.ips` và `.crash`, rồi chỉ ra **linh kiện nào
đang nghi lỗi** thay vì chỉ hiện một đống chữ khó hiểu.

Dành cho kỹ thuật viên sửa iPhone và người dùng muốn biết máy mình sập nguồn vì đâu.

## Tải về

**[Tải PanicAnalyzer-unsigned.ipa](../../releases/latest/download/PanicAnalyzer-unsigned.ipa)**

File chưa ký — ký bằng chứng chỉ của bạn (ESign, Sideloadly, AltStore…) rồi cài
như bình thường. Không cần jailbreak.

## Chức năng

**Phân loại theo mức độ.** Mỗi lần sập nguồn được xếp vào một trong ba nhóm:

| Mức | Nghĩa là gì |
|---|---|
| Cần quan tâm | Dấu hiệu hỏng phần cứng: mất cảm biến SMC, treo bus I2C, lỗi bộ nhớ trong, quá nhiệt SoC |
| Cần theo dõi | Watchdog hết giờ, treo khi ngủ/thức, một lần kernel panic đơn lẻ |
| Có thể bỏ qua | Jetsam giải phóng RAM, ứng dụng bên thứ ba văng |

**Chỉ ra linh kiện nghi lỗi.** Mã cảm biến thiếu trong log SMC được tra ra đúng
cụm cáp; tên thiết bị trong log I2C (`roswell`, `audio-speaker-top`…) được dịch
sang tên linh kiện thật.

**Kèm độ tin cậy.** Mỗi kết luận ghi rõ Cao / Trung bình / Thấp, vì cùng một địa
chỉ I2C ở đời máy khác lại là con IC khác — app không đoán bừa.

**Gom lỗi trùng.** Các lần sập cùng nguyên nhân được gộp lại và hiện tần suất
(ví dụ 7 lần trong 24 giờ), vì lặp lại nhiều lần mới là dấu hiệu phần cứng thật.

**Xuất báo cáo đã lọc.** Báo cáo bỏ số sê-ri, UDID và thông tin cá nhân trước khi
chia sẻ.

**Tự cập nhật bộ luật.** Mỗi lần mở, app tải bộ luật mới nhất từ kho mã — không
cần cài lại ứng dụng. Mất mạng thì dùng bản đã tải trước đó.

**Gửi log lạ cho admin.** Log nào app chưa tra được sẽ hiện nút gửi, báo cáo được
sao chép sẵn và mở Telegram [@longdzqua](https://t.me/longdzqua).

Hiện có **53 quy tắc chẩn đoán** trên 20 nhóm hệ thống: I2C, SMC, AOP, SEP,
Storage, Watchdog, Power, Thermal, GPU, Baseband, Memory, Jetsam…

## Hỗ trợ

Chạy từ **iOS 15.0 trở lên**. Việc đọc log *tự động* phụ thuộc cách cài:

| Cách cài | Phiên bản iOS | Tự đọc log |
|---|---|---|
| `.ipa` ký chứng chỉ thường | 15.0 trở lên, kể cả iOS 26 | Không — nạp thủ công |
| `.tipa` qua TrollStore | 15.0 – 16.6.1, 16.7 RC, 17.0 | Có |
| Máy đã jailbreak | tuỳ công cụ | Có |

## Cách nạp log

**Cài đặt → Quyền riêng tư & Bảo mật → Phân tích & Cải thiện → Dữ liệu phân tích**
→ chọn file `panic-full-…` → Chia sẻ → PanicAnalyzer.

Hoặc dùng nút **Chọn file .ips / .crash** trong app.

## Bộ luật

Tri thức chẩn đoán nằm trong `assets/`, tách khỏi mã nguồn:

| File | Nội dung |
|---|---|
| `panic_rules.json` | Chữ ký panic và cách phân loại |
| `i2c_rules.json` | Địa chỉ I2C theo bus và đời máy |
| `sensor_database.json` | Mã cảm biến SMC → tên linh kiện |
| `model_database.json` | Mã máy → tên thương mại |

Dữ liệu đối chiếu từ mã nguồn xnu của Apple, log panic thật đăng công khai trên
Apple Developer Forums / Apple Support Communities, và wiki iFixit. Luật chưa
kiểm chứng được ghi rõ trong trường `source` và để độ tin cậy Thấp.

## Tự dựng

Cần macOS và Xcode 16 trở lên:

```bash
brew install xcodegen
xcodegen generate
open PanicAnalyzer.xcodeproj
```

## Giấy phép

**GNU General Public License v3.0** — xem [LICENSE](LICENSE).

Ứng dụng chỉ đọc log ngay trên máy, không gửi dữ liệu đi đâu.
