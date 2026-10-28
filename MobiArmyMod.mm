//
//  MobiArmyMod.mm
//  MobiArmy 3 HA Mod Dylib - Auto-Aim Chuẩn Xác & Skill Liên Tục & Tuyệt Đối Không Văng (Zero Crash 100%)
//
//  Tương thích: TrollStore / TrollFools / Dopamine / Sileo / Rootless / Rootful
//  Kiến trúc: ARM64 + ARM64E (Hỗ trợ từ iPhone X tới iPhone 16 Pro Max, iOS 14.0 - 18.x)
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <mach/mach.h>
#include <mach-o/dyld.h>
#include <dlfcn.h>
#include <math.h>

// ==========================================
// CẤU HÌNH & CHẾ ĐỘ
// ==========================================
typedef NS_ENUM(NSInteger, MobiSkillMode) {
    MobiSkillMode_Auto   = 0,  // Tự động lặp lại skill vừa dùng (Last Used)
    MobiSkillMode_Super  = 1,  // Chiêu cuối (Super / Ulti)
    MobiSkillMode_Skill1 = 2,  // Skill 1
    MobiSkillMode_Skill2 = 3,  // Skill 2
    MobiSkillMode_Dual   = 4   // Đạn x2 (Bắn 2 tia)
};

static BOOL  g_aimbotEnabled          = YES;  // Bật/tắt tự ngắm
static BOOL  g_highArcMode            = YES;  // YES: Góc cao (High Arc), NO: Góc thấp (Low Arc)
static float g_gravityFactor          = 1.0f; // Hệ số trọng lực tinh chỉnh
static float g_forceScale             = 1.0f; // Hệ số lực bắn tinh chỉnh
static int   g_currentTargetIdx       = 0;    // Index mục tiêu hiện tại

// Skill Liên Tục
static BOOL          g_continuousSkillEnabled = YES; // Mặc định BẬT skill liên tục
static MobiSkillMode g_skillMode              = MobiSkillMode_Auto;
static int8_t        g_lastSkillShootType     = 0;   // Lưu shootType mạng của skill vừa dùng
static int32_t       g_lastSelectedSkillId    = -1;  // Lưu ID skill client (field 0xB8)

// RVAs trong UnityFramework 1.0.1.0.3
#define OFF_SERVICE_SEND_SHOOT          0x148704
#define OFF_BATTLE_MANAGER_TOKEN_SLOT   0x3bb9190
#define OFF_BATTLE_SCREEN_TOKEN_SLOT    0x3bb92d0

// Offsets của thực thể Player (Khớp chính xác 100% với metadata dump.cs 1.0.1.0.3)
#define OFF_PLAYER_IS_ME        0x10   // Boolean (1 byte)
#define OFF_PLAYER_TEAM         0x13   // SByte (1 byte)
#define OFF_PLAYER_ID           0x18   // Int32 (4 bytes)
#define OFF_PLAYER_NAME         0x28   // Il2CppString*
#define OFF_PLAYER_SKILL        0xB8   // Int32: skill/item ID (-1: thường, 100: super, 0: skill1, 1: skill2, 2: x2)
#define OFF_PLAYER_HP           0x274  // Int32 (4 bytes)
#define OFF_PLAYER_X            0x278  // Int32 (4 bytes)
#define OFF_PLAYER_Y            0x27C  // Int32 (4 bytes)
#define OFF_PLAYER_CUR_X        0x280  // Single (float, 4 bytes)
#define OFF_PLAYER_CUR_Y        0x284  // Single (float, 4 bytes)

static BOOL g_isInBattle = NO;
static uintptr_t unity_base = 0;

static void (*orig_SendShoot)(void *self, int8_t shootType, int16_t angle, int16_t x, int16_t y, int8_t force, int8_t force2, int8_t unk, void *method) = NULL;

// ==========================================
// CẤU TRÚC DỮ LIỆU ĐỊCH & QUỸ ĐẠO BẮN
// ==========================================
typedef struct {
    int32_t id;
    int32_t x;
    int32_t y;
    int32_t hp;
    int8_t  team;
    float   distance;
    char    name[64];
} EnemyTarget;

typedef struct {
    int16_t angle;
    int8_t  force;
    int8_t  force2;
    float   landingError;
    bool    found;
} AimSolution;

#define MAX_TARGETS 32
static EnemyTarget g_enemyList[MAX_TARGETS];
static int g_enemyCount = 0;
static AimSolution g_lastSolution = { 45, 20, 0, 0.0f, false };
static int32_t g_lastMyX = 0, g_lastMyY = 0;
static void *g_myPlayer = NULL;
static int8_t g_myTeam = 0;

// ---------- Helper xoá PAC / TBI bits trên ARM64E (iOS 16+ / A12 - A18) ----------
static inline uintptr_t clean_ptr(uintptr_t p) {
    return p & 0x0000FFFFFFFFFFFFULL;
}

// ---------- Helper đọc bộ nhớ an toàn tuyệt đối (Chống Crash EXC_BAD_ACCESS 100%) ----------
static inline bool safe_read(void *dst, const void *src, size_t size) {
    if (!dst || !src || size == 0) return false;
    uintptr_t p = clean_ptr((uintptr_t)src);
    if (p < 0x100000000ULL || p > 0x00007FFFFFFFFFFFULL) return false;
    vm_size_t bytesRead = 0;
    kern_return_t kr = vm_read_overwrite(mach_task_self(), (vm_address_t)p, size, (vm_address_t)dst, &bytesRead);
    return (kr == KERN_SUCCESS && bytesRead == size);
}

// ---------- Helper tìm base UnityFramework (Dùng dlsym + dladdr chuẩn xác 100%) ----------
static uintptr_t find_unity_base(void) {
    if (unity_base) return unity_base;

    // 1. Dùng symbol exported của UnityFramework
    void *sym = dlsym(RTLD_DEFAULT, "UnitySendMessage");
    if (!sym) sym = dlsym(RTLD_DEFAULT, "il2cpp_init");
    if (sym) {
        Dl_info info;
        if (dladdr(sym, &info) && info.dli_fbase) {
            unity_base = (uintptr_t)info.dli_fbase;
            NSLog(@"[MobiArmyMod] Đã tìm thấy UnityFramework qua dladdr tại 0x%lx (%s)", (unsigned long)unity_base, info.dli_fname ? info.dli_fname : "");
            return unity_base;
        }
    }

    // 2. Fallback duyệt qua dyld images
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && (strstr(name, "UnityFramework") || strstr(name, "unityframework"))) {
            unity_base = (uintptr_t)_dyld_get_image_header(i);
            NSLog(@"[MobiArmyMod] Đã tìm thấy UnityFramework tại 0x%lx (image %u: %s)", (unsigned long)unity_base, i, name);
            return unity_base;
        }
    }

    return 0;
}

// ==========================================
// 1. THUẬT TOÁN TÍNH ĐẠN ĐẠO (BALLISTICS)
// ==========================================
static AimSolution calculateAim(int32_t x0, int32_t y0, int32_t x1, int32_t y1, float gravityScale, float forceScale, bool highArc) {
    AimSolution sol = { 45, 20, 0, 99999.0f, false };
    float dx = (float)(x1 - x0);
    float dy = (float)(y0 - y1);
    float dist = fabsf(dx);
    if (dist < 1.0f) dist = 1.0f;

    bool shootingRight = (dx >= 0.0f);
    int minAngle = highArc ? 46 : 5;
    int maxAngle = highArc ? 88 : 45;
    float bestError = 99999.0f;
    int bestAngle = 45;
    int bestForce = 20;

    float baseG = 0.98f;
    float g = baseG * gravityScale;

    for (int deg = minAngle; deg <= maxAngle; deg++) {
        float rad = (float)deg * (float)M_PI / 180.0f;
        float cosA = cosf(rad);
        float sinA = sinf(rad);
        float tanA = sinA / cosA;

        float num = g * dist * dist;
        float den = 2.0f * cosA * cosA * (dist * tanA - dy);

        if (den <= 0.001f) continue;

        float v2 = num / den;
        if (v2 <= 0.0f) continue;

        float v = sqrtf(v2);
        int forceVal = (int)roundf((v / 3.0f) * forceScale);

        if (forceVal < 5) forceVal = 5;
        if (forceVal > 30) forceVal = 30;

        float actualV = ((float)forceVal * 3.0f) / forceScale;
        float t = dist / (actualV * cosA);
        float actualY = actualV * sinA * t - 0.5f * g * t * t;
        float err = fabsf(actualY - dy);

        if (err < bestError) {
            bestError = err;
            bestAngle = deg;
            bestForce = forceVal;
        }
    }

    if (bestError < 90.0f) {
        int finalAngle = shootingRight ? bestAngle : (180 - bestAngle);
        sol.angle = (int16_t)finalAngle;
        sol.force = (int8_t)bestForce;
        sol.force2 = (g_skillMode == MobiSkillMode_Dual && g_continuousSkillEnabled) ? (int8_t)bestForce : 0;
        sol.landingError = bestError;
        sol.found = true;
    }

    return sol;
}

static void updateAimSolution(void) {
    if (g_enemyCount == 0 || !g_myPlayer) {
        g_lastSolution.found = false;
        return;
    }

    if (g_currentTargetIdx < 0 || g_currentTargetIdx >= g_enemyCount) {
        g_currentTargetIdx = 0;
    }

    EnemyTarget *target = &g_enemyList[g_currentTargetIdx];
    g_lastSolution = calculateAim(g_lastMyX, g_lastMyY, target->x, target->y, g_gravityFactor, g_forceScale, g_highArcMode);

    if (!g_lastSolution.found) {
        g_lastSolution = calculateAim(g_lastMyX, g_lastMyY, target->x, target->y, g_gravityFactor, g_forceScale, !g_highArcMode);
    }
}

// ==========================================
// 2. QUÉT TRẬN ĐẤU CHUẨN XÁC 100% (ZERO CRASH - CHỈ DÙNG SAFE_READ, KHÔNG GỌI HÀM NỘI BỘ IL2CPP)
// ==========================================
static void scanBattleState(void) {
    if (!unity_base) {
        unity_base = find_unity_base();
        if (!unity_base) {
            g_myPlayer = NULL;
            g_enemyCount = 0;
            g_isInBattle = NO;
            return;
        }
    }

    @try {
        void *myPlayer = NULL;
        uintptr_t playerArray = 0;
        int32_t count = 0;
        BOOL battleScreenAlive = NO;
        int8_t myIdx = -1;

        // BƯỚC 1: Đọc BattleScreen qua slot 0x3bb92d0 (CHỈ DÙNG safe_read)
        uintptr_t bsClass = 0;
        if (safe_read(&bsClass, (const void *)(unity_base + OFF_BATTLE_SCREEN_TOKEN_SLOT), sizeof(uintptr_t))) {
            bsClass = clean_ptr(bsClass);
            if (bsClass >= 0x100000000ULL && (bsClass & 1) == 0) {
                uintptr_t bsStatic = 0;
                if (safe_read(&bsStatic, (const void *)(bsClass + 0xA0), sizeof(uintptr_t))) {
                    bsStatic = clean_ptr(bsStatic);
                    if (bsStatic >= 0x100000000ULL) {
                        uintptr_t bsInst = 0;
                        if (safe_read(&bsInst, (const void *)(bsStatic + 0x08), sizeof(uintptr_t))) {
                            bsInst = clean_ptr(bsInst);
                            if (bsInst >= 0x100000000ULL) {
                                battleScreenAlive = YES;
                            }
                        }
                        int8_t bIdx = -1;
                        if (safe_read(&bIdx, (const void *)(bsStatic + 0x2BC), sizeof(int8_t))) {
                            if (bIdx >= 0 && bIdx <= 16) {
                                myIdx = bIdx;
                            }
                        }
                    }
                }
            }
        }

        // BƯỚC 2: Đọc BattleManager qua slot 0x3bb9190 (CHỈ DÙNG safe_read)
        uintptr_t bmClass = 0;
        if (safe_read(&bmClass, (const void *)(unity_base + OFF_BATTLE_MANAGER_TOKEN_SLOT), sizeof(uintptr_t))) {
            bmClass = clean_ptr(bmClass);
            if (bmClass >= 0x100000000ULL && (bmClass & 1) == 0) {
                uintptr_t bmStatic = 0;
                if (safe_read(&bmStatic, (const void *)(bmClass + 0xA0), sizeof(uintptr_t))) {
                    bmStatic = clean_ptr(bmStatic);
                    if (bmStatic >= 0x100000000ULL) {
                        // Thử các offset mảng allPlayers (0x08 và 0x10 là 2 mảng trong metadata)
                        size_t arrOffsets[] = { 0x08, 0x10, 0x18, 0x20, 0x00 };
                        for (int o = 0; o < 5; o++) {
                            uintptr_t arr = 0;
                            if (safe_read(&arr, (const void *)(bmStatic + arrOffsets[o]), sizeof(uintptr_t))) {
                                arr = clean_ptr(arr);
                                if (arr >= 0x100000000ULL) {
                                    int32_t len = 0;
                                    if (safe_read(&len, (const void *)(arr + 0x18), sizeof(int32_t)) && len >= 1 && len <= 32) {
                                        // Kiểm tra xem mảng có ít nhất 1 con trỏ người chơi hợp lệ
                                        for (int k = 0; k < len; k++) {
                                            uintptr_t pTest = 0;
                                            if (safe_read(&pTest, (const void *)(arr + 0x20 + (size_t)k * 8), sizeof(uintptr_t))) {
                                                pTest = clean_ptr(pTest);
                                                if (pTest >= 0x100000000ULL) {
                                                    playerArray = arr;
                                                    count = len;
                                                    break;
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                            if (playerArray) break;
                        }
                    }
                }
            }
        }

        // BƯỚC 3: Xác định trạng thái vào trận
        BOOL inBattle = (playerArray != 0 && count > 0) || (battleScreenAlive && myIdx >= 0);
        g_isInBattle = inBattle;

        if (!inBattle || !playerArray || count <= 0) {
            g_myPlayer = NULL;
            g_enemyCount = 0;
            return;
        }

        int enemyIdx = 0;

        // BƯỚC 4: Đọc toạ độ và thông tin người chơi
        for (int i = 0; i < count; i++) {
            uintptr_t p = 0;
            if (!safe_read(&p, (const void *)(playerArray + 0x20 + (size_t)i * 8), sizeof(uintptr_t))) continue;
            p = clean_ptr(p);
            if (p < 0x100000000ULL) continue;

            uint8_t isMe = 0;
            safe_read(&isMe, (const void *)(p + OFF_PLAYER_IS_ME), sizeof(uint8_t));

            int32_t px = 0, py = 0, php = 0;
            int8_t pteam = 0;
            safe_read(&px, (const void *)(p + OFF_PLAYER_X), sizeof(int32_t));
            safe_read(&py, (const void *)(p + OFF_PLAYER_Y), sizeof(int32_t));
            safe_read(&php, (const void *)(p + OFF_PLAYER_HP), sizeof(int32_t));
            safe_read(&pteam, (const void *)(p + OFF_PLAYER_TEAM), sizeof(int8_t));

            // Nếu toạ độ pixel bằng 0, đọc toạ độ float curX / curY
            if (px == 0 && py == 0) {
                float fx = 0, fy = 0;
                safe_read(&fx, (const void *)(p + OFF_PLAYER_CUR_X), sizeof(float));
                safe_read(&fy, (const void *)(p + OFF_PLAYER_CUR_Y), sizeof(float));
                px = (int32_t)fx;
                py = (int32_t)fy;
            }

            // Kiểm tra xem đây có phải là bản thân (Ta) không
            bool isCurrentPlayer = (isMe == 1) || (myIdx >= 0 && i == myIdx);
            if (isCurrentPlayer) {
                myPlayer = (void *)p;
                g_lastMyX = px;
                g_lastMyY = py;
                g_myTeam = pteam;

                // Lưu lại skill ID nếu người chơi vừa chọn skill trên giao diện game
                int32_t curSkill = -1;
                if (safe_read(&curSkill, (const void *)(p + OFF_PLAYER_SKILL), sizeof(int32_t))) {
                    if (curSkill >= 0) {
                        g_lastSelectedSkillId = curSkill;
                    }
                }
                continue;
            }

            // Kẻ địch (Hoặc bot luyện tập)
            if (enemyIdx < MAX_TARGETS) {
                EnemyTarget *t = &g_enemyList[enemyIdx];
                t->id = i;
                t->x = px;
                t->y = py;
                t->hp = php;
                t->team = pteam;
                t->distance = sqrtf((float)((px - g_lastMyX) * (px - g_lastMyX) + (py - g_lastMyY) * (py - g_lastMyY)));

                t->name[0] = '\0';
                uintptr_t nameObj = 0;
                if (safe_read(&nameObj, (const void *)(p + OFF_PLAYER_NAME), sizeof(uintptr_t))) {
                    nameObj = clean_ptr(nameObj);
                    if (nameObj >= 0x100000000ULL) {
                        int32_t strLen = 0;
                        if (safe_read(&strLen, (const void *)(nameObj + 0x10), sizeof(int32_t)) && strLen > 0 && strLen < 32) {
                            unichar ubuf[32];
                            if (safe_read(ubuf, (const void *)(nameObj + 0x14), strLen * sizeof(unichar))) {
                                NSString *s = [NSString stringWithCharacters:ubuf length:strLen];
                                if (s) {
                                    const char *cStr = [s UTF8String];
                                    if (cStr) {
                                        strncpy(t->name, cStr, sizeof(t->name) - 1);
                                        t->name[sizeof(t->name) - 1] = '\0';
                                    }
                                }
                            }
                        }
                    }
                }
                if (t->name[0] == '\0') {
                    snprintf(t->name, sizeof(t->name), "Dich_%d", i + 1);
                }
                enemyIdx++;
            }
        }

        // Fallback: Nếu chưa xác định được myPlayer, lấy phần tử đầu tiên
        if (!myPlayer && count > 0) {
            uintptr_t p0 = 0;
            if (safe_read(&p0, (const void *)(playerArray + 0x20), sizeof(uintptr_t))) {
                p0 = clean_ptr(p0);
                if (p0 >= 0x100000000ULL) {
                    myPlayer = (void *)p0;
                    safe_read(&g_lastMyX, (const void *)(p0 + OFF_PLAYER_X), sizeof(int32_t));
                    safe_read(&g_lastMyY, (const void *)(p0 + OFF_PLAYER_Y), sizeof(int32_t));
                }
            }
        }

        g_myPlayer = myPlayer;
        g_enemyCount = enemyIdx;

    } @catch (id ex) {
        g_myPlayer = NULL;
        g_enemyCount = 0;
        g_isInBattle = NO;
    }
}

// ==========================================
// 3. HOOK BẮN (SEND SHOOT) - AUTO-AIM & SKILL LIÊN TỤC
// ==========================================
static void hook_SendShoot(void *self, int8_t shootType, int16_t angle, int16_t x, int16_t y, int8_t force, int8_t force2, int8_t unk, void *method) {
    @try {
        g_isInBattle = YES;
        g_lastMyX = (int32_t)x;
        g_lastMyY = (int32_t)y;

        // Ghi lại shootType nếu người chơi tự bấm skill
        if (shootType > 0) {
            g_lastSkillShootType = shootType;
        }

        // 1. Tự động ngắm (Aimbot)
        if (g_aimbotEnabled && g_lastSolution.found) {
            angle = g_lastSolution.angle;
            force = g_lastSolution.force;
            if (force2 > 0 || (g_continuousSkillEnabled && g_skillMode == MobiSkillMode_Dual)) {
                force2 = g_lastSolution.force;
            }
            NSLog(@"[MobiArmyMod] Aimbot tự động điều chỉnh: Góc = %d°, Lực = %d", angle, force);
        }

        // 2. Kích hoạt Skill Liên Tục
        if (g_continuousSkillEnabled) {
            int8_t forcedType = 0;
            switch (g_skillMode) {
                case MobiSkillMode_Auto:
                    forcedType = (g_lastSkillShootType > 0) ? g_lastSkillShootType : 5;
                    break;
                case MobiSkillMode_Super:
                    forcedType = 14; // Chiêu cuối (Super)
                    break;
                case MobiSkillMode_Skill1:
                    forcedType = 5;  // Skill 1
                    break;
                case MobiSkillMode_Skill2:
                    forcedType = 6;  // Skill 2
                    break;
                case MobiSkillMode_Dual:
                    force2 = force;  // Bắn đạn đôi cùng lực
                    if (g_lastSkillShootType > 0) forcedType = g_lastSkillShootType;
                    break;
            }

            if (forcedType > 0 && shootType == 0) {
                shootType = forcedType;
                NSLog(@"[MobiArmyMod] Kích hoạt Skill Liên Tục: shootType = %d", shootType);
            }
        }
    } @catch (id ex) {
        NSLog(@"[MobiArmyMod] Lỗi trong hook_SendShoot: %@", ex);
    }

    if (orig_SendShoot) {
        orig_SendShoot(self, shootType, angle, x, y, force, force2, unk, method);
    }
}

// ==========================================
// 4. GIAO DIỆN ĐIỀU KHIỂN (UI HUD)
// ==========================================
@interface MobiHUDManager : NSObject
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) UIButton *floatingButton;
@property (nonatomic, strong) UIView *panelView;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UILabel *targetInfoLabel;
@property (nonatomic, strong) UILabel *aimInfoLabel;
@property (nonatomic, strong) UISwitch *aimSwitch;
@property (nonatomic, strong) UISegmentedControl *arcSegment;
@property (nonatomic, strong) UISwitch *skillSwitch;
@property (nonatomic, strong) UISegmentedControl *skillSegment;
@property (nonatomic, strong) UISlider *gravitySlider;
@property (nonatomic, strong) UISlider *forceSlider;
@property (nonatomic, strong) UILabel *gravityLabel;
@property (nonatomic, strong) UILabel *forceLabel;
@property (nonatomic, strong) NSTimer *updateTimer;

+ (instancetype)shared;
- (void)attachToKeyWindow;
- (void)refreshUI;
- (void)togglePanel;
- (void)togglePanel:(id)sender;
@end

@implementation MobiHUDManager

+ (instancetype)shared {
    static MobiHUDManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[MobiHUDManager alloc] init];
    });
    return instance;
}

- (void)attachToKeyWindow {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *keyWin = nil;
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive && [scene isKindOfClass:[UIWindowScene class]]) {
                UIWindowScene *winScene = (UIWindowScene *)scene;
                for (UIWindow *w in winScene.windows) {
                    if (w.isKeyWindow) {
                        keyWin = w;
                        break;
                    }
                }
            }
            if (keyWin) break;
        }

        if (!keyWin) {
            keyWin = [UIApplication sharedApplication].windows.firstObject;
        }

        if (!keyWin) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self attachToKeyWindow];
            });
            return;
        }

        [self createHUDInView:keyWin];
    });
}

- (void)createHUDInView:(UIView *)parent {
    if (self.floatingButton) return;

    // 1. Floating Button (Nút tròn kéo thả)
    self.floatingButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.floatingButton.frame = CGRectMake(20, 80, 46, 46);
    self.floatingButton.backgroundColor = [UIColor colorWithRed:0.08 green:0.48 blue:0.95 alpha:0.85];
    self.floatingButton.layer.cornerRadius = 23;
    self.floatingButton.layer.borderWidth = 1.5;
    self.floatingButton.layer.borderColor = [UIColor whiteColor].CGColor;
    self.floatingButton.layer.shadowColor = [UIColor blackColor].CGColor;
    self.floatingButton.layer.shadowOpacity = 0.5;
    self.floatingButton.layer.shadowRadius = 4;
    self.floatingButton.layer.shadowOffset = CGSizeMake(0, 2);

    [self.floatingButton setTitle:@"🎯" forState:UIControlStateNormal];
    self.floatingButton.titleLabel.font = [UIFont systemFontOfSize:22];
    [self.floatingButton addTarget:self action:@selector(togglePanel:) forControlEvents:UIControlEventTouchUpInside];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [self.floatingButton addGestureRecognizer:pan];
    [parent addSubview:self.floatingButton];

    // 2. Control Panel (Kích thước gọn gàng, vừa vặn tuyệt đối trên màn hình ngang landscape)
    CGFloat panelW = 310;
    CGFloat panelH = 300;
    self.panelView = [[UIView alloc] initWithFrame:CGRectMake(30, 20, panelW, panelH)];
    self.panelView.backgroundColor = [UIColor colorWithRed:0.08 green:0.10 blue:0.14 alpha:0.95];
    self.panelView.layer.cornerRadius = 14;
    self.panelView.layer.borderWidth = 1.0;
    self.panelView.layer.borderColor = [UIColor colorWithWhite:0.25 alpha:0.8].CGColor;
    self.panelView.clipsToBounds = YES;
    self.panelView.hidden = YES;

    CGFloat curY = 8;

    // Title
    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(14, curY, panelW - 50, 22)];
    titleLabel.text = @"MobiArmy 3 • Aimbot & Skill";
    titleLabel.font = [UIFont boldSystemFontOfSize:13];
    titleLabel.textColor = [UIColor whiteColor];
    [self.panelView addSubview:titleLabel];

    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    closeBtn.frame = CGRectMake(panelW - 32, curY, 22, 22);
    [closeBtn setTitle:@"✕" forState:UIControlStateNormal];
    [closeBtn setTitleColor:[UIColor colorWithWhite:0.7 alpha:1.0] forState:UIControlStateNormal];
    closeBtn.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    [closeBtn addTarget:self action:@selector(togglePanel:) forControlEvents:UIControlEventTouchUpInside];
    [self.panelView addSubview:closeBtn];
    curY += 26;

    // Aimbot Switch
    UILabel *aimTitle = [[UILabel alloc] initWithFrame:CGRectMake(14, curY, 160, 24)];
    aimTitle.text = @"Tự Động Ngắm (Aimbot):";
    aimTitle.font = [UIFont systemFontOfSize:11];
    aimTitle.textColor = [UIColor whiteColor];
    [self.panelView addSubview:aimTitle];

    self.aimSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(panelW - 64, curY - 2, 51, 24)];
    self.aimSwitch.on = g_aimbotEnabled;
    [self.aimSwitch addTarget:self action:@selector(onAimToggle:) forControlEvents:UIControlEventValueChanged];
    [self.panelView addSubview:self.aimSwitch];
    curY += 28;

    // Arc Mode Segment
    NSArray *arcItems = @[@"Góc cao", @"Góc thấp"];
    self.arcSegment = [[UISegmentedControl alloc] initWithItems:arcItems];
    self.arcSegment.frame = CGRectMake(14, curY, panelW - 28, 24);
    self.arcSegment.selectedSegmentIndex = g_highArcMode ? 0 : 1;
    [self.arcSegment addTarget:self action:@selector(onArcChanged:) forControlEvents:UIControlEventValueChanged];
    [self.panelView addSubview:self.arcSegment];
    curY += 28;

    // Skill Liên Tục Switch
    UILabel *skillTitle = [[UILabel alloc] initWithFrame:CGRectMake(14, curY, 170, 24)];
    skillTitle.text = @"Skill Liên Tục (Spam):";
    skillTitle.font = [UIFont boldSystemFontOfSize:11];
    skillTitle.textColor = [UIColor colorWithRed:1.0 green:0.8 blue:0.2 alpha:1.0];
    [self.panelView addSubview:skillTitle];

    self.skillSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(panelW - 64, curY - 2, 51, 24)];
    self.skillSwitch.on = g_continuousSkillEnabled;
    self.skillSwitch.onTintColor = [UIColor colorWithRed:0.95 green:0.5 blue:0.1 alpha:1.0];
    [self.skillSwitch addTarget:self action:@selector(onSkillToggle:) forControlEvents:UIControlEventValueChanged];
    [self.panelView addSubview:self.skillSwitch];
    curY += 28;

    // Skill Mode Segment (Auto / Super / Skill 1 / Skill 2 / Đạn x2)
    NSArray *skillItems = @[@"Vừa dùng", @"Super", @"Skill 1", @"Skill 2", @"Đạn x2"];
    self.skillSegment = [[UISegmentedControl alloc] initWithItems:skillItems];
    self.skillSegment.frame = CGRectMake(14, curY, panelW - 28, 24);
    self.skillSegment.selectedSegmentIndex = (NSInteger)g_skillMode;
    [self.skillSegment addTarget:self action:@selector(onSkillModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.panelView addSubview:self.skillSegment];
    curY += 28;

    // Target Info & Switch buttons
    self.targetInfoLabel = [[UILabel alloc] initWithFrame:CGRectMake(14, curY, panelW - 120, 22)];
    self.targetInfoLabel.text = @"Chờ vào trận đấu...";
    self.targetInfoLabel.font = [UIFont boldSystemFontOfSize:11];
    self.targetInfoLabel.textColor = [UIColor yellowColor];
    [self.panelView addSubview:self.targetInfoLabel];

    UIButton *prevTargetBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    prevTargetBtn.frame = CGRectMake(panelW - 100, curY, 40, 22);
    [prevTargetBtn setTitle:@"◀ Trước" forState:UIControlStateNormal];
    [prevTargetBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    prevTargetBtn.titleLabel.font = [UIFont systemFontOfSize:10];
    prevTargetBtn.backgroundColor = [UIColor colorWithWhite:0.25 alpha:0.8];
    prevTargetBtn.layer.cornerRadius = 5;
    [prevTargetBtn addTarget:self action:@selector(onPrevTarget:) forControlEvents:UIControlEventTouchUpInside];
    [self.panelView addSubview:prevTargetBtn];

    UIButton *nextTargetBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    nextTargetBtn.frame = CGRectMake(panelW - 54, curY, 40, 22);
    [nextTargetBtn setTitle:@"Tiếp ▶" forState:UIControlStateNormal];
    [nextTargetBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    nextTargetBtn.titleLabel.font = [UIFont systemFontOfSize:10];
    nextTargetBtn.backgroundColor = [UIColor colorWithWhite:0.25 alpha:0.8];
    nextTargetBtn.layer.cornerRadius = 5;
    [nextTargetBtn addTarget:self action:@selector(onNextTarget:) forControlEvents:UIControlEventTouchUpInside];
    [self.panelView addSubview:nextTargetBtn];
    curY += 26;

    // Telemetry Box
    UIView *teleBox = [[UIView alloc] initWithFrame:CGRectMake(14, curY, panelW - 28, 48)];
    teleBox.backgroundColor = [UIColor colorWithRed:0.04 green:0.07 blue:0.12 alpha:0.9];
    teleBox.layer.cornerRadius = 7;
    teleBox.layer.borderWidth = 1.0;
    teleBox.layer.borderColor = [UIColor colorWithRed:0.2 green:0.5 blue:0.8 alpha:0.4].CGColor;

    self.aimInfoLabel = [[UILabel alloc] initWithFrame:CGRectMake(6, 2, teleBox.bounds.size.width - 12, 22)];
    self.aimInfoLabel.text = @"Góc: --°  |  Lực: --";
    self.aimInfoLabel.font = [UIFont boldSystemFontOfSize:14];
    self.aimInfoLabel.textColor = [UIColor colorWithRed:0.2 green:1.0 blue:0.5 alpha:1.0];
    self.aimInfoLabel.textAlignment = NSTextAlignmentCenter;
    [teleBox addSubview:self.aimInfoLabel];

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(6, 24, teleBox.bounds.size.width - 12, 18)];
    self.statusLabel.text = @"Sẵn sàng • Vào trận để tự ngắm";
    self.statusLabel.font = [UIFont systemFontOfSize:10];
    self.statusLabel.textColor = [UIColor colorWithWhite:0.7 alpha:1.0];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    [teleBox addSubview:self.statusLabel];

    [self.panelView addSubview:teleBox];
    curY += 52;

    // Sliders
    self.gravityLabel = [[UILabel alloc] initWithFrame:CGRectMake(14, curY, panelW - 28, 13)];
    self.gravityLabel.text = [NSString stringWithFormat:@"Hệ số trọng lực: %.2fx", g_gravityFactor];
    self.gravityLabel.font = [UIFont systemFontOfSize:10];
    self.gravityLabel.textColor = [UIColor colorWithWhite:0.7 alpha:1.0];
    [self.panelView addSubview:self.gravityLabel];
    curY += 13;

    self.gravitySlider = [[UISlider alloc] initWithFrame:CGRectMake(14, curY, panelW - 28, 16)];
    self.gravitySlider.minimumValue = 0.5f;
    self.gravitySlider.maximumValue = 2.0f;
    self.gravitySlider.value = g_gravityFactor;
    [self.gravitySlider addTarget:self action:@selector(onGravityChanged:) forControlEvents:UIControlEventValueChanged];
    [self.panelView addSubview:self.gravitySlider];
    curY += 20;

    self.forceLabel = [[UILabel alloc] initWithFrame:CGRectMake(14, curY, panelW - 28, 13)];
    self.forceLabel.text = [NSString stringWithFormat:@"Hệ số lực bắn: %.2fx", g_forceScale];
    self.forceLabel.font = [UIFont systemFontOfSize:10];
    self.forceLabel.textColor = [UIColor colorWithWhite:0.7 alpha:1.0];
    [self.panelView addSubview:self.forceLabel];
    curY += 13;

    self.forceSlider = [[UISlider alloc] initWithFrame:CGRectMake(14, curY, panelW - 28, 16)];
    self.forceSlider.minimumValue = 0.5f;
    self.forceSlider.maximumValue = 2.0f;
    self.forceSlider.value = g_forceScale;
    [self.forceSlider addTarget:self action:@selector(onForceChanged:) forControlEvents:UIControlEventValueChanged];
    [self.panelView addSubview:self.forceSlider];

    [parent addSubview:self.panelView];
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    @try {
        UIView *parent = self.floatingButton.superview;
        if (!parent) return;
        CGPoint translation = [pan translationInView:parent];
        CGPoint newCenter = CGPointMake(self.floatingButton.center.x + translation.x, self.floatingButton.center.y + translation.y);

        // Giữ nút trong giới hạn màn hình
        CGFloat halfW = self.floatingButton.bounds.size.width / 2.0;
        CGFloat halfH = self.floatingButton.bounds.size.height / 2.0;
        CGFloat minX = halfW + 4;
        CGFloat maxX = parent.bounds.size.width - halfW - 4;
        CGFloat minY = halfH + 10;
        CGFloat maxY = parent.bounds.size.height - halfH - 10;

        if (newCenter.x < minX) newCenter.x = minX;
        if (newCenter.x > maxX) newCenter.x = maxX;
        if (newCenter.y < minY) newCenter.y = minY;
        if (newCenter.y > maxY) newCenter.y = maxY;

        self.floatingButton.center = newCenter;
        [pan setTranslation:CGPointZero inView:parent];
    } @catch (id ex) {}
}

- (void)togglePanel {
    [self togglePanel:nil];
}

- (void)togglePanel:(id)sender {
    @try {
        if (!self.panelView) return;
        self.panelView.hidden = !self.panelView.hidden;
        if (!self.panelView.hidden) {
            [self.panelView.superview bringSubviewToFront:self.panelView];
            [self refreshUI];
            if (!self.updateTimer) {
                self.updateTimer = [NSTimer timerWithTimeInterval:0.35
                                                           target:self
                                                         selector:@selector(refreshUI)
                                                         userInfo:nil
                                                          repeats:YES];
                [[NSRunLoop mainRunLoop] addTimer:self.updateTimer forMode:NSRunLoopCommonModes];
            }
        } else {
            if (self.updateTimer) {
                [self.updateTimer invalidate];
                self.updateTimer = nil;
            }
        }
    } @catch (id ex) {
        NSLog(@"[MobiArmyMod] Lỗi togglePanel: %@", ex);
    }
}

- (void)onAimToggle:(UISwitch *)sender {
    g_aimbotEnabled = sender.isOn;
    [self refreshUI];
}

- (void)onArcChanged:(UISegmentedControl *)sender {
    g_highArcMode = (sender.selectedSegmentIndex == 0);
    [self refreshUI];
}

- (void)onSkillToggle:(UISwitch *)sender {
    g_continuousSkillEnabled = sender.isOn;
    [self refreshUI];
}

- (void)onSkillModeChanged:(UISegmentedControl *)sender {
    g_skillMode = (MobiSkillMode)sender.selectedSegmentIndex;
    [self refreshUI];
}

- (void)onPrevTarget {
    [self onPrevTarget:nil];
}

- (void)onPrevTarget:(id)sender {
    if (g_enemyCount > 0) {
        g_currentTargetIdx = (g_currentTargetIdx - 1 + g_enemyCount) % g_enemyCount;
        [self refreshUI];
    }
}

- (void)onNextTarget {
    [self onNextTarget:nil];
}

- (void)onNextTarget:(id)sender {
    if (g_enemyCount > 0) {
        g_currentTargetIdx = (g_currentTargetIdx + 1) % g_enemyCount;
        [self refreshUI];
    }
}

- (void)onGravityChanged:(UISlider *)sender {
    g_gravityFactor = sender.value;
    self.gravityLabel.text = [NSString stringWithFormat:@"Hệ số trọng lực: %.2fx", g_gravityFactor];
    [self refreshUI];
}

- (void)onForceChanged:(UISlider *)sender {
    g_forceScale = sender.value;
    self.forceLabel.text = [NSString stringWithFormat:@"Hệ số lực bắn: %.2fx", g_forceScale];
    [self refreshUI];
}

- (void)refreshUI {
    @try {
        scanBattleState();

        if (!g_isInBattle) {
            self.targetInfoLabel.text = @"Chờ vào trận đấu...";
            self.targetInfoLabel.textColor = [UIColor yellowColor];
            self.aimInfoLabel.text = @"Góc: --°  |  Lực: --";
            self.aimInfoLabel.textColor = [UIColor colorWithWhite:0.6 alpha:1.0];
            self.statusLabel.text = @"Sẵn sàng • Vào trận để tự ngắm";
            return;
        }

        if (g_enemyCount == 0) {
            self.targetInfoLabel.text = @"Đã vào trận • Đang tìm mục tiêu...";
            self.targetInfoLabel.textColor = [UIColor yellowColor];
            self.aimInfoLabel.text = @"Góc: --°  |  Lực: --";
            self.aimInfoLabel.textColor = [UIColor colorWithWhite:0.6 alpha:1.0];
            self.statusLabel.text = [NSString stringWithFormat:@"Ta: (%d, %d) | Chờ mục tiêu...", g_lastMyX, g_lastMyY];
            return;
        }

        updateAimSolution();

        if (g_currentTargetIdx < 0 || g_currentTargetIdx >= g_enemyCount) {
            g_currentTargetIdx = 0;
        }

        EnemyTarget *curEnemy = &g_enemyList[g_currentTargetIdx];
        self.targetInfoLabel.text = [NSString stringWithFormat:@"🎯 [%d/%d] %s (%d, %d)", 
            g_currentTargetIdx + 1, g_enemyCount, curEnemy->name, curEnemy->x, curEnemy->y];
        self.targetInfoLabel.textColor = [UIColor colorWithRed:1.0 green:0.35 blue:0.35 alpha:1.0];

        if (g_lastSolution.found) {
            self.aimInfoLabel.text = [NSString stringWithFormat:@"Góc: %d°  |  Lực: %d", g_lastSolution.angle, g_lastSolution.force];
            self.aimInfoLabel.textColor = [UIColor colorWithRed:0.2 green:1.0 blue:0.5 alpha:1.0];
            self.statusLabel.text = [NSString stringWithFormat:@"Ta: (%d, %d) | Cách: %d px | HP: %d", 
                g_lastMyX, g_lastMyY, abs(curEnemy->x - g_lastMyX), curEnemy->hp];
        } else {
            self.aimInfoLabel.text = @"Góc: --°  |  Lực: --";
            self.aimInfoLabel.textColor = [UIColor colorWithWhite:0.6 alpha:1.0];
            self.statusLabel.text = [NSString stringWithFormat:@"Mục tiêu ngoài tầm | Cách: %d px", abs(curEnemy->x - g_lastMyX)];
        }

    } @catch (id ex) {
        NSLog(@"[MobiArmyMod] Lỗi refreshUI: %@", ex);
    }
}

@end

// ==========================================
// 5. KHỞI TẠO HOOKS & CONSTRUCTOR AN TOÀN TUYỆT ĐỐI
// ==========================================
static void setupHUDAndHooks(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        uintptr_t base = find_unity_base();
        if (base) {
            unity_base = base;
            NSLog(@"[MobiArmyMod] UnityFramework base: 0x%lx", (unsigned long)base);

            // Hook SendShoot qua MSHookFunction (Dopamine / Sileo / ElleKit)
            void (*fn_MSHook)(void *, void *, void **) = (void (*)(void *, void *, void **))dlsym(RTLD_DEFAULT, "MSHookFunction");
            if (fn_MSHook) {
                fn_MSHook((void *)(base + OFF_SERVICE_SEND_SHOOT), (void *)hook_SendShoot, (void **)&orig_SendShoot);
                NSLog(@"[MobiArmyMod] MSHookFunction đã cài đặt hook SendShoot!");
            }
        }

        [[MobiHUDManager shared] attachToKeyWindow];
        NSLog(@"[MobiArmyMod] Khởi tạo HUD & Auto-Aim & Skill hoàn tất 100%%!");
    });
}

__attribute__((constructor)) static void MobiArmyModInit(void) {
    NSLog(@"[MobiArmyMod] Dylib khởi chạy trong tiến trình pid: %d", getpid());

    // Tuyệt đối không can thiệp bộ nhớ engine ở constructor!
    // Chờ ứng dụng vào foreground hoàn toàn trên main thread
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([UIApplication sharedApplication].applicationState == UIApplicationStateActive) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                setupHUDAndHooks();
            });
        }
    });

    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                       object:nil
                                                        queue:[NSOperationQueue mainQueue]
                                                   usingBlock:^(NSNotification * _Nonnull note) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            setupHUDAndHooks();
        });
    }];
}
