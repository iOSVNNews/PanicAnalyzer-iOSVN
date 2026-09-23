# PanicAnalyzer — iOSVN

Ứng dụng iOS đọc log `panic-full`, `.ips` và `.crash`, rồi chỉ ra **linh kiện nào
đang nghi lỗi** thay vì chỉ hiện một đống chữ khó hiểu.

Dành cho kỹ thuật viên sửa iPhone và người dùng muốn biết máy mình sập nguồn vì đâu.

## Tải về

**[Tải PanicAnalyzer-unsigned.ipa](../../releases/latest/download/PanicAnalyzer-unsigned.ipa)**

File chưa ký — ký bằng chứng chỉ của bạn (ESign, Sideloadly, AltStore…) rồi cài
như bình thường. Không cần jailbreak để nhập log bằng Share Sheet.

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

**Nhận log nhanh từ Share Sheet.** Trong màn hình Dữ liệu phân tích của iOS, chọn
một hoặc nhiều log rồi dùng **Chia sẻ → PanicAnalyzer**. Share Extension chuyển
log thẳng vào app, không cần mở trình chọn Tệp.

**Tự ghép đôi trên iOS 27.** App tự phát mình thành một "máy tính có thể ghép
đôi". Bạn chọn nó trong **Cài đặt → Quyền riêng tư & Bảo mật → Nhà phát triển**,
nhập mã PIN app hiển thị, rồi app lưu pairing record được bảo vệ và quét
CrashReportCopyMobile qua LocalDevVPN + RSD. Không cần máy tính, không cần
jailbreak.

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
| `.ipa` ký chứng chỉ thường | 15.0 trở lên | Có — qua Share Sheet |
| `.ipa` + LocalDevVPN | iOS 27 trở lên | Tự ghép đôi và quét CrashReporter |
| `.tipa` qua TrollStore | 15.0 – 16.6.1, 16.7 RC, 17.0 | Có |
| Máy đã jailbreak | tuỳ công cụ | Có |

## Cách nạp log

Nhanh nhất: **Cài đặt → Quyền riêng tư & Bảo mật → Phân tích & Cải thiện → Dữ
liệu phân tích** → chọn file `panic-full-…` → **Chia sẻ → PanicAnalyzer**. Share
Extension tự lưu log và đóng; mở PanicAnalyzer để xem kết quả.

Hoặc dùng nút **Chọn file .ips / .crash** trong app.

### Quét tự động qua LocalDevVPN trên iOS 27

1. Bật LocalDevVPN/StosVPN. Trong PanicAnalyzer, mở **Cấu hình LocalDevVPN** và
   nhập đúng **Device IP** đang hiển thị trong VPN (không phải **Tunnel IP**).
   Mặc định là `10.7.0.1`; có thể dán cả `10.7.0.1/32`. Ô cổng để trống: app tự
   tìm cổng RemotePairing (dịch vụ `remotepairingd` không cố định ở `49152`, iOS có
   thể đổi sang `49153`, `49154`… sau khi khởi động lại).
2. Bấm **Ghép đôi thiết bị này**, cho phép **Mạng cục bộ** và **Thông báo** nếu
   iOS hỏi. App bắt đầu quảng bá `_remotepairing-pairable-host._tcp` tên
   **PanicAnalyzer** (tối đa 5 phút, vẫn chạy khi bạn chuyển sang Cài đặt).
3. Mở **Cài đặt → Quyền riêng tư & Bảo mật → Nhà phát triển** (cần bật Chế độ nhà
   phát triển), chọn **PanicAnalyzer** và nhập mã PIN 6 số. Mã hiện trong thông
   báo và đã được sao chép sẵn.
4. App lưu record trong vùng dữ liệu được bảo vệ rồi tự đọc CrashReporter. Những
   lần sau chỉ cần bật LocalDevVPN; không phải ghép đôi lại.

**Hai đường kết nối.** Sau khi ghép đôi, app thử tunnel RPPairing trước. Trên
chính iPhone, tunnel này có thể bị iOS đóng ngay sau TLS (listener chỉ mở trên
Wi-Fi — SideInstaller đã ghi nhận). Khi đó app tự chuyển sang **CoreDeviceProxy**
qua lockdownd cổng `62078` (cách StikDebug dùng): dùng lockdown pairing file bạn
đã nhập (`.mobiledevicepairing`/`.plist` tạo từ máy tính, iLoader…) hoặc xin
lockdownd tạo mới — iOS có thể hỏi **Tin cậy máy tính này?**, hãy chọn Tin cậy.

Nếu kết nối lỗi, bấm **Kết nối lại thiết bị này** để ghép đôi lại. Record cũ chỉ
bị thay khi ghép đôi mới thành công; lỗi mạng không xóa khóa cũ. Có thể nhập
Remote Pairing file có sẵn qua **Cấu hình LocalDevVPN → Nhập pairing file**.

Lỗi `Connection refused` (NWError 61) nghĩa là VPN đã chạy nhưng cổng đã lưu
không còn mở. App tự dò lại cổng qua Bonjour `_remotepairing._tcp` (ưu tiên
dịch vụ của chính máy), thử từng cổng rồi ghi nhớ cổng dùng được. Nếu vẫn không
dò được, nhập cổng thủ công trong **Cấu hình LocalDevVPN**.

Nếu vẫn không đến được địa chỉ hiển thị trong lỗi, kiểm tra Device IP, quyền
Mạng cục bộ của PanicAnalyzer trong Cài đặt iOS rồi ngắt/kết nối lại LocalDevVPN.
VPN hiện trạng thái bật chưa bảo đảm cổng ghép đôi đã truy cập được. App không
tự thay đổi cấu hình của ứng dụng VPN khác. Sau khi cổng mở được, nếu ghép đôi
vẫn thất bại, mở khóa iPhone và chấp nhận yêu cầu của iOS hoặc nhập record hợp lệ.

Pairing record là thông tin xác thực nhạy cảm. App tạo và lưu nó trong
Application Support với file protection, loại khỏi bản sao lưu và không gửi nội
dung ra ngoài. Xóa app sẽ xóa bản sao record được lưu trong ứng dụng.

### Phạm vi `/var`

Remote Pairing chỉ kết nối dịch vụ
`com.apple.crashreportcopymobile.shim.remote`. Dịch vụ này xuất một cây AFC ảo
tương ứng với CrashReporter, thường là
`/var/mobile/Library/Logs/CrashReporter/` và các thư mục con như `Retired`.
Nó **không** cấp quyền duyệt toàn bộ `/var`, không đọc tùy ý mọi tệp trong
`/var/mobile/Library/Logs/`, và không phải Filza chạy trong sandbox.

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

Cần macOS, Xcode 16 trở lên, XcodeGen và Rust:

```bash
brew install xcodegen
rustup target add aarch64-apple-ios
bash PairingBridge/build-xcframework.sh
xcodegen generate
open PanicAnalyzer.xcodeproj
```

Bridge ghim thư viện MIT `jkcoxson/idevice`; xem [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Giấy phép

**GNU General Public License v3.0** — xem [LICENSE](LICENSE).

Ứng dụng chỉ đọc log ngay trên máy, không gửi dữ liệu đi đâu.
