# PanicAnalyzer — iOSVN

Ứng dụng iOS đọc log `panic-full`, `.ips` và `.crash`, rồi chỉ ra **linh kiện nào
đang nghi lỗi** thay vì chỉ hiện một đống chữ khó hiểu.

Dành cho kỹ thuật viên sửa iPhone và người dùng muốn biết máy mình sập nguồn vì đâu.

## Tải về

Bản `.ipa` mới nhất luôn có ở mục **Releases**:

**[Tải PanicAnalyzer-unsigned.ipa](../../releases/latest/download/PanicAnalyzer-unsigned.ipa)**

File chưa ký — ký bằng chứng chỉ của bạn (ESign, Sideloadly, AltStore, chứng chỉ
nhà phát triển…) rồi cài như bình thường. Không cần jailbreak.

## Phiên bản iOS hỗ trợ

Ứng dụng chạy từ **iOS 15.0 trở lên**.

Việc đọc log **tự động** phụ thuộc vào cách cài, không phụ thuộc đời máy: iOS chỉ
cho ứng dụng đọc `/var/mobile/Library/Logs/` khi ứng dụng thoát được sandbox.

| Cách cài | Phiên bản iOS | Tự đọc log hệ thống |
|---|---|---|
| `.ipa` ký bằng chứng chỉ thường (ESign, Sideloadly, AltStore, chứng chỉ nhà phát triển) | 15.0 trở lên, kể cả iOS 26 | Không — nạp log thủ công |
| `.tipa` cài qua TrollStore | 15.0 – 16.6.1, 16.7 RC (20H18), 17.0 | Có |
| Máy đã jailbreak | tuỳ công cụ jailbreak | Có |

TrollStore dựa trên lỗi CoreTrust của Apple nên chỉ chạy trong khoảng phiên bản
trên; **16.7.x (trừ bản 16.7 RC) và 17.0.1 trở lên sẽ không bao giờ được hỗ trợ**.
Máy iOS 17.0.1+ hoặc iOS 18/26 bắt buộc nạp log thủ công.

App tự kiểm tra ngay khi mở: đọc được thư mục log thì quét luôn, không đọc được
thì hiện hướng dẫn nạp tay.

## Ứng dụng làm gì

**Phân loại theo mức độ.** Mỗi lần sập nguồn được xếp vào một trong ba nhóm:

| Mức | Nghĩa là gì |
|---|---|
| Cần quan tâm | Dấu hiệu hỏng phần cứng: mất cảm biến SMC, treo bus I2C, lỗi bộ nhớ trong, quá nhiệt SoC |
| Cần theo dõi | Watchdog hết giờ, treo khi ngủ/thức, một lần kernel panic đơn lẻ |
| Có thể bỏ qua | Jetsam giải phóng RAM, ứng dụng bên thứ ba văng |

**Chỉ ra linh kiện nghi lỗi.** Ví dụ mã cảm biến thiếu trong log SMC được tra ra
đúng cụm cáp; tên thiết bị trong log I2C (`roswell`, `audio-speaker-top`…) được
dịch sang tên linh kiện thật.

**Kèm độ tin cậy.** Mỗi kết luận ghi rõ Cao / Trung bình / Thấp, vì cùng một địa
chỉ I2C ở đời máy khác lại là con IC khác — app không đoán bừa.

**Gom lỗi trùng.** Các lần sập cùng nguyên nhân được gộp lại và hiện tần suất
(ví dụ 7 lần trong 24 giờ), vì lặp lại nhiều lần mới là dấu hiệu phần cứng thật.

**Xuất báo cáo đã lọc.** Báo cáo bỏ số sê-ri, UDID và thông tin cá nhân trước khi
chia sẻ.

## Cách nạp log

Trên máy chưa jailbreak, iOS không cho ứng dụng đọc thư mục log hệ thống. Lấy log
theo một trong hai cách:

1. **Cài đặt → Quyền riêng tư & Bảo mật → Phân tích & Cải thiện → Dữ liệu phân
   tích** → chọn file `panic-full-…` → nút Chia sẻ → PanicAnalyzer.
2. Trích log bằng công cụ trên máy tính rồi mở trong app bằng nút
   **Chọn file .ips / .crash**.

Trên bản `.tipa` (TrollStore) app tự đọc thư mục
`/var/mobile/Library/Logs/CrashReporter/`.

## Bộ luật chẩn đoán

Toàn bộ tri thức chẩn đoán nằm trong thư mục `assets/`, không nằm trong mã nguồn:

| File | Nội dung |
|---|---|
| `panic_rules.json` | Các chữ ký panic và cách phân loại |
| `i2c_rules.json` | Địa chỉ I2C theo từng bus và từng đời máy |
| `sensor_database.json` | Mã cảm biến SMC → tên và vị trí linh kiện |
| `model_database.json` | Mã máy → tên thương mại |

**App tự cập nhật bộ luật.** Mỗi lần mở, app tải các file này từ nhánh `main` của
kho mã. Sửa file JSON trên GitHub là máy người dùng nhận luật mới ở lần mở kế
tiếp — không cần dựng lại ứng dụng. Mất mạng thì app dùng bản đã tải trước đó,
không có nữa thì dùng bản đi kèm trong ứng dụng.

Thêm một loại lỗi mới chỉ cần thêm một mục vào `panic_rules.json`:

```json
{
  "id": "vi-du-loi-moi",
  "family": "SMC",
  "baseSeverity": "warning",
  "subsystemWeight": 2,
  "escalateAt": 2,
  "windowHours": 48,
  "match": { "anyOf": ["chuỗi xuất hiện trong log"] },
  "title": "Tên hiển thị",
  "suspected": "Linh kiện nghi lỗi",
  "subsystem": "Hệ thống con",
  "advice": "Hướng xử lý",
  "confidence": "Trung bình"
}
```

Luật được xét lần lượt từ trên xuống, **luật đầu tiên khớp sẽ thắng** — nên đặt
chữ ký càng cụ thể càng lên trên. Các chữ ký quá chung như `Kernel data abort`
phải để cuối, vì chúng có mặt trong gần như mọi log panic.

## Gặp log lạ

Log nào app chưa tra được sẽ hiện nút **Gửi log cho admin**. Bấm vào đó, báo cáo
được sao chép sẵn và mở Telegram [@longdzqua](https://t.me/longdzqua) để gửi.
Lỗi mới sẽ được bổ sung vào bộ luật cho lần cập nhật sau.

## Cấu trúc mã nguồn

```
Sources/           Swift: cầu nối native, quét log, tải bộ luật
ShareExtension/    Nhận file .ips từ Share Sheet
web/               Giao diện và engine phân tích (HTML/CSS/JS)
assets/            Bộ luật chẩn đoán dạng JSON
project.yml        Cấu hình XcodeGen
```

Giao diện chạy trong `WKWebView`. Vì `file://` bị chặn CORS, phần Swift nạp sẵn
toàn bộ bộ luật vào trang trước khi mã JavaScript chạy.

## Tự dựng

Cần macOS và Xcode 16 trở lên:

```bash
brew install xcodegen
xcodegen generate
open PanicAnalyzer.xcodeproj
```

Mỗi lần đẩy lên nhánh `main`, GitHub Actions tự dựng và phát hành bản `.ipa` mới.

## Nguồn dữ liệu chẩn đoán

Các chữ ký panic trong `panic_rules.json` được đối chiếu với nguồn gốc, không phải
chép lại từ một bộ dữ liệu có sẵn. Mỗi luật có trường `source` ghi rõ xuất xứ:

- **Mã nguồn xnu của Apple** ([apple-oss-distributions/xnu](https://github.com/apple-oss-distributions/xnu))
  — nguồn duy nhất cho biết chính xác từng dấu chấm phẩy của chuỗi panic. Các file
  dùng nhiều nhất: `osfmk/arm64/sleh.c`, `osfmk/kern/zalloc.c`,
  `iokit/Kernel/IOPMrootDomain.cpp`. Phát hành theo Apple Public Source License.
- **Log panic thật do người dùng đăng công khai** trên Apple Developer Forums,
  Apple Support Communities và phần Answers của iFixit — dùng để xác nhận các chuỗi
  nằm trong kext đóng (SMC, AOP, DCP, SEP, ANS2) mà mã nguồn mở không có.
- **Bảng mã cảm biến SMC theo từng đời máy** tham khảo từ trang wiki cộng đồng của
  iFixit: [iPhone SMC Panic Assertion Failed](https://www.ifixit.com/Wiki/iPhone_SMC_Panic_Assertion_Failed).

Luật nào chưa tìm được log thật để đối chiếu thì ghi rõ "chưa kiểm chứng" trong
`source` và để độ tin cậy Thấp, thay vì hiện như một kết luận chắc chắn.

## Giấy phép

Phát hành theo **GNU General Public License v3.0** — xem file [LICENSE](LICENSE).

Nghĩa là: ai cũng được dùng, sửa và phân phối lại, nhưng bản sửa đổi phải mở mã
nguồn theo cùng giấy phép này.

Ứng dụng chỉ đọc log ngay trên máy, không gửi dữ liệu đi đâu.
