# MOBIARMY 3 HA MOD (ZOOM & AIMBOT)
> Bản Mod chuyên sâu cho **MobiArmy 3 HA (v1.0.1.0.3)** trên nền tảng **iOS (arm64, Unity IL2CPP)**.  
> Được phân tích và viết trực tiếp dựa trên mã nguồn giải mã từ IPA gốc.

---

## 🌟 TÍNH NĂNG CHÍNH

### 1. Zoom Map Thông Minh (Smart Viewport Scaling)
- Thu nhỏ map để quan sát toàn cảnh chiến trường (mức zoom tuỳ chọn từ `1.0x` đến `2.0x`).
- **Không làm vỡ/lệch UI**: Can thiệp chính xác vào 3 điểm gọi (call-sites) của renderer `GL.LoadPixelMatrix` (`0x194188`, `0x194868`, `0x194A98`), giữ nguyên kích thước nút bấm, thanh máu và minimap của game.

### 2. Aimbot Tự Động Tính Góc & Lực (Ballistics Auto-Aim)
- **Quét bộ nhớ RAM**: Truy cập trực tiếp thực thể `BattleManager` (Class 27) và mảng người chơi `Player[]` tại `static_fields + 0x8`.
- **Tự động nhận diện địch**: Lọc người chơi khác đội (`team != myTeam`), còn sống (`hp > 0`), lấy toạ độ thực `(x, y)` của bạn và đối thủ.
- **Tính toán quỹ đạo đạn Parabol**:
  - Hỗ trợ **High Arc (Góc cao)**: Đạn vồng cao từ 55°–85°, vượt chướng ngại vật địa hình và rơi thẳng đầu địch.
  - Hỗ trợ **Low Arc (Góc thấp)**: Đạn căng từ 20°–54°, đường bắn trực diện nhanh nhất.
  - Tự động bù hướng bắn (bắn trái/phải).
- **Tự động can thiệp hàm bắn**: Hook trực tiếp vào hàm `Service.SendShoot` (RVA `0x148704`, gói tin `CMD 0x16`). Khi bạn bấm nút bắn trong game, mod sẽ tự động ghi đè góc và lực đã tính toán chuẩn xác mà không cần căn tay.

### 3. Floating HUD Menu (Giao diện điều khiển nổi cao cấp)
- Nút icon `🎯` kéo thả tự do mọi vị trí trên màn hình.
- Menu phong cách **Dark Glassmorphism** hiện đại:
  - Thanh chọn mức zoom (`1.0x`, `1.4x`, `1.6x`, `1.8x`, `2.0x`).
  - Nút bật/tắt nhanh Aimbot.
  - Nút chuyển chế độ đạn (Góc cao / Góc thấp).
  - Nút chọn mục tiêu địch `◀` và `▶` (hiển thị ID, HP, khoảng cách pixel).
  - Thanh trượt Calibrate (tinh chỉnh hệ số trọng lực và lực bắn trực tiếp trong game khi gió đổi).

---

## 🛠 HƯỚNG DẪN BIÊN DỊCH (BUILD)

### Cách 1: Tự động qua GitHub Actions (Không cần Mac / Theos)
1. Tạo một repository mới trên GitHub (chế độ Public hoặc Private).
2. Tải toàn bộ các file trong thư mục này lên repository:
   ```
   .github/workflows/build.yml
   Makefile
   MobiArmyMod.mm
   MobiArmyMod.plist
   control
   README.md
   ```
3. Vào tab **Actions** trên GitHub → Chọn workflow **build** → Bấm **Run workflow**.
4. Chờ 2–3 phút, vào mục kết quả build và tải artifact **MobiArmyMod-Release** (bên trong có sẵn `MobiArmyMod.dylib` và `MobiArmyMod.plist`).

---

### Cách 2: Tự biên dịch bằng Theos (Trên Mac, Linux hoặc iPhone Jailbreak)
Nếu bạn có Theos trên máy hoặc trực tiếp trên iPhone 14 Pro Max qua Terminal:

```bash
cd /path/to/dylib_folder
make clean
make FINALPACKAGE=1
```
File dylib sau khi build sẽ nằm tại: `.theos/obj/MobiArmyMod.dylib`.

---

## 📲 HƯỚNG DẪN CÀI ĐẶT LÊN IPHONE 14 PRO MAX

### Phương án A: Dùng TrollFools (Khuyên dùng - Nhanh & Ổn định nhất)
1. Chuyển file `MobiArmyMod.dylib` sang iPhone (AirDrop, iCloud Drive hoặc Filza).
2. Mở ứng dụng **TrollFools** trên iPhone.
3. Chọn ứng dụng **MobiArmy3HA** trong danh sách.
4. Bấm **Inject** → Tìm và chọn file `MobiArmyMod.dylib`.
5. TrollFools sẽ tự chèn dylib vào game. Mở game lên và trải nghiệm ngay!

---

### Phương án B: Cài dạng Tweak Jailbreak (Dopamine / Rootless / ElleKit)
Vì máy của bạn đã Jailbreak, bạn có thể cho tweak tự nạp qua Substrate/ElleKit:
1. Mở **Filza File Manager**.
2. Chép 2 file:
   - `MobiArmyMod.dylib`
   - `MobiArmyMod.plist` (chứa Filter Bundle ID `com.Mobiarmy3HA.puochuy222`)
3. Dán vào thư mục:
   - **Rootless (Dopamine/palera1n):** `/var/jb/Library/MobileSubstrate/DynamicLibraries/`
   - **Rootful:** `/Library/MobileSubstrate/DynamicLibraries/`
4. Vào game **MobiArmy3HA**, dylib sẽ tự động được inject vào tiến trình game.

---

## 🎮 HƯỚNG DẪN SỬ DỤNG TRONG TRẬN ĐẤU

1. **Vào trận chiến bất kỳ:**
   - Khi vào trận, bạn sẽ thấy icon nổi `🎯` ở góc màn hình. Bạn có thể giữ và kéo icon đến góc thuận tiện.
2. **Mở Menu:**
   - Chạm vào `🎯` để mở bảng điều khiển.
3. **Chọn mục tiêu:**
   - Bấm nút `◀` hoặc `▶` để chuyển mục tiêu bạn muốn tiêu diệt. Menu sẽ hiển thị rõ: `Địch #ID (HP: ...)`, khoảng cách và góc/lực tính toán tương ứng.
4. **Bắn:**
   - Giữ nguyên Aimbot ở trạng thái **BẬT**.
   - Bạn chỉ cần bấm nút bắn trong game, mod sẽ tự động áp dụng góc và lực tối ưu để đạn rơi trúng mục tiêu!
5. **Cân chỉnh (Fine-tuning):**
   - Nếu nhân vật của bạn có lực bắn khác biệt hoặc điều kiện gió lớn, hãy kéo nhẹ thanh trượt **Hệ số lực bắn** hoặc **Hệ số trọng lực** trong menu để đạt độ chính xác tuyệt đối.

---

## 🔬 THÔNG SỐ KỸ THUẬT NGHIÊN CỨU TỪ GAME (IPA 1.0.1.0.3)

| Mục | Địa chỉ RVA / Token / Offset | Ý nghĩa |
| :--- | :--- | :--- |
| **`SendShoot`** | RVA `0x148704` (Token `0x06000CF1`) | Hàm gửi packet bắn `CMD 0x16 (22)` lên máy chủ |
| **`GetMyPlayer`** | RVA `0x295FAC` (Token `0x060003E7`) | Trả về con trỏ thực thể người chơi của mình |
| **`BattleManager`** | Namespace: `lllIIlllllllIlIIIIllIIIIIlllIIIlIlIl` | Quản lý trận đấu, chứa mảng Player tại `static_fields + 0x8` |
| **`Player Coordinates`** | Offset `+0x278` (x), `+0x27C` (y) | Toạ độ integer thực tế của nhân vật trong map |
| **`Screen.get_width`** | RVA `0x1A81AA0` | Renderer Map call-sites: `0x194188`, `0x194868`, `0x194A98` |
| **`Screen.get_height`** | RVA `0x1A81AE0` | Renderer Map call-sites: `0x194194`, `0x194874`, `0x194AA4` |
| **Bundle ID** | `com.Mobiarmy3HA.puochuy222` | Bundle Identifier của app trong `Info.plist` |
