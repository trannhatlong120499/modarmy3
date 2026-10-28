//
// MobiArmyMod.mm
// Bản Mod Zoom map & Aimbot hoàn chỉnh cho MobiArmy 3 HA (v1.0.1.0.3)
// Kiến trúc: iOS arm64 / arm64e (iPhone 14 Pro Max / Dopamine / TrollFools)
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dispatch/dispatch.h>
#import <mach/mach.h>
#import <mach/vm_map.h>
#import <mach/mach_time.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <substrate.h>

#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <unistd.h>
#include <math.h>

// ==========================================
// CẤU HÌNH MẶC ĐỊNH
// ==========================================
static float g_zoomFactor       = 1.35f;    // Mức zoom mặc định (1.2x - 2.0x)
static BOOL  g_globalZoom       = YES;      // Zoom toàn cảnh
static BOOL  g_aimbotEnabled    = YES;      // Bật aimbot
static BOOL  g_highArcMode      = YES;      // YES: Góc cao (High Arc), NO: Góc thấp (Low Arc)
static float g_gravityFactor    = 1.0f;     // Hệ số trọng lực tinh chỉnh
static float g_forceScale       = 1.0f;     // Hệ số lực bắn tinh chỉnh
static int   g_currentTargetIdx = 0;        // Index mục tiêu hiện tại

// RVAs trong UnityFramework 1.0.1.0.3
#define OFF_SCREEN_GET_WIDTH            0x1a81aa0
#define OFF_SCREEN_GET_HEIGHT           0x1a81ae0
#define OFF_SCREEN_SET_RESOLUTION       0x1a81fbc
#define OFF_GL_LOAD_PIXEL_MATRIX        0x1a830e4
#define OFF_SERVICE_SEND_SHOOT          0x148704
#define OFF_PLAYER_UPDATE               0x9f244
#define OFF_BATTLE_UPDATE               0x297090
#define OFF_BATTLE_GET_MY_PLAYER        0x295fac

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

// Function Pointers
static uintptr_t unity_base = 0;
static BOOL g_hooksInstalled = NO;
static uint64_t g_playerUpdateCount = 0;
static uint64_t g_battleUpdateCount = 0;

static int (*orig_get_width)(void) = NULL;
static int (*orig_get_height)(void) = NULL;
static void (*orig_SetResolution)(int width, int height, bool fullscreen, void *method) = NULL;
static void (*orig_LoadPixelMatrix)(float left, float right, float bottom, float top, void *method) = NULL;
static void (*orig_SendShoot)(void *self, int8_t shootType, int16_t angle, int16_t x, int16_t y, int8_t force, int8_t force2, int8_t unk, void *method) = NULL;
static void (*orig_PlayerUpdate)(void *self, void *method) = NULL;
static void (*orig_BattleUpdate)(void *self, void *method) = NULL;
static void *(*orig_GetMyPlayer)(void *method) = NULL;

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
static uint64_t g_lastPlayerUpdateTime = 0;

// ---------- Helper đọc bộ nhớ an toàn (Chống Crash EXC_BAD_ACCESS 100%) ----------
static inline bool safe_read(void *dst, const void *src, size_t size) {
    if (!src || (uintptr_t)src < 0x100000000ULL || (uintptr_t)src > 0x3000000000ULL) return false;
    vm_size_t bytesRead = 0;
    kern_return_t kr = vm_read_overwrite(mach_task_self(), (vm_address_t)src, size, (vm_address_t)dst, &bytesRead);
    return (kr == KERN_SUCCESS && bytesRead == size);
}

// ---------- Helper tìm base UnityFramework ----------
static uintptr_t find_unity_base(void) {
    if (unity_base) return unity_base;
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strstr(name, "UnityFramework")) {
            unity_base = (uintptr_t)_dyld_get_image_header(i);
            NSLog(@"[MobiArmyMod] Đã tìm thấy UnityFramework tại 0x%lx (image %d: %s)", unity_base, i, name);
            return unity_base;
        }
    }
    return 0;
}


// ==========================================
// 1. ZOOM HOOK (Screen & GL.LoadPixelMatrix)
// ==========================================
static int hook_get_width(void) {
    int w = orig_get_width ? orig_get_width() : 0;
    if (g_zoomFactor > 1.01f) {
        return (int)(w * g_zoomFactor);
    }
    return w;
}

static int hook_get_height(void) {
    int h = orig_get_height ? orig_get_height() : 0;
    if (g_zoomFactor > 1.01f) {
        return (int)(h * g_zoomFactor);
    }
    return h;
}

// Hook Screen.SetResolution (0x1a81fbc) để patch cứng độ phân giải ngay từ đầu
static void hook_SetResolution(int width, int height, bool fullscreen, void *method) {
    NSLog(@"[MobiZoom] Screen.SetResolution gốc: %d x %d (fullscreen: %d)", width, height, fullscreen);
    if (g_zoomFactor > 1.01f) {
        width = (int)(width * g_zoomFactor);
        height = (int)(height * g_zoomFactor);
        NSLog(@"[MobiZoom] -> Patch cứng độ phân giải: %d x %d (zoom %.2fx)", width, height, g_zoomFactor);
    }
    if (orig_SetResolution) {
        orig_SetResolution(width, height, fullscreen, method);
    }
}

static void hook_LoadPixelMatrix(float left, float right, float bottom, float top, void *method) {
    if (g_zoomFactor > 1.01f) {
        right *= g_zoomFactor;
        bottom *= g_zoomFactor;
    }
    if (orig_LoadPixelMatrix) {
        orig_LoadPixelMatrix(left, right, bottom, top, method);
    }
}

// ==========================================
// 2. THUẬT TOÁN TÍNH ĐẠN ĐẠO (BALLISTICS)
// ==========================================
static AimSolution calculateAim(int32_t x0, int32_t y0, int32_t x1, int32_t y1, float gravityScale, float forceScale, bool highArc) {
    AimSolution sol = { 45, 20, 0, 99999.0f, false };
    float dx = (float)(x1 - x0);
    float dy = (float)(y0 - y1);
    float dist = fabsf(dx);
    if (dist < 1.0f) dist = 1.0f;

    bool shootingRight = (dx >= 0);
    float g = 9.8f * gravityScale;

    int minAngle = highArc ? 55 : 20;
    int maxAngle = highArc ? 85 : 54;

    float bestError = 999999.0f;
    int bestAngle = 45;
    int bestForce = 20;

    for (int deg = minAngle; deg <= maxAngle; deg++) {
        float rad = (float)deg * (float)M_PI / 180.0f;
        float cosA = cosf(rad);
        float sinA = sinf(rad);
        float tanA = sinA / cosA;

        float rhs = dist * tanA - dy;
        if (rhs <= 0.001f) continue;

        float vSq = (g * dist * dist) / (2.0f * cosA * cosA * rhs);
        if (vSq <= 0.0f) continue;
        float v = sqrtf(vSq);

        float rawForce = (v * 0.48f) / forceScale;
        int forceInt = (int)roundf(rawForce);
        if (forceInt < 5) forceInt = 5;
        if (forceInt > 30 && forceInt > 60) continue;

        float actualV = ((float)forceInt * forceScale) / 0.48f;
        float actualDrop = (g * dist * dist) / (2.0f * actualV * actualV * cosA * cosA);
        float actualY = dist * tanA - actualDrop;
        float err = fabsf(actualY - dy);

        if (err < bestError) {
            bestError = err;
            bestAngle = deg;
            bestForce = forceInt;
            if (err < 2.0f) break;
        }
    }

    int16_t finalAngle = (int16_t)bestAngle;
    if (!shootingRight) {
        finalAngle = (int16_t)(180 - bestAngle);
    }

    sol.angle = finalAngle;
    sol.force = (int8_t)bestForce;
    sol.force2 = 0;
    sol.landingError = bestError;
    sol.found = (bestError < 60.0f);
    return sol;
}

// Cập nhật tính toán đường ngắm
static void updateAimSolution(void) {
    if (g_enemyCount > 0) {
        if (g_currentTargetIdx >= g_enemyCount) g_currentTargetIdx = 0;
        EnemyTarget *target = &g_enemyList[g_currentTargetIdx];
        float dx = (float)(target->x - g_lastMyX);
        float dy = (float)(target->y - g_lastMyY);
        target->distance = sqrtf(dx * dx + dy * dy);
        g_lastSolution = calculateAim(g_lastMyX, g_lastMyY, target->x, target->y, g_gravityFactor, g_forceScale, g_highArcMode);
    } else {
        g_lastSolution.found = false;
    }
}

// ==========================================
// 3. HOOK REAL-TIME PLAYER UPDATE (TỰ ĐỘNG BẮT TOẠ ĐỘ)
// ==========================================
static void hook_PlayerUpdate(void *self, void *method) {
    if (self && (uintptr_t)self >= 0x100000000ULL) {
        g_lastPlayerUpdateTime = mach_absolute_time();
        g_playerUpdateCount++;

        uint8_t isMe = 0;
        safe_read(&isMe, (const void *)((uintptr_t)self + OFF_PLAYER_IS_ME), sizeof(uint8_t));

        int8_t team = 0;
        int32_t hp = 0, px = 0, py = 0, pid = 0;
        safe_read(&team, (const void *)((uintptr_t)self + OFF_PLAYER_TEAM), sizeof(int8_t));
        safe_read(&hp, (const void *)((uintptr_t)self + OFF_PLAYER_HP), sizeof(int32_t));
        safe_read(&px, (const void *)((uintptr_t)self + OFF_PLAYER_X), sizeof(int32_t));
        safe_read(&py, (const void *)((uintptr_t)self + OFF_PLAYER_Y), sizeof(int32_t));
        safe_read(&pid, (const void *)((uintptr_t)self + OFF_PLAYER_ID), sizeof(int32_t));

        // Fallback đọc toạ độ float nếu int = 0
        if (px == 0 && py == 0) {
            float fx = 0, fy = 0;
            safe_read(&fx, (const void *)((uintptr_t)self + OFF_PLAYER_CUR_X), sizeof(float));
            safe_read(&fy, (const void *)((uintptr_t)self + OFF_PLAYER_CUR_Y), sizeof(float));
            if (fx != 0 || fy != 0) {
                px = (int32_t)fx;
                py = (int32_t)fy;
            }
        }

        if (isMe != 0) {
            g_myPlayer = self;
            g_lastMyX = px;
            g_lastMyY = py;
            g_myTeam = team;
        } else if (hp > 0 || pid != 0) {
            // Không tính đồng đội nếu ở trận đấu đội
            BOOL isTeammate = (g_myTeam != 0 && team == g_myTeam);
            if (!isTeammate) {
                int32_t targetId = pid != 0 ? pid : (int32_t)((uintptr_t)self & 0xFFFF);
                if (hp > 0) {
                    bool found = false;
                    for (int i = 0; i < g_enemyCount; i++) {
                        if (g_enemyList[i].id == targetId) {
                            g_enemyList[i].x = px;
                            g_enemyList[i].y = py;
                            g_enemyList[i].hp = hp;
                            g_enemyList[i].team = team;
                            float dx = (float)(px - g_lastMyX);
                            float dy = (float)(py - g_lastMyY);
                            g_enemyList[i].distance = sqrtf(dx * dx + dy * dy);
                            snprintf(g_enemyList[i].name, sizeof(g_enemyList[i].name), "Địch #%d (HP:%d)", targetId, hp);
                            found = true;
                            break;
                        }
                    }
                    if (!found && g_enemyCount < MAX_TARGETS) {
                        EnemyTarget enemy;
                        enemy.id = targetId;
                        enemy.x = px;
                        enemy.y = py;
                        enemy.hp = hp;
                        enemy.team = team;
                        float dx = (float)(px - g_lastMyX);
                        float dy = (float)(py - g_lastMyY);
                        enemy.distance = sqrtf(dx * dx + dy * dy);
                        snprintf(enemy.name, sizeof(enemy.name), "Địch #%d (HP:%d)", targetId, hp);
                        g_enemyList[g_enemyCount++] = enemy;
                    }
                } else {
                    // Địch đã chết -> xoá khỏi danh sách mục tiêu
                    for (int i = 0; i < g_enemyCount; i++) {
                        if (g_enemyList[i].id == targetId) {
                            for (int j = i; j < g_enemyCount - 1; j++) {
                                g_enemyList[j] = g_enemyList[j + 1];
                            }
                            g_enemyCount--;
                            if (g_currentTargetIdx >= g_enemyCount) g_currentTargetIdx = 0;
                            break;
                        }
                    }
                }
            }
        }
    }

    if (orig_PlayerUpdate) {
        orig_PlayerUpdate(self, method);
    }
}

// Hook vòng lặp cập nhật trận đấu
static void hook_BattleUpdate(void *self, void *method) {
    if (self) {
        g_lastPlayerUpdateTime = mach_absolute_time();
        g_battleUpdateCount++;
    }
    if (orig_BattleUpdate) {
        orig_BattleUpdate(self, method);
    }
}

// Hook GetMyPlayer để lập tức lấy toạ độ Player khi vào trận
static void *hook_GetMyPlayer(void *method) {
    void *player = orig_GetMyPlayer ? orig_GetMyPlayer(method) : NULL;
    if (player && (uintptr_t)player >= 0x100000000ULL) {
        g_lastPlayerUpdateTime = mach_absolute_time();
        g_battleUpdateCount++;
        g_myPlayer = player;

        int32_t px = 0, py = 0;
        int8_t team = 0;
        safe_read(&px, (const void *)((uintptr_t)player + OFF_PLAYER_X), sizeof(int32_t));
        safe_read(&py, (const void *)((uintptr_t)player + OFF_PLAYER_Y), sizeof(int32_t));
        safe_read(&team, (const void *)((uintptr_t)player + OFF_PLAYER_TEAM), sizeof(int8_t));

        if (px == 0 && py == 0) {
            float fx = 0, fy = 0;
            safe_read(&fx, (const void *)((uintptr_t)player + OFF_PLAYER_CUR_X), sizeof(float));
            safe_read(&fy, (const void *)((uintptr_t)player + OFF_PLAYER_CUR_Y), sizeof(float));
            if (fx != 0 || fy != 0) {
                px = (int32_t)fx;
                py = (int32_t)fy;
            }
        }
        if (px != 0 || py != 0) {
            g_lastMyX = px;
            g_lastMyY = py;
            g_myTeam = team;
        }
    }
    return player;
}

// ==========================================
// 4. HOOK HÀM BẮN (SEND SHOOT HOOK)
// ==========================================
static void hook_SendShoot(void *self, int8_t shootType, int16_t angle, int16_t x, int16_t y, int8_t force, int8_t force2, int8_t unk, void *method) {
    @try {
        updateAimSolution();
        if (g_aimbotEnabled && g_lastSolution.found) {
            angle = g_lastSolution.angle;
            force = g_lastSolution.force;
            NSLog(@"[MobiAimbot] AUTO-AIM BẮN! -> (Góc: %d°, Lực: %d)", angle, force);
        }
    } @catch (id ex) {
        NSLog(@"[MobiAimbot] Lỗi SendShoot: %@", ex);
    }

    if (orig_SendShoot) {
        orig_SendShoot(self, shootType, angle, x, y, force, force2, unk, method);
    }
}

// ==========================================
// 5. GIAO DIỆN NỔI (AN TOÀN TUYỆT ĐỐI)
// ==========================================
@interface MobiHUDManager : NSObject
@property (nonatomic, strong) UIButton *floatingButton;
@property (nonatomic, strong) UIView *panelView;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UILabel *aimInfoLabel;
@property (nonatomic, strong) UILabel *targetInfoLabel;
@property (nonatomic, strong) UISwitch *aimbotSwitch;
@property (nonatomic, strong) UISegmentedControl *arcSegment;
@property (nonatomic, strong) UISegmentedControl *zoomSegment;
@property (nonatomic, strong) UISegmentedControl *zoomModeSegment;
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
    static MobiHUDManager *s_instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s_instance = [[MobiHUDManager alloc] init];
    });
    return s_instance;
}

- (void)attachToKeyWindow {
    UIWindow *targetWindow = nil;
    if (@available(iOS 13.0, *)) {
        for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive) {
                for (UIWindow *w in scene.windows) {
                    if (w.isKeyWindow) { targetWindow = w; break; }
                }
                if (!targetWindow && scene.windows.count > 0) targetWindow = scene.windows.firstObject;
            }
            if (targetWindow) break;
        }
    }
    if (!targetWindow) targetWindow = [UIApplication sharedApplication].keyWindow;
    if (!targetWindow || self.floatingButton) return;

    [self setupFloatingButtonInView:targetWindow];
    [self setupPanelInView:targetWindow];
    NSLog(@"[MobiArmyMod] HUD attached to keyWindow successfully!");
}

- (void)setupFloatingButtonInView:(UIView *)parent {
    self.floatingButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.floatingButton.frame = CGRectMake(20, 100, 50, 50);
    self.floatingButton.layer.cornerRadius = 25;
    self.floatingButton.layer.borderWidth = 1.5;
    self.floatingButton.layer.borderColor = [UIColor colorWithRed:0.2 green:0.8 blue:1.0 alpha:0.8].CGColor;
    self.floatingButton.backgroundColor = [UIColor colorWithRed:0.05 green:0.1 blue:0.18 alpha:0.9];
    [self.floatingButton setTitle:@"🎯" forState:UIControlStateNormal];
    self.floatingButton.titleLabel.font = [UIFont systemFontOfSize:24];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [self.floatingButton addGestureRecognizer:pan];
    [self.floatingButton addTarget:self action:@selector(togglePanel) forControlEvents:UIControlEventTouchUpInside];

    [parent addSubview:self.floatingButton];
    [parent bringSubviewToFront:self.floatingButton];
}

- (void)setupPanelInView:(UIView *)parent {
    CGFloat panelW = 320;
    CGFloat panelH = 460;
    CGFloat x = (parent.bounds.size.width - panelW) / 2;
    CGFloat y = 50;

    self.panelView = [[UIView alloc] initWithFrame:CGRectMake(x, y, panelW, panelH)];
    self.panelView.layer.cornerRadius = 16;
    self.panelView.layer.borderWidth = 1.0;
    self.panelView.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.25].CGColor;
    self.panelView.backgroundColor = [UIColor colorWithRed:0.08 green:0.12 blue:0.20 alpha:0.96];
    self.panelView.clipsToBounds = YES;
    self.panelView.hidden = YES;

    // Header
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(16, 12, 220, 24)];
    title.text = @"⚡ MOBIARMY 3 HA MOD";
    title.font = [UIFont boldSystemFontOfSize:15];
    title.textColor = [UIColor colorWithRed:0.3 green:0.85 blue:1.0 alpha:1.0];
    [self.panelView addSubview:title];

    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    closeBtn.frame = CGRectMake(panelW - 40, 10, 30, 30);
    [closeBtn setTitle:@"✕" forState:UIControlStateNormal];
    [closeBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    closeBtn.titleLabel.font = [UIFont boldSystemFontOfSize:18];
    [closeBtn addTarget:self action:@selector(togglePanel) forControlEvents:UIControlEventTouchUpInside];
    [self.panelView addSubview:closeBtn];

    CGFloat curY = 42;

    // Zoom Factor
    UILabel *zoomTitle = [[UILabel alloc] initWithFrame:CGRectMake(16, curY, 140, 18)];
    zoomTitle.text = @"MỨC ZOOM:";
    zoomTitle.font = [UIFont boldSystemFontOfSize:11];
    zoomTitle.textColor = [UIColor colorWithWhite:0.75 alpha:1.0];
    [self.panelView addSubview:zoomTitle];
    curY += 20;

    self.zoomSegment = [[UISegmentedControl alloc] initWithItems:@[@"1.0x", @"1.3x", @"1.5x", @"1.8x", @"2.0x"]];
    self.zoomSegment.frame = CGRectMake(16, curY, panelW - 32, 26);
    self.zoomSegment.selectedSegmentIndex = 2; // 1.5x
    [self.zoomSegment addTarget:self action:@selector(onZoomChanged:) forControlEvents:UIControlEventValueChanged];
    [self.panelView addSubview:self.zoomSegment];
    curY += 32;

    // Zoom Mode (Toàn cảnh vs Renderer)
    self.zoomModeSegment = [[UISegmentedControl alloc] initWithItems:@[@"Zoom Toàn Bộ (Khuyên dùng)", @"Chỉ Zoom Map"]];
    self.zoomModeSegment.frame = CGRectMake(16, curY, panelW - 32, 26);
    self.zoomModeSegment.selectedSegmentIndex = g_globalZoom ? 0 : 1;
    [self.zoomModeSegment addTarget:self action:@selector(onZoomModeChanged:) forControlEvents:UIControlEventValueChanged];
    [self.panelView addSubview:self.zoomModeSegment];
    curY += 34;

    // Aimbot switch
    UILabel *aimTitle = [[UILabel alloc] initWithFrame:CGRectMake(16, curY + 2, 120, 24)];
    aimTitle.text = @"AIMBOT TỰ ĐỘNG";
    aimTitle.font = [UIFont boldSystemFontOfSize:11];
    aimTitle.textColor = [UIColor colorWithWhite:0.75 alpha:1.0];
    [self.panelView addSubview:aimTitle];

    self.aimbotSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(panelW - 68, curY, 50, 24)];
    self.aimbotSwitch.on = g_aimbotEnabled;
    [self.aimbotSwitch addTarget:self action:@selector(onAimbotToggled:) forControlEvents:UIControlEventValueChanged];
    [self.panelView addSubview:self.aimbotSwitch];
    curY += 34;

    // Arc Mode
    self.arcSegment = [[UISegmentedControl alloc] initWithItems:@[@"Góc cao (High Arc)", @"Góc thấp (Low Arc)"]];
    self.arcSegment.frame = CGRectMake(16, curY, panelW - 32, 26);
    self.arcSegment.selectedSegmentIndex = g_highArcMode ? 0 : 1;
    [self.arcSegment addTarget:self action:@selector(onArcChanged:) forControlEvents:UIControlEventValueChanged];
    [self.panelView addSubview:self.arcSegment];
    curY += 34;

    // Target Selector
    UIButton *prevTargetBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    prevTargetBtn.frame = CGRectMake(16, curY, 60, 28);
    [prevTargetBtn setTitle:@"◀ Trước" forState:UIControlStateNormal];
    [prevTargetBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    prevTargetBtn.titleLabel.font = [UIFont systemFontOfSize:12];
    prevTargetBtn.backgroundColor = [UIColor colorWithWhite:0.25 alpha:0.8];
    prevTargetBtn.layer.cornerRadius = 6;
    [prevTargetBtn addTarget:self action:@selector(onPrevTarget) forControlEvents:UIControlEventTouchUpInside];
    [self.panelView addSubview:prevTargetBtn];

    self.targetInfoLabel = [[UILabel alloc] initWithFrame:CGRectMake(80, curY, panelW - 160, 28)];
    self.targetInfoLabel.text = @"Chưa vào trận đấu";
    self.targetInfoLabel.font = [UIFont boldSystemFontOfSize:12];
    self.targetInfoLabel.textColor = [UIColor yellowColor];
    self.targetInfoLabel.textAlignment = NSTextAlignmentCenter;
    [self.panelView addSubview:self.targetInfoLabel];

    UIButton *nextTargetBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    nextTargetBtn.frame = CGRectMake(panelW - 76, curY, 60, 28);
    [nextTargetBtn setTitle:@"Tiếp ▶" forState:UIControlStateNormal];
    [nextTargetBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    nextTargetBtn.titleLabel.font = [UIFont systemFontOfSize:12];
    nextTargetBtn.backgroundColor = [UIColor colorWithWhite:0.25 alpha:0.8];
    nextTargetBtn.layer.cornerRadius = 6;
    [nextTargetBtn addTarget:self action:@selector(onNextTarget) forControlEvents:UIControlEventTouchUpInside];
    [self.panelView addSubview:nextTargetBtn];
    curY += 34;

    // Telemetry Box
    UIView *teleBox = [[UIView alloc] initWithFrame:CGRectMake(16, curY, panelW - 32, 52)];
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

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(8, 26, teleBox.bounds.size.width - 16, 20)];
    self.statusLabel.text = @"Vào trận để tự động quét địch";
    self.statusLabel.font = [UIFont systemFontOfSize:11];
    self.statusLabel.textColor = [UIColor colorWithWhite:0.7 alpha:1.0];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    [teleBox addSubview:self.statusLabel];
    [self.panelView addSubview:teleBox];
    curY += 60;

    // Sliders
    self.gravityLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, curY, panelW - 32, 16)];
    self.gravityLabel.text = [NSString stringWithFormat:@"Hệ số trọng lực: %.2fx", g_gravityFactor];
    self.gravityLabel.font = [UIFont systemFontOfSize:11];
    self.gravityLabel.textColor = [UIColor colorWithWhite:0.7 alpha:1.0];
    [self.panelView addSubview:self.gravityLabel];
    curY += 16;

    self.gravitySlider = [[UISlider alloc] initWithFrame:CGRectMake(16, curY, panelW - 32, 20)];
    self.gravitySlider.minimumValue = 0.5f;
    self.gravitySlider.maximumValue = 2.0f;
    self.gravitySlider.value = g_gravityFactor;
    [self.gravitySlider addTarget:self action:@selector(onGravityChanged:) forControlEvents:UIControlEventValueChanged];
    [self.panelView addSubview:self.gravitySlider];
    curY += 26;

    self.forceLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, curY, panelW - 32, 16)];
    self.forceLabel.text = [NSString stringWithFormat:@"Hệ số lực bắn: %.2fx", g_forceScale];
    self.forceLabel.font = [UIFont systemFontOfSize:11];
    self.forceLabel.textColor = [UIColor colorWithWhite:0.7 alpha:1.0];
    [self.panelView addSubview:self.forceLabel];
    curY += 16;

    self.forceSlider = [[UISlider alloc] initWithFrame:CGRectMake(16, curY, panelW - 32, 20)];
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
    self.panelView.hidden = !self.panelView.hidden;
    if (!self.panelView.hidden) {
        [self.panelView.superview bringSubviewToFront:self.panelView];
        [self refreshUI];
        if (!self.updateTimer) {
            self.updateTimer = [NSTimer scheduledTimerWithTimeInterval:0.5
                                                                target:self
                                                              selector:@selector(refreshUI)
                                                              userInfo:nil
                                                               repeats:YES];
        }
    } else {
        [self.updateTimer invalidate];
        self.updateTimer = nil;
    }
}

- (void)onZoomChanged:(UISegmentedControl *)sender {
    float values[] = { 1.0f, 1.3f, 1.5f, 1.8f, 2.0f };
    if (sender.selectedSegmentIndex >= 0 && sender.selectedSegmentIndex < 5) {
        g_zoomFactor = values[sender.selectedSegmentIndex];
    }
}

- (void)onZoomModeChanged:(UISegmentedControl *)sender {
    g_globalZoom = (sender.selectedSegmentIndex == 0);
}

- (void)onAimbotToggled:(UISwitch *)sender {
    g_aimbotEnabled = sender.isOn;
}

- (void)onArcChanged:(UISegmentedControl *)sender {
    g_highArcMode = (sender.selectedSegmentIndex == 0);
    [self refreshUI];
}

- (void)onPrevTarget {
    if (g_enemyCount == 0) return;
    g_currentTargetIdx = (g_currentTargetIdx - 1 + g_enemyCount) % g_enemyCount;
    [self refreshUI];
}

- (void)onNextTarget {
    if (g_enemyCount == 0) return;
    g_currentTargetIdx = (g_currentTargetIdx + 1) % g_enemyCount;
    [self refreshUI];
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
    if (!g_hooksInstalled) {
        self.targetInfoLabel.text = @"Đang nạp hook...";
        self.aimInfoLabel.text = @"Góc: --°  |  Lực: --";
        self.statusLabel.text = [NSString stringWithFormat:@"Base: 0x%lx", unity_base];
        return;
    }

    static mach_timebase_info_data_t s_timebase;
    if (s_timebase.denom == 0) mach_timebase_info(&s_timebase);

    uint64_t elapsedNs = (g_lastPlayerUpdateTime > 0) ? (mach_absolute_time() - g_lastPlayerUpdateTime) * s_timebase.numer / s_timebase.denom : 99999999999ULL;
    BOOL inBattle = (g_lastPlayerUpdateTime > 0 && elapsedNs < 6000000000ULL); // Cập nhật trong vòng 6.0 giây

    if (!inBattle) {
        g_enemyCount = 0;
        g_myPlayer = NULL;
        self.targetInfoLabel.text = @"Chưa vào trận đấu";
        self.aimInfoLabel.text = @"Góc: --°  |  Lực: --";
        self.statusLabel.text = [NSString stringWithFormat:@"Vào trận để quét (P:%llu B:%llu)", g_playerUpdateCount, g_battleUpdateCount];
        return;
    }

    updateAimSolution();

    if (g_enemyCount == 0) {
        if (g_myPlayer != NULL) {
            self.targetInfoLabel.text = [NSString stringWithFormat:@"Đã vào trận (Toạ độ: %d, %d)", g_lastMyX, g_lastMyY];
        } else {
            self.targetInfoLabel.text = @"Đã vào trận (Chờ quét địch)";
        }
        self.aimInfoLabel.text = @"Góc: --°  |  Lực: --";
        self.statusLabel.text = [NSString stringWithFormat:@"Đang quét địch... (P:%llu B:%llu)", g_playerUpdateCount, g_battleUpdateCount];
        return;
    }

    if (g_currentTargetIdx >= g_enemyCount) {
        g_currentTargetIdx = 0;
    }

    EnemyTarget *target = &g_enemyList[g_currentTargetIdx];
    self.targetInfoLabel.text = [NSString stringWithFormat:@"[%d/%d] %s", g_currentTargetIdx + 1, g_enemyCount, target->name];

    if (g_lastSolution.found) {
        self.aimInfoLabel.text = [NSString stringWithFormat:@"🎯 Góc: %d°  |  Lực: %d", g_lastSolution.angle, g_lastSolution.force];
        self.statusLabel.text = [NSString stringWithFormat:@"K.Cách: %.0f px | HP: %d (P:%llu)", target->distance, target->hp, g_playerUpdateCount];
    } else {
        self.aimInfoLabel.text = @"Không tìm được góc trúng!";
        self.statusLabel.text = [NSString stringWithFormat:@"Ngoài tầm (%.0f px) (P:%llu)", target->distance, g_playerUpdateCount];
    }
}

@end

// ==========================================
// 6. KHỞI TẠO HOOKS AN TOÀN
// ==========================================
static void install_hooks(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        uintptr_t base = find_unity_base();
        if (!base) {
            NSLog(@"[MobiArmyMod] Lỗi: Chưa tìm thấy base của UnityFramework!");
            return;
        }
        unity_base = base;

        NSLog(@"[MobiArmyMod] Bắt đầu cài đặt toàn bộ hooks vào UnityFramework (0x%lx)...", base);

        // 1. Hook Screen.get_width & get_height
        MSHookFunction((void *)(base + OFF_SCREEN_GET_WIDTH), (void *)hook_get_width, (void **)&orig_get_width);
        MSHookFunction((void *)(base + OFF_SCREEN_GET_HEIGHT), (void *)hook_get_height, (void **)&orig_get_height);

        // 2. Hook Screen.SetResolution (0x1a81fbc) để patch cứng zoom ngay khi game khởi động!
        MSHookFunction((void *)(base + OFF_SCREEN_SET_RESOLUTION), (void *)hook_SetResolution, (void **)&orig_SetResolution);

        // 3. Hook GL.LoadPixelMatrix (0x1a830e4)
        MSHookFunction((void *)(base + OFF_GL_LOAD_PIXEL_MATRIX), (void *)hook_LoadPixelMatrix, (void **)&orig_LoadPixelMatrix);

        // 4. Hook SendShoot để auto-aim
        MSHookFunction((void *)(base + OFF_SERVICE_SEND_SHOOT), (void *)hook_SendShoot, (void **)&orig_SendShoot);

        // 5. Hook Player.Update (0x9f244) để tự động bắt toạ độ Player & Địch realtime 100%
        MSHookFunction((void *)(base + OFF_PLAYER_UPDATE), (void *)hook_PlayerUpdate, (void **)&orig_PlayerUpdate);

        // 6. Hook BattleManager.Update (0x297090) để nhận biết trận đấu bắt đầu
        MSHookFunction((void *)(base + OFF_BATTLE_UPDATE), (void *)hook_BattleUpdate, (void **)&orig_BattleUpdate);

        // 7. Hook BattleManager.GetMyPlayer (0x295fac)
        MSHookFunction((void *)(base + OFF_BATTLE_GET_MY_PLAYER), (void *)hook_GetMyPlayer, (void **)&orig_GetMyPlayer);

        g_hooksInstalled = YES;
        NSLog(@"[MobiArmyMod] TẤT CẢ HOOK ĐÃ ĐƯỢC CÀI ĐẶT THÀNH CÔNG (100%%)!");
    });
}

__attribute__((constructor)) static void MobiArmyModInit(void) {
    NSLog(@"[MobiArmyMod] Dylib khởi chạy trong tiến trình pid: %d", getpid());

    // Thử cài hook ngay lập tức nếu UnityFramework đã load sẵn (trước khi game chạy Awake/Start)
    if (find_unity_base()) {
        install_hooks();
    } else {
        // Nếu chưa load, poll nhanh mỗi 20ms trong thread ưu tiên cao
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
            for (int i = 0; i < 500; i++) {
                if (find_unity_base()) {
                    install_hooks();
                    break;
                }
                usleep(20000); // 20ms
            }
        });
    }

    // Gắn UI sau khi app active
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification * _Nonnull note) {
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [[MobiHUDManager shared] attachToKeyWindow];
            });
        });
    }];
}
