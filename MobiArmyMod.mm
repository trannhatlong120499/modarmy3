//
// MobiArmyMod.mm
// Bản Mod Zoom map & Aimbot an toàn tuyệt đối cho MobiArmy 3 HA (v1.0.1.0.3)
// Kiến trúc: iOS arm64 / arm64e (iPhone 14 Pro Max / Dopamine)
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dispatch/dispatch.h>
#import <mach/mach.h>
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
static float g_zoomFactor       = 1.6f;     // Mức zoom mặc định (1.3 - 2.0)
static BOOL  g_aimbotEnabled    = YES;      // Bật aimbot
static BOOL  g_highArcMode      = YES;      // YES: Góc cao (High Arc), NO: Góc thấp (Low Arc)
static float g_gravityFactor    = 1.0f;     // Hệ số trọng lực tinh chỉnh
static float g_forceScale       = 1.0f;     // Hệ số lực bắn tinh chỉnh
static int   g_currentTargetIdx = 0;        // Index mục tiêu hiện tại

// RVAs trong UnityFramework 1.0.1.0.3
#define OFF_SCREEN_GET_WIDTH            0x1a81aa0
#define OFF_SCREEN_GET_HEIGHT           0x1a81ae0
#define OFF_SERVICE_SEND_SHOOT          0x148704
#define OFF_BATTLE_GET_MY_PLAYER        0x295fac
#define OFF_BATTLE_MANAGER_CLASS_PTR    0x3bb9190

// Call-site của Renderer Map (Screen.get_width/height + 4)
static const uintptr_t kWidthSites[]  = { 0x194188, 0x194868, 0x194a98 };
static const uintptr_t kHeightSites[] = { 0x194194, 0x194874, 0x194aa4 };

// Offsets của thực thể Player
#define OFF_PLAYER_IS_ME        0x10   // Boolean
#define OFF_PLAYER_TEAM         0x13   // SByte
#define OFF_PLAYER_ID           0x18   // Int32
#define OFF_PLAYER_NAME         0x28   // Il2CppString*
#define OFF_PLAYER_HP           0x274  // Int32
#define OFF_PLAYER_X            0x278  // Int32
#define OFF_PLAYER_Y            0x27C  // Int32
#define OFF_PLAYER_CUR_X        0x280  // Single (float)
#define OFF_PLAYER_CUR_Y        0x284  // Single (float)

// Function Pointers
static uintptr_t unity_base = 0;
static void *(*p_GetMyPlayer)(void) = NULL;
static int (*orig_get_width)(void) = NULL;
static int (*orig_get_height)(void) = NULL;
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

// ---------- Helper tìm base UnityFramework ----------
static uintptr_t find_unity_base(void) {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strstr(name, "UnityFramework")) {
            return (uintptr_t)_dyld_get_image_header(i);
        }
    }
    return 0;
}

static inline bool matches_site(uintptr_t ra, const uintptr_t *sites, size_t n) {
    for (size_t i = 0; i < n; i++) {
        if (ra == unity_base + sites[i]) return true;
    }
    return false;
}

// ==========================================
// 1. ZOOM HOOK (Renderer Only với PAC Stripping)
// ==========================================
static int hook_get_width(void) {
    int w = orig_get_width ? orig_get_width() : 0;
    uintptr_t ra = (uintptr_t)__builtin_return_address(0);
    uintptr_t clean_ra = ra & 0x0000007fffffffffULL; // Gỡ PAC trên A16 arm64e
    if (matches_site(clean_ra, kWidthSites, sizeof(kWidthSites) / sizeof(kWidthSites[0]))) {
        return (int)(w * g_zoomFactor);
    }
    return w;
}

static int hook_get_height(void) {
    int h = orig_get_height ? orig_get_height() : 0;
    uintptr_t ra = (uintptr_t)__builtin_return_address(0);
    uintptr_t clean_ra = ra & 0x0000007fffffffffULL; // Gỡ PAC trên A16 arm64e
    if (matches_site(clean_ra, kHeightSites, sizeof(kHeightSites) / sizeof(kHeightSites[0]))) {
        return (int)(h * g_zoomFactor);
    }
    return h;
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

// ==========================================
// 3. QUÉT BỘ NHỚ VỊ TRÍ ĐỊCH (AN TOÀN TUYỆT ĐỐI)
// ==========================================
static void updateTargetsFromMemory(void) {
    g_enemyCount = 0;
    if (!p_GetMyPlayer || !unity_base) return;

    void *myPlayer = NULL;
    @try {
        myPlayer = p_GetMyPlayer();
    } @catch (id ex) {
        return;
    }
    if (!myPlayer || (uintptr_t)myPlayer < 0x100000000ULL) return;

    // Đọc toạ độ của MyPlayer
    g_lastMyX = *(int32_t *)((uintptr_t)myPlayer + OFF_PLAYER_X);
    g_lastMyY = *(int32_t *)((uintptr_t)myPlayer + OFF_PLAYER_Y);
    int8_t myTeam = *(int8_t *)((uintptr_t)myPlayer + OFF_PLAYER_TEAM);

    // BattleManager Class pointer tại unity_base + 0x3bb9190
    uintptr_t bmClassPtr = *(uintptr_t *)(unity_base + OFF_BATTLE_MANAGER_CLASS_PTR);
    if (!bmClassPtr || bmClassPtr < 0x100000000ULL) return;

    // Check cctor_finished: [bmClass + 0xe4] != 0
    uint32_t cctorFinished = *(uint32_t *)(bmClassPtr + 0xe4);
    if (!cctorFinished) return;

    // static_fields: [bmClass + 0xa0]
    uintptr_t staticFields = *(uintptr_t *)(bmClassPtr + 0xa0);
    if (!staticFields || staticFields < 0x100000000ULL) return;

    // Player[] array: [staticFields + 0x8]
    uintptr_t playersArr = *(uintptr_t *)(staticFields + 0x8);
    if (!playersArr || playersArr < 0x100000000ULL) return;

    uint32_t count = *(uint32_t *)(playersArr + 0x18);
    if (count == 0 || count > 32) return;

    void **items = (void **)(playersArr + 0x20);

    for (uint32_t i = 0; i < count; i++) {
        void *p = items[i];
        if (!p || (uintptr_t)p < 0x100000000ULL || p == myPlayer) continue;

        int8_t team = *(int8_t *)((uintptr_t)p + OFF_PLAYER_TEAM);
        int32_t hp = *(int32_t *)((uintptr_t)p + OFF_PLAYER_HP);
        int32_t px = *(int32_t *)((uintptr_t)p + OFF_PLAYER_X);
        int32_t py = *(int32_t *)((uintptr_t)p + OFF_PLAYER_Y);
        int32_t pid = *(int32_t *)((uintptr_t)p + OFF_PLAYER_ID);

        if (team != myTeam && hp > 0 && g_enemyCount < MAX_TARGETS) {
            EnemyTarget enemy;
            enemy.id = pid;
            enemy.x = px;
            enemy.y = py;
            enemy.hp = hp;
            enemy.team = team;
            float dx = (float)(px - g_lastMyX);
            float dy = (float)(py - g_lastMyY);
            enemy.distance = sqrtf(dx * dx + dy * dy);
            snprintf(enemy.name, sizeof(enemy.name), "Địch #%d (HP:%d)", pid, hp);
            g_enemyList[g_enemyCount++] = enemy;
        }
    }

    if (g_enemyCount == 0) {
        g_lastSolution.found = false;
        return;
    }

    if (g_currentTargetIdx >= g_enemyCount) {
        g_currentTargetIdx = 0;
    }

    EnemyTarget *target = &g_enemyList[g_currentTargetIdx];
    g_lastSolution = calculateAim(g_lastMyX, g_lastMyY, target->x, target->y, g_gravityFactor, g_forceScale, g_highArcMode);
}

// ==========================================
// 4. HOOK HÀM BẮN (SEND SHOOT HOOK)
// ==========================================
static void hook_SendShoot(void *self, int8_t shootType, int16_t angle, int16_t x, int16_t y, int8_t force, int8_t force2, int8_t unk, void *method) {
    @try {
        updateTargetsFromMemory();
        if (g_aimbotEnabled && g_lastSolution.found) {
            angle = g_lastSolution.angle;
            force = g_lastSolution.force;
            NSLog(@"[MobiAimbot] AUTO-AIM! Gốc:(%d,%d) -> Mod:(%d,%d) | Lệch:%.1f px",
                  angle, force, g_lastSolution.angle, g_lastSolution.force, g_lastSolution.landingError);
        }
    } @catch (id ex) {
        NSLog(@"[MobiAimbot] Error: %@", ex);
    }

    if (orig_SendShoot) {
        orig_SendShoot(self, shootType, angle, x, y, force, force2, unk, method);
    }
}

// ==========================================
// 5. GIAO DIỆN NỔI (ATTACH TRỰC TIẾP VÀO KEYWINDOW)
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
@property (nonatomic, strong) UISlider *gravitySlider;
@property (nonatomic, strong) UISlider *forceSlider;
@property (nonatomic, strong) UILabel *gravityLabel;
@property (nonatomic, strong) UILabel *forceLabel;
+ (instancetype)shared;
- (void)attachToKeyWindow;
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
    CGFloat panelH = 430;
    CGFloat x = (parent.bounds.size.width - panelW) / 2;
    CGFloat y = 80;

    self.panelView = [[UIView alloc] initWithFrame:CGRectMake(x, y, panelW, panelH)];
    self.panelView.layer.cornerRadius = 16;
    self.panelView.layer.borderWidth = 1.0;
    self.panelView.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.25].CGColor;
    self.panelView.backgroundColor = [UIColor colorWithRed:0.08 green:0.12 blue:0.20 alpha:0.95];
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

    CGFloat curY = 44;

    // Zoom
    UILabel *zoomTitle = [[UILabel alloc] initWithFrame:CGRectMake(16, curY, 120, 20)];
    zoomTitle.text = @"MỨC ZOOM MAP";
    zoomTitle.font = [UIFont boldSystemFontOfSize:12];
    zoomTitle.textColor = [UIColor colorWithWhite:0.7 alpha:1.0];
    [self.panelView addSubview:zoomTitle];
    curY += 22;

    self.zoomSegment = [[UISegmentedControl alloc] initWithItems:@[@"1.0x", @"1.4x", @"1.6x", @"1.8x", @"2.0x"]];
    self.zoomSegment.frame = CGRectMake(16, curY, panelW - 32, 28);
    self.zoomSegment.selectedSegmentIndex = 2; // 1.6x
    [self.zoomSegment addTarget:self action:@selector(onZoomChanged:) forControlEvents:UIControlEventValueChanged];
    [self.panelView addSubview:self.zoomSegment];
    curY += 38;

    // Aimbot switch
    UILabel *aimTitle = [[UILabel alloc] initWithFrame:CGRectMake(16, curY + 4, 120, 24)];
    aimTitle.text = @"AIMBOT TỰ ĐỘNG";
    aimTitle.font = [UIFont boldSystemFontOfSize:12];
    aimTitle.textColor = [UIColor colorWithWhite:0.7 alpha:1.0];
    [self.panelView addSubview:aimTitle];

    self.aimbotSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(panelW - 68, curY, 50, 24)];
    self.aimbotSwitch.on = g_aimbotEnabled;
    [self.aimbotSwitch addTarget:self action:@selector(onAimbotToggled:) forControlEvents:UIControlEventValueChanged];
    [self.panelView addSubview:self.aimbotSwitch];
    curY += 38;

    // Arc Mode
    self.arcSegment = [[UISegmentedControl alloc] initWithItems:@[@"Góc cao (High Arc)", @"Góc thấp (Low Arc)"]];
    self.arcSegment.frame = CGRectMake(16, curY, panelW - 32, 28);
    self.arcSegment.selectedSegmentIndex = g_highArcMode ? 0 : 1;
    [self.arcSegment addTarget:self action:@selector(onArcChanged:) forControlEvents:UIControlEventValueChanged];
    [self.panelView addSubview:self.arcSegment];
    curY += 36;

    // Target Selector
    UIButton *prevTargetBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    prevTargetBtn.frame = CGRectMake(16, curY, 36, 28);
    [prevTargetBtn setTitle:@"◀" forState:UIControlStateNormal];
    [prevTargetBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    prevTargetBtn.backgroundColor = [UIColor colorWithWhite:0.25 alpha:0.8];
    prevTargetBtn.layer.cornerRadius = 6;
    [prevTargetBtn addTarget:self action:@selector(onPrevTarget) forControlEvents:UIControlEventTouchUpInside];
    [self.panelView addSubview:prevTargetBtn];

    self.targetInfoLabel = [[UILabel alloc] initWithFrame:CGRectMake(56, curY, panelW - 112, 28)];
    self.targetInfoLabel.text = @"Chưa vào trận";
    self.targetInfoLabel.font = [UIFont systemFontOfSize:12];
    self.targetInfoLabel.textColor = [UIColor whiteColor];
    self.targetInfoLabel.textAlignment = NSTextAlignmentCenter;
    self.targetInfoLabel.backgroundColor = [UIColor colorWithWhite:0.15 alpha:0.8];
    self.targetInfoLabel.layer.cornerRadius = 6;
    self.targetInfoLabel.clipsToBounds = YES;
    [self.panelView addSubview:self.targetInfoLabel];

    UIButton *nextTargetBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    nextTargetBtn.frame = CGRectMake(panelW - 52, curY, 36, 28);
    [nextTargetBtn setTitle:@"▶" forState:UIControlStateNormal];
    [nextTargetBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    nextTargetBtn.backgroundColor = [UIColor colorWithWhite:0.25 alpha:0.8];
    nextTargetBtn.layer.cornerRadius = 6;
    [nextTargetBtn addTarget:self action:@selector(onNextTarget) forControlEvents:UIControlEventTouchUpInside];
    [self.panelView addSubview:nextTargetBtn];
    curY += 36;

    // Telemetry Box
    UIView *teleBox = [[UIView alloc] initWithFrame:CGRectMake(16, curY, panelW - 32, 54)];
    teleBox.backgroundColor = [UIColor colorWithRed:0.04 green:0.07 blue:0.12 alpha:0.9];
    teleBox.layer.cornerRadius = 8;
    teleBox.layer.borderWidth = 1.0;
    teleBox.layer.borderColor = [UIColor colorWithRed:0.2 green:0.5 blue:0.8 alpha:0.4].CGColor;

    self.aimInfoLabel = [[UILabel alloc] initWithFrame:CGRectMake(8, 4, teleBox.bounds.size.width - 16, 24)];
    self.aimInfoLabel.text = @"Góc: --°  |  Lực: --";
    self.aimInfoLabel.font = [UIFont boldSystemFontOfSize:15];
    self.aimInfoLabel.textColor = [UIColor colorWithRed:0.2 green:1.0 blue:0.5 alpha:1.0];
    self.aimInfoLabel.textAlignment = NSTextAlignmentCenter;
    [teleBox addSubview:self.aimInfoLabel];

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(8, 28, teleBox.bounds.size.width - 16, 20)];
    self.statusLabel.text = @"Vào trận để quét toạ độ địch";
    self.statusLabel.font = [UIFont systemFontOfSize:11];
    self.statusLabel.textColor = [UIColor colorWithWhite:0.7 alpha:1.0];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    [teleBox addSubview:self.statusLabel];
    [self.panelView addSubview:teleBox];
    curY += 64;

    // Sliders
    self.gravityLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, curY, panelW - 32, 16)];
    self.gravityLabel.text = [NSString stringWithFormat:@"Hệ số trọng lực: %.2fx", g_gravityFactor];
    self.gravityLabel.font = [UIFont systemFontOfSize:11];
    self.gravityLabel.textColor = [UIColor colorWithWhite:0.7 alpha:1.0];
    [self.panelView addSubview:self.gravityLabel];
    curY += 18;

    self.gravitySlider = [[UISlider alloc] initWithFrame:CGRectMake(16, curY, panelW - 32, 20)];
    self.gravitySlider.minimumValue = 0.5f;
    self.gravitySlider.maximumValue = 2.0f;
    self.gravitySlider.value = g_gravityFactor;
    [self.gravitySlider addTarget:self action:@selector(onGravityChanged:) forControlEvents:UIControlEventValueChanged];
    [self.panelView addSubview:self.gravitySlider];
    curY += 28;

    self.forceLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, curY, panelW - 32, 16)];
    self.forceLabel.text = [NSString stringWithFormat:@"Hệ số lực bắn: %.2fx", g_forceScale];
    self.forceLabel.font = [UIFont systemFontOfSize:11];
    self.forceLabel.textColor = [UIColor colorWithWhite:0.7 alpha:1.0];
    [self.panelView addSubview:self.forceLabel];
    curY += 18;

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
        [self refreshUI];
    }
}

- (void)onZoomChanged:(UISegmentedControl *)sender {
    float values[] = { 1.0f, 1.4f, 1.6f, 1.8f, 2.0f };
    if (sender.selectedSegmentIndex >= 0 && sender.selectedSegmentIndex < 5) {
        g_zoomFactor = values[sender.selectedSegmentIndex];
    }
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
    updateTargetsFromMemory();

    if (g_enemyCount == 0) {
        self.targetInfoLabel.text = @"Chưa vào trận hoặc không có địch";
        self.aimInfoLabel.text = @"Góc: --°  |  Lực: --";
        self.statusLabel.text = @"Vào trận để quét toạ độ địch";
        return;
    }

    if (g_currentTargetIdx >= g_enemyCount) {
        g_currentTargetIdx = 0;
    }

    EnemyTarget *target = &g_enemyList[g_currentTargetIdx];
    self.targetInfoLabel.text = [NSString stringWithFormat:@"[%d/%d] %s", g_currentTargetIdx + 1, g_enemyCount, target->name];

    if (g_lastSolution.found) {
        self.aimInfoLabel.text = [NSString stringWithFormat:@"🎯 Góc: %d°  |  Lực: %d", g_lastSolution.angle, g_lastSolution.force];
        self.statusLabel.text = [NSString stringWithFormat:@"Khoảng cách: %.0f px", target->distance];
    } else {
        self.aimInfoLabel.text = @"Không tìm được góc trúng!";
        self.statusLabel.text = [NSString stringWithFormat:@"Ngoài tầm bắn (%.0f px)", target->distance];
    }
}

@end

// ==========================================
// 6. KHỞI TẠO HOOKS AN TOÀN
// ==========================================
static void install_hooks(void) {
    uintptr_t base = find_unity_base();
    if (!base) return;
    unity_base = base;

    // 1. Resolve GetMyPlayer
    p_GetMyPlayer = (void *(*)(void))(base + OFF_BATTLE_GET_MY_PLAYER);

    // 2. MSHookFunction Screen.get_width & get_height
    MSHookFunction((void *)(base + OFF_SCREEN_GET_WIDTH), (void *)hook_get_width, (void **)&orig_get_width);
    MSHookFunction((void *)(base + OFF_SCREEN_GET_HEIGHT), (void *)hook_get_height, (void **)&orig_get_height);

    // 3. MSHookFunction SendShoot
    MSHookFunction((void *)(base + OFF_SERVICE_SEND_SHOOT), (void *)hook_SendShoot, (void **)&orig_SendShoot);

    NSLog(@"[MobiArmyMod] MSHookFunction installed successfully on Screen & SendShoot!");
}

__attribute__((constructor)) static void MobiArmyModInit(void) {
    // Chờ UnityFramework load xong để hook function
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
        for (int i = 0; i < 60; i++) {
            if (find_unity_base()) {
                install_hooks();
                break;
            }
            usleep(200000); // 0.2s
        }
    });

    // Lắng nghe thông báo khi App đã sẵn sàng để gắn UI an toàn
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification * _Nonnull note) {
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            // Delay 3 giây để Unity khởi tạo xong view chính
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [[MobiHUDManager shared] attachToKeyWindow];
            });
        });
    }];
}
