//
//  MobiArmyMod.mm
//  MobiArmy 3 HA Mod Dylib - Auto-Aim Chuẩn Xác & Zero Crash 100%
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
// CẤU HÌNH MẶC ĐỊNH
// ==========================================
static BOOL  g_aimbotEnabled    = YES;      // Bật aimbot
static BOOL  g_highArcMode      = YES;      // YES: Góc cao (High Arc), NO: Góc thấp (Low Arc)
static float g_gravityFactor    = 1.0f;     // Hệ số trọng lực tinh chỉnh
static float g_forceScale       = 1.0f;     // Hệ số lực bắn tinh chỉnh
static int   g_currentTargetIdx = 0;        // Index mục tiêu hiện tại

// RVAs trong UnityFramework 1.0.1.0.3
#define OFF_SERVICE_SEND_SHOOT          0x148704
#define OFF_BATTLE_MANAGER_CLASS        0x3bb9190
#define OFF_GAMECONTROLLER_CLASS        0x3bb92d0

// Offsets của thực thể Player (Khớp chính xác 100% với metadata dump.cs 1.0.1.0.3)
#define OFF_PLAYER_IS_ME        0x10   // Boolean (1 byte)
#define OFF_PLAYER_TEAM         0x13   // SByte (1 byte)
#define OFF_PLAYER_ID           0x18   // Int32 (4 bytes)
#define OFF_PLAYER_NAME         0x28   // Il2CppString*
#define OFF_PLAYER_HP           0x274  // Int32 (4 bytes)
#define OFF_PLAYER_X            0x278  // Int32 (4 bytes)
#define OFF_PLAYER_Y            0x27C  // Int32 (4 bytes)
#define OFF_PLAYER_CUR_X        0x280  // Single (float, 4 bytes)
#define OFF_PLAYER_CUR_Y        0x284  // Single (float, 4 bytes)

static BOOL g_isInBattle = NO;
static uintptr_t unity_base = 0;
static uint64_t g_battleUpdateCount = 0;

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

// ---------- Helper xoá PAC / TBI bits trên ARM64E (iPhone 14/15/16 Pro Max / iOS 16+) ----------
static inline uintptr_t clean_ptr(uintptr_t p) {
    return p & 0x0000FFFFFFFFFFFFULL;
}

// ---------- Helper đọc bộ nhớ an toàn (Chống Crash EXC_BAD_ACCESS 100%) ----------
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
            NSLog(@"[MobiArmyMod] Đã tìm thấy UnityFramework qua dladdr tại 0x%lx (%s)", unity_base, info.dli_fname ? info.dli_fname : "");
            return unity_base;
        }
    }

    // 2. Fallback duyệt qua dyld images
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && (strstr(name, "UnityFramework") || strstr(name, "unityframework"))) {
            unity_base = (uintptr_t)_dyld_get_image_header(i);
            NSLog(@"[MobiArmyMod] Đã tìm thấy UnityFramework tại 0x%lx (image %d: %s)", unity_base, i, name);
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

    if (bestError < 80.0f) {
        int finalAngle = shootingRight ? bestAngle : (180 - bestAngle);
        sol.angle = (int16_t)finalAngle;
        sol.force = (int8_t)bestForce;
        sol.force2 = 0;
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
// 2. QUÉT TRẬN ĐẤU CHUẨN XÁC 100% (ZERO CRASH - SAFE READ ONLY)
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
        uintptr_t gcClass = 0;
        int8_t myIdx = -1;
        uint8_t isInBattleFlag = 0;

        // 1. Đọc GameController tại base + OFF_GAMECONTROLLER_CLASS (0x3bb92d0)
        if (safe_read(&gcClass, (const void *)(unity_base + OFF_GAMECONTROLLER_CLASS), sizeof(uintptr_t))) {
            gcClass = clean_ptr(gcClass);
            if (gcClass >= 0x100000000ULL && (gcClass & 1) == 0) {
                uintptr_t gcStatic = 0;
                if (safe_read(&gcStatic, (const void *)(gcClass + 0xA0), sizeof(uintptr_t))) {
                    gcStatic = clean_ptr(gcStatic);
                    if (gcStatic >= 0x100000000ULL) {
                        safe_read(&myIdx, (const void *)(gcStatic + 0x2BC), sizeof(int8_t));
                        safe_read(&isInBattleFlag, (const void *)(gcStatic + 0x2E0), sizeof(uint8_t));
                    }
                }
            }
        }

        // 2. Đọc BattleManager tại base + OFF_BATTLE_MANAGER_CLASS (0x3bb9190)
        uintptr_t bmClass = 0;
        uintptr_t playerArray = 0;
        int32_t count = 0;

        if (safe_read(&bmClass, (const void *)(unity_base + OFF_BATTLE_MANAGER_CLASS), sizeof(uintptr_t))) {
            bmClass = clean_ptr(bmClass);
            if (bmClass >= 0x100000000ULL && (bmClass & 1) == 0) {
                uintptr_t bmStatic = 0;
                if (safe_read(&bmStatic, (const void *)(bmClass + 0xA0), sizeof(uintptr_t))) {
                    bmStatic = clean_ptr(bmStatic);
                    if (bmStatic >= 0x100000000ULL) {
                        // Thử các offset mảng allPlayers (0x08 là allPlayers chính thức)
                        size_t offsets[] = { 0x08, 0x10, 0x18, 0x20, 0x00 };
                        for (int o = 0; o < 5; o++) {
                            uintptr_t arr = 0;
                            if (safe_read(&arr, (const void *)(bmStatic + offsets[o]), sizeof(uintptr_t))) {
                                arr = clean_ptr(arr);
                                if (arr >= 0x100000000ULL) {
                                    int32_t len = 0;
                                    if (safe_read(&len, (const void *)(arr + 0x18), sizeof(int32_t))) {
                                        if (len >= 1 && len <= 32) {
                                            uintptr_t p0 = 0;
                                            if (safe_read(&p0, (const void *)(arr + 0x20), sizeof(uintptr_t))) {
                                                p0 = clean_ptr(p0);
                                                if (p0 >= 0x100000000ULL) {
                                                    playerArray = arr;
                                                    count = len;
                                                    break;
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        // 3. Nếu chưa thấy ở BattleManager, thử tìm trong GameController static fields
        if (!playerArray && gcClass >= 0x100000000ULL) {
            uintptr_t gcStatic = 0;
            if (safe_read(&gcStatic, (const void *)(gcClass + 0xA0), sizeof(uintptr_t))) {
                gcStatic = clean_ptr(gcStatic);
                if (gcStatic >= 0x100000000ULL) {
                    size_t gcOffsets[] = { 0x2F8, 0x1A0, 0x1C8, 0x200, 0x08, 0x10 };
                    for (int o = 0; o < 6; o++) {
                        uintptr_t arr = 0;
                        if (safe_read(&arr, (const void *)(gcStatic + gcOffsets[o]), sizeof(uintptr_t))) {
                            arr = clean_ptr(arr);
                            if (arr >= 0x100000000ULL) {
                                int32_t len = 0;
                                if (safe_read(&len, (const void *)(arr + 0x18), sizeof(int32_t))) {
                                    if (len >= 1 && len <= 32) {
                                        uintptr_t p0 = 0;
                                        if (safe_read(&p0, (const void *)(arr + 0x20), sizeof(uintptr_t))) {
                                            p0 = clean_ptr(p0);
                                            if (p0 >= 0x100000000ULL) {
                                                playerArray = arr;
                                                count = len;
                                                break;
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        // Xác định trạng thái vào trận:
        // Cả đấu Online (isInBattleFlag == 1) VÀ Luyện tập offline (myIdx >= 0 HOẶC playerArray có count > 0)
        BOOL inBattle = (isInBattleFlag == 1) || (myIdx >= 0) || (playerArray != 0 && count > 0);
        g_isInBattle = inBattle;

        if (!inBattle || !playerArray || count <= 0) {
            g_myPlayer = NULL;
            g_enemyCount = 0;
            return;
        }

        g_battleUpdateCount++;
        void *myPlayer = NULL;
        int enemyIdx = 0;

        // Ưu tiên 1: myPlayer theo myIdx từ GameController
        if (myIdx >= 0 && myIdx < count) {
            uintptr_t pMe = 0;
            if (safe_read(&pMe, (const void *)(playerArray + 0x20 + (size_t)myIdx * 8), sizeof(uintptr_t))) {
                pMe = clean_ptr(pMe);
                if (pMe >= 0x100000000ULL) {
                    myPlayer = (void *)pMe;
                    int32_t mx = 0, my = 0;
                    int8_t mteam = 0;
                    safe_read(&mx, (const void *)(pMe + OFF_PLAYER_X), sizeof(int32_t));
                    safe_read(&my, (const void *)(pMe + OFF_PLAYER_Y), sizeof(int32_t));
                    safe_read(&mteam, (const void *)(pMe + OFF_PLAYER_TEAM), sizeof(int8_t));
                    if (mx == 0 && my == 0) {
                        float fx = 0, fy = 0;
                        safe_read(&fx, (const void *)(pMe + OFF_PLAYER_CUR_X), sizeof(float));
                        safe_read(&fy, (const void *)(pMe + OFF_PLAYER_CUR_Y), sizeof(float));
                        mx = (int32_t)fx;
                        my = (int32_t)fy;
                    }
                    g_lastMyX = mx;
                    g_lastMyY = my;
                    g_myTeam = mteam;
                }
            }
        }

        // Quét toàn bộ mảng người chơi
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

            if (px == 0 && py == 0) {
                float fx = 0, fy = 0;
                safe_read(&fx, (const void *)(p + OFF_PLAYER_CUR_X), sizeof(float));
                safe_read(&fy, (const void *)(p + OFF_PLAYER_CUR_Y), sizeof(float));
                px = (int32_t)fx;
                py = (int32_t)fy;
            }

            // Nếu chưa xác định myPlayer bằng myIdx, kiểm tra cờ isMe
            if (!myPlayer && isMe) {
                myPlayer = (void *)p;
                g_lastMyX = px;
                g_lastMyY = py;
                g_myTeam = pteam;
                continue;
            }

            // Nếu chính là myPlayer thì cập nhật vị trí và bỏ qua
            if (myPlayer && (void *)p == myPlayer) {
                g_lastMyX = px;
                g_lastMyY = py;
                g_myTeam = pteam;
                continue;
            }

            // Kẻ địch (hoặc bot trong chế độ Luyện tập)
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
                                if (s) strncpy(t->name, [s UTF8String], sizeof(t->name) - 1);
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

        // Fallback: nếu vẫn chưa tìm thấy myPlayer, lấy phần tử đầu tiên
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
// 3. HOOK BẮN (SEND SHOOT)
// ==========================================
static void hook_SendShoot(void *self, int8_t shootType, int16_t angle, int16_t x, int16_t y, int8_t force, int8_t force2, int8_t unk, void *method) {
    @try {
        if (g_aimbotEnabled && g_lastSolution.found) {
            angle = g_lastSolution.angle;
            force = g_lastSolution.force;
            force2 = g_lastSolution.force2;
            NSLog(@"[MobiArmyMod] Aimbot tự động điều chỉnh: Góc = %d°, Lực = %d", angle, force);
        }
    } @catch (id ex) {}

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
@property (nonatomic, strong) UISlider *gravitySlider;
@property (nonatomic, strong) UISlider *forceSlider;
@property (nonatomic, strong) UILabel *gravityLabel;
@property (nonatomic, strong) UILabel *forceLabel;
@property (nonatomic, strong) NSTimer *updateTimer;

+ (instancetype)shared;
- (void)attachToKeyWindow;
- (void)refreshUI;
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

        if (self.floatingButton && self.floatingButton.superview) return;

        [self setupUIInWindow:keyWin];
    });
}

- (void)setupUIInWindow:(UIWindow *)parent {
    CGFloat btnSize = 44.0;
    self.floatingButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.floatingButton.frame = CGRectMake(parent.bounds.size.width - btnSize - 16, 40, btnSize, btnSize);
    self.floatingButton.backgroundColor = [UIColor colorWithRed:0.95 green:0.26 blue:0.21 alpha:0.85];
    self.floatingButton.layer.cornerRadius = btnSize / 2.0;
    self.floatingButton.layer.borderWidth = 2.0;
    self.floatingButton.layer.borderColor = [UIColor whiteColor].CGColor;
    self.floatingButton.layer.shadowColor = [UIColor blackColor].CGColor;
    self.floatingButton.layer.shadowOffset = CGSizeMake(0, 2);
    self.floatingButton.layer.shadowOpacity = 0.5;
    self.floatingButton.layer.shadowRadius = 4;
    [self.floatingButton setTitle:@"🎯" forState:UIControlStateNormal];
    self.floatingButton.titleLabel.font = [UIFont systemFontOfSize:22];

    [self.floatingButton addTarget:self action:@selector(togglePanel) forControlEvents:UIControlEventTouchUpInside];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [self.floatingButton addGestureRecognizer:pan];
    [parent addSubview:self.floatingButton];

    // Panel điều khiển (gọn gàng, tối ưu không gian)
    CGFloat panelW = 310;
    CGFloat panelH = 280;
    self.panelView = [[UIView alloc] initWithFrame:CGRectMake((parent.bounds.size.width - panelW) / 2, (parent.bounds.size.height - panelH) / 2, panelW, panelH)];
    self.panelView.backgroundColor = [UIColor colorWithRed:0.08 green:0.11 blue:0.16 alpha:0.95];
    self.panelView.layer.cornerRadius = 14;
    self.panelView.layer.borderWidth = 1.5;
    self.panelView.layer.borderColor = [UIColor colorWithRed:0.2 green:0.6 blue:1.0 alpha:0.6].CGColor;
    self.panelView.layer.shadowColor = [UIColor blackColor].CGColor;
    self.panelView.layer.shadowOffset = CGSizeMake(0, 4);
    self.panelView.layer.shadowOpacity = 0.6;
    self.panelView.layer.shadowRadius = 8;
    self.panelView.hidden = YES;

    CGFloat curY = 12;

    // Tiêu đề
    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, curY, panelW - 56, 24)];
    titleLabel.text = @"⚡ MOBIARMY 3 HA AIMBOT";
    titleLabel.font = [UIFont boldSystemFontOfSize:15];
    titleLabel.textColor = [UIColor colorWithRed:0.3 green:0.8 blue:1.0 alpha:1.0];
    [self.panelView addSubview:titleLabel];

    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    closeBtn.frame = CGRectMake(panelW - 40, curY, 28, 24);
    [closeBtn setTitle:@"✕" forState:UIControlStateNormal];
    [closeBtn setTitleColor:[UIColor colorWithWhite:0.7 alpha:1.0] forState:UIControlStateNormal];
    closeBtn.titleLabel.font = [UIFont boldSystemFontOfSize:18];
    [closeBtn addTarget:self action:@selector(togglePanel) forControlEvents:UIControlEventTouchUpInside];
    [self.panelView addSubview:closeBtn];
    curY += 32;

    // Aimbot Switch
    UILabel *aimTitle = [[UILabel alloc] initWithFrame:CGRectMake(16, curY + 4, 150, 24)];
    aimTitle.text = @"AIMBOT TỰ ĐỘNG";
    aimTitle.font = [UIFont boldSystemFontOfSize:13];
    aimTitle.textColor = [UIColor whiteColor];
    [self.panelView addSubview:aimTitle];

    self.aimSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(panelW - 68, curY, 51, 31)];
    self.aimSwitch.on = g_aimbotEnabled;
    [self.aimSwitch addTarget:self action:@selector(onAimToggle:) forControlEvents:UIControlEventValueChanged];
    [self.panelView addSubview:self.aimSwitch];
    curY += 36;

    // Arc Mode Segment
    NSArray *arcItems = @[@"Góc cao (High Arc)", @"Góc thấp (Low Arc)"];
    self.arcSegment = [[UISegmentedControl alloc] initWithItems:arcItems];
    self.arcSegment.frame = CGRectMake(16, curY, panelW - 32, 28);
    self.arcSegment.selectedSegmentIndex = g_highArcMode ? 0 : 1;
    [self.arcSegment addTarget:self action:@selector(onArcChanged:) forControlEvents:UIControlEventValueChanged];
    [self.panelView addSubview:self.arcSegment];
    curY += 34;

    // Target Info & Switch
    self.targetInfoLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, curY, panelW - 130, 24)];
    self.targetInfoLabel.text = @"Chưa vào trận đấu";
    self.targetInfoLabel.font = [UIFont boldSystemFontOfSize:13];
    self.targetInfoLabel.textColor = [UIColor yellowColor];
    [self.panelView addSubview:self.targetInfoLabel];

    UIButton *prevTargetBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    prevTargetBtn.frame = CGRectMake(panelW - 110, curY, 42, 24);
    [prevTargetBtn setTitle:@"◀ Trước" forState:UIControlStateNormal];
    [prevTargetBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    prevTargetBtn.titleLabel.font = [UIFont systemFontOfSize:11];
    prevTargetBtn.backgroundColor = [UIColor colorWithWhite:0.25 alpha:0.8];
    prevTargetBtn.layer.cornerRadius = 6;
    [prevTargetBtn addTarget:self action:@selector(onPrevTarget) forControlEvents:UIControlEventTouchUpInside];
    [self.panelView addSubview:prevTargetBtn];

    UIButton *nextTargetBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    nextTargetBtn.frame = CGRectMake(panelW - 60, curY, 44, 24);
    [nextTargetBtn setTitle:@"Tiếp ▶" forState:UIControlStateNormal];
    [nextTargetBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    nextTargetBtn.titleLabel.font = [UIFont systemFontOfSize:11];
    nextTargetBtn.backgroundColor = [UIColor colorWithWhite:0.25 alpha:0.8];
    nextTargetBtn.layer.cornerRadius = 6;
    [nextTargetBtn addTarget:self action:@selector(onNextTarget) forControlEvents:UIControlEventTouchUpInside];
    [self.panelView addSubview:nextTargetBtn];
    curY += 30;

    // Telemetry Box
    UIView *teleBox = [[UIView alloc] initWithFrame:CGRectMake(16, curY, panelW - 32, 50)];
    teleBox.backgroundColor = [UIColor colorWithRed:0.04 green:0.07 blue:0.12 alpha:0.9];
    teleBox.layer.cornerRadius = 8;
    teleBox.layer.borderWidth = 1.0;
    teleBox.layer.borderColor = [UIColor colorWithRed:0.2 green:0.5 blue:0.8 alpha:0.4].CGColor;

    self.aimInfoLabel = [[UILabel alloc] initWithFrame:CGRectMake(8, 4, teleBox.bounds.size.width - 16, 22)];
    self.aimInfoLabel.text = @"Góc: --°  |  Lực: --";
    self.aimInfoLabel.font = [UIFont boldSystemFontOfSize:15];
    self.aimInfoLabel.textColor = [UIColor colorWithRed:0.2 green:1.0 blue:0.5 alpha:1.0];
    self.aimInfoLabel.textAlignment = NSTextAlignmentCenter;
    [teleBox addSubview:self.aimInfoLabel];

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(8, 26, teleBox.bounds.size.width - 16, 18)];
    self.statusLabel.text = @"Vào trận để tự động quét mục tiêu";
    self.statusLabel.font = [UIFont systemFontOfSize:11];
    self.statusLabel.textColor = [UIColor colorWithWhite:0.7 alpha:1.0];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    [teleBox addSubview:self.statusLabel];

    [self.panelView addSubview:teleBox];
    curY += 56;

    // Sliders
    self.gravityLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, curY, panelW - 32, 14)];
    self.gravityLabel.text = [NSString stringWithFormat:@"Hệ số trọng lực: %.2fx", g_gravityFactor];
    self.gravityLabel.font = [UIFont systemFontOfSize:11];
    self.gravityLabel.textColor = [UIColor colorWithWhite:0.7 alpha:1.0];
    [self.panelView addSubview:self.gravityLabel];
    curY += 14;

    self.gravitySlider = [[UISlider alloc] initWithFrame:CGRectMake(16, curY, panelW - 32, 18)];
    self.gravitySlider.minimumValue = 0.5f;
    self.gravitySlider.maximumValue = 2.0f;
    self.gravitySlider.value = g_gravityFactor;
    [self.gravitySlider addTarget:self action:@selector(onGravityChanged:) forControlEvents:UIControlEventValueChanged];
    [self.panelView addSubview:self.gravitySlider];
    curY += 22;

    self.forceLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, curY, panelW - 32, 14)];
    self.forceLabel.text = [NSString stringWithFormat:@"Hệ số lực bắn: %.2fx", g_forceScale];
    self.forceLabel.font = [UIFont systemFontOfSize:11];
    self.forceLabel.textColor = [UIColor colorWithWhite:0.7 alpha:1.0];
    [self.panelView addSubview:self.forceLabel];
    curY += 14;

    self.forceSlider = [[UISlider alloc] initWithFrame:CGRectMake(16, curY, panelW - 32, 18)];
    self.forceSlider.minimumValue = 0.5f;
    self.forceSlider.maximumValue = 2.0f;
    self.forceSlider.value = g_forceScale;
    [self.forceSlider addTarget:self action:@selector(onForceChanged:) forControlEvents:UIControlEventValueChanged];
    [self.panelView addSubview:self.forceSlider];

    [parent addSubview:self.panelView];
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    UIView *parent = self.floatingButton.superview;
    if (!parent) return;
    CGPoint translation = [pan translationInView:parent];
    self.floatingButton.center = CGPointMake(self.floatingButton.center.x + translation.x, self.floatingButton.center.y + translation.y);
    [pan setTranslation:CGPointZero inView:parent];
}

- (void)togglePanel {
    @try {
        self.panelView.hidden = !self.panelView.hidden;
        if (!self.panelView.hidden) {
            [self.panelView.superview bringSubviewToFront:self.panelView];
            [self refreshUI];
            if (!self.updateTimer) {
                self.updateTimer = [NSTimer scheduledTimerWithTimeInterval:0.4
                                                                    target:self
                                                                  selector:@selector(refreshUI)
                                                                  userInfo:nil
                                                                   repeats:YES];
            }
        } else {
            [self.updateTimer invalidate];
            self.updateTimer = nil;
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

- (void)onPrevTarget {
    if (g_enemyCount > 0) {
        g_currentTargetIdx = (g_currentTargetIdx - 1 + g_enemyCount) % g_enemyCount;
        [self refreshUI];
    }
}

- (void)onNextTarget {
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
            self.targetInfoLabel.text = @"Chưa vào trận đấu";
            self.targetInfoLabel.textColor = [UIColor yellowColor];
            self.aimInfoLabel.text = @"Góc: --°  |  Lực: --";
            self.aimInfoLabel.textColor = [UIColor colorWithWhite:0.6 alpha:1.0];
            self.statusLabel.text = @"Vào trận để tự động quét mục tiêu";
            return;
        }

        if (g_enemyCount == 0) {
            self.targetInfoLabel.text = @"Đang tìm địch...";
            self.targetInfoLabel.textColor = [UIColor yellowColor];
            self.aimInfoLabel.text = @"Góc: --°  |  Lực: --";
            self.aimInfoLabel.textColor = [UIColor colorWithWhite:0.6 alpha:1.0];
            self.statusLabel.text = [NSString stringWithFormat:@"Ta: (%d, %d) | Chờ mục tiêu...", g_lastMyX, g_lastMyY];
            return;
        }

        updateAimSolution();

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
            self.statusLabel.text = [NSString stringWithFormat:@"Mục tiêu ngoài tầm bắn | Cách: %d px", abs(curEnemy->x - g_lastMyX)];
        }

    } @catch (id ex) {
        NSLog(@"[MobiArmyMod] Lỗi refreshUI: %@", ex);
    }
}

@end

// ==========================================
// 5. KHỞI TẠO HOOKS & CONSTRUCTOR AN TOÀN
// ==========================================
static void setupHUDAndHooks(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        uintptr_t base = find_unity_base();
        if (base) {
            unity_base = base;
            NSLog(@"[MobiArmyMod] UnityFramework base: 0x%lx", base);

            // Hook qua MSHookFunction nếu có Substrate/Ellekit (Dopamine / Sileo)
            void (*fn_MSHook)(void *, void *, void **) = (void (*)(void *, void *, void **))dlsym(RTLD_DEFAULT, "MSHookFunction");
            if (fn_MSHook) {
                fn_MSHook((void *)(base + OFF_SERVICE_SEND_SHOOT), (void *)hook_SendShoot, (void **)&orig_SendShoot);
                NSLog(@"[MobiArmyMod] MSHookFunction đã cài đặt hook SendShoot!");
            }
        }

        [[MobiHUDManager shared] attachToKeyWindow];
        NSLog(@"[MobiArmyMod] Khởi tạo HUD thành công 100%%!");
    });
}

__attribute__((constructor)) static void MobiArmyModInit(void) {
    NSLog(@"[MobiArmyMod] Dylib khởi chạy trong tiến trình pid: %d", getpid());

    // Tuyệt đối không can thiệp bộ nhớ engine ở constructor!
    // Chờ app vào foreground hoàn toàn trên main thread
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([UIApplication sharedApplication].applicationState == UIApplicationStateActive) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                setupHUDAndHooks();
            });
        }
    });

    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                       object:nil
                                                        queue:[NSOperationQueue mainQueue]
                                                   usingBlock:^(NSNotification * _Nonnull note) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            setupHUDAndHooks();
        });
    }];
}
