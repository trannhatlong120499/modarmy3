//
// MobiArmyMod.mm
// Mod Zoom map & Aimbot cho MobiArmy 3 HA (v1.0.1.0.3)
// Kiến trúc: iOS Unity IL2CPP, arm64
//
// Tính năng:
//  1. Zoom map: Thu nhỏ map bằng cách scale ma trận renderer (GL.LoadPixelMatrix),
//     không làm biến dạng UI thông qua call-site matching.
//  2. Aimbot: Quét danh sách Player & Enemy từ BattleManager (Class 27) trong RAM,
//     tính góc bắn & lực bắn theo quỹ đạo đạn đạo parabol (Low Arc / High Arc),
//     tự động can thiệp ghi đè packet bắn (CMD 0x16 tại RVA 0x148704).
//  3. Menu HUD nổi (Floating Menu): Thiết kế Dark Glassmorphism sang trọng,
//     chỉnh mức Zoom, bật/tắt Aimbot, chọn mục tiêu địch, tinh chỉnh trọng lực & lực bắn.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dispatch/dispatch.h>
#import <mach/mach.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach/vm_page_size.h>

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

// ---------- IL2CPP Opaque Types ----------
typedef struct Il2CppDomain Il2CppDomain;
typedef struct Il2CppAssembly Il2CppAssembly;
typedef struct Il2CppImage Il2CppImage;
typedef struct Il2CppClass Il2CppClass;
typedef struct Il2CppString Il2CppString;

typedef struct Il2CppObject {
    void *klass;
    void *monitor;
} Il2CppObject;

typedef struct MethodInfo {
    void *methodPointer;
    void *invoker_method;
    const char *name;
    void *klass;
    const void *return_type;
    const void *parameters;
} MethodInfo;

typedef struct Il2CppArray {
    Il2CppObject obj;
    void *bounds;
    uintptr_t max_length;
} Il2CppArray;

// ---------- RVA trong UnityFramework 1.0.1.0.3 ----------
#define OFF_DOMAIN_GET                  0x1e67400
#define OFF_DOMAIN_GET_ASSEMBLIES       0x1e6740c
#define OFF_ASSEMBLY_GET_IMAGE          0x1e66e80
#define OFF_IMAGE_GET_NAME              0x1e67c20
#define OFF_CLASS_FROM_NAME             0x1e66eb8
#define OFF_CLASS_GET_METHOD_FROM_NAME  0x1e66ee0
#define OFF_THREAD_ATTACH               0x1e67964

#define OFF_SCREEN_GET_WIDTH            0x1a81aa0
#define OFF_SCREEN_GET_HEIGHT           0x1a81ae0

// Call-site của Renderer Map (Screen.get_width/height + 4)
static const uintptr_t kWidthSites[]  = { 0x194188, 0x194868, 0x194a98 };
static const uintptr_t kHeightSites[] = { 0x194194, 0x194874, 0x194aa4 };

// Game Function RVAs
// Service.SendShoot (token 0x06000CF1)
#define OFF_SERVICE_SEND_SHOOT          0x148704
// BattleManager.GetMyPlayer (token 0x060003E7)
#define OFF_BATTLE_GET_MY_PLAYER        0x295fac

// Class Offsets
#define OFF_PLAYER_IS_ME        0x10   // Boolean
#define OFF_PLAYER_TEAM         0x13   // SByte
#define OFF_PLAYER_ID           0x18   // Int32
#define OFF_PLAYER_NAME         0x28   // Il2CppString*
#define OFF_PLAYER_HP           0x274  // Int32
#define OFF_PLAYER_X            0x278  // Int32
#define OFF_PLAYER_Y            0x27C  // Int32
#define OFF_PLAYER_CUR_X        0x280  // Single (float)
#define OFF_PLAYER_CUR_Y        0x284  // Single (float)

// ---------- Typedefs cho Function Pointers ----------
typedef Il2CppDomain *(*domain_get_t)(void);
typedef Il2CppAssembly **(*domain_get_assemblies_t)(Il2CppDomain *, size_t *);
typedef Il2CppImage *(*assembly_get_image_t)(Il2CppAssembly *);
typedef const char *(*image_get_name_t)(Il2CppImage *);
typedef Il2CppClass *(*class_from_name_t)(const Il2CppImage *, const char *, const char *);
typedef MethodInfo *(*class_get_method_from_name_t)(Il2CppClass *, const char *, int);
typedef void *(*thread_attach_t)(Il2CppDomain *);

typedef int (*get_width_t)(const MethodInfo *);
typedef int (*get_height_t)(const MethodInfo *);
typedef void (*send_shoot_t)(void *, int8_t, int16_t, int16_t, int16_t, int8_t, int8_t, int8_t, const MethodInfo *);
typedef void *(*get_my_player_t)(void);

static domain_get_t p_domain_get;
static domain_get_assemblies_t p_domain_get_assemblies;
static assembly_get_image_t p_assembly_get_image;
static image_get_name_t p_image_get_name;
static class_from_name_t p_class_from_name;
static class_get_method_from_name_t p_class_get_method_from_name;
static thread_attach_t p_thread_attach;

static get_width_t orig_get_width;
static get_height_t orig_get_height;
static send_shoot_t orig_SendShoot;
static get_my_player_t p_GetMyPlayer;

static uintptr_t unity_base = 0;
static Il2CppImage *csharp_image = NULL;
static Il2CppClass *battle_manager_class = NULL;
static volatile int g_installed = 0;

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

static int matches_site(uintptr_t ra, const uintptr_t *sites, size_t n) {
    for (size_t i = 0; i < n; i++) {
        if (ra == unity_base + sites[i]) return 1;
    }
    return 0;
}

static void patch_method(MethodInfo *m, void *fn) {
    if (!m || !m->methodPointer) return;
    vm_address_t page = (vm_address_t)m & ~(vm_page_size - 1);
    kern_return_t kr = vm_protect(mach_task_self(), page, vm_page_size, false,
                                  VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (kr == KERN_SUCCESS) {
        m->methodPointer = fn;
    }
}

// ==========================================
// 1. ZOOM HOOK (Renderer Only)
// ==========================================
static int hook_get_width(const MethodInfo *mi) {
    int w = orig_get_width(mi);
    uintptr_t ra = (uintptr_t)__builtin_return_address(0);
    if (matches_site(ra, kWidthSites, sizeof(kWidthSites) / sizeof(kWidthSites[0]))) {
        return (int)(w * g_zoomFactor);
    }
    return w;
}

static int hook_get_height(const MethodInfo *mi) {
    int h = orig_get_height(mi);
    uintptr_t ra = (uintptr_t)__builtin_return_address(0);
    if (matches_site(ra, kHeightSites, sizeof(kHeightSites) / sizeof(kHeightSites[0]))) {
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
    float dy = (float)(y0 - y1); // Trục y game hướng xuống, nên dy = y0 - y1 (dương = mục tiêu ở cao hơn)
    float dist = fabsf(dx);
    if (dist < 1.0f) dist = 1.0f;

    bool shootingRight = (dx >= 0);
    float g = 9.8f * gravityScale;

    // Giới hạn góc tìm kiếm:
    // Góc cao: 55° đến 85° (vượt địa hình, rơi từ trên xuống)
    // Góc thấp: 20° đến 54° (bắn thẳng, đường đạn căng)
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

        // Phương trình quỹ đạo: dy = dist * tan(α) - (g * dist^2) / (2 * v^2 * cos^2(α))
        // Suy ra: v^2 = (g * dist^2) / (2 * cos^2(α) * (dist * tan(α) - dy))
        float rhs = dist * tanA - dy;
        if (rhs <= 0.001f) continue; // Góc này đạn không thể đạt độ cao mục tiêu

        float vSq = (g * dist * dist) / (2.0f * cosA * cosA * rhs);
        if (vSq <= 0.0f) continue;
        float v = sqrtf(vSq);

        // Quy đổi vận tốc v sang thanh lực trong game (0 - 30)
        // Hệ số chuẩn hóa v -> force trong MobiArmy
        float rawForce = (v * 0.48f) / forceScale;
        int forceInt = (int)roundf(rawForce);
        if (forceInt < 5) forceInt = 5;
        if (forceInt > 30) {
            if (forceInt > 60) continue; // Vượt quá lực tối đa cho phép
        }

        // Tính sai số rơi thực tế với lực nguyên này
        float actualV = ((float)forceInt * forceScale) / 0.48f;
        float actualDrop = (g * dist * dist) / (2.0f * actualV * actualV * cosA * cosA);
        float actualY = dist * tanA - actualDrop;
        float err = fabsf(actualY - dy);

        if (err < bestError) {
            bestError = err;
            bestAngle = deg;
            bestForce = forceInt;
            if (err < 2.0f) break; // Sai số dưới 2 pixel coi như trúng đích
        }
    }

    // Góc nòng: nếu bắn sang trái thì đảo góc (180 - alpha)
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
// 3. QUÉT BỘ NHỚ VỊ TRÍ ĐỊCH (RUNTIME SCANNER)
// ==========================================
static void updateTargetsFromMemory(void) {
    g_enemyCount = 0;

    if (!p_GetMyPlayer || !battle_manager_class) return;

    void *myPlayer = p_GetMyPlayer();
    if (!myPlayer) return;

    // Đọc toạ độ của MyPlayer
    g_lastMyX = *(int32_t *)((uintptr_t)myPlayer + OFF_PLAYER_X);
    g_lastMyY = *(int32_t *)((uintptr_t)myPlayer + OFF_PLAYER_Y);
    int8_t myTeam = *(int8_t *)((uintptr_t)myPlayer + OFF_PLAYER_TEAM);

    // Đọc danh sách player từ BattleManager.static_fields
    // BattleManager Class 27: static_fields + 8 là mảng Player[]
    void *staticFields = *(void **)((uintptr_t)battle_manager_class + 0xa0); // klass->static_fields
    if (!staticFields) return;

    Il2CppArray *playersArr = *(Il2CppArray **)((uintptr_t)staticFields + 0x8);
    if (!playersArr) return;

    uint32_t count = *(uint32_t *)((uintptr_t)playersArr + 0x18);
    void **items = (void **)((uintptr_t)playersArr + 0x20);

    for (uint32_t i = 0; i < count; i++) {
        void *p = items[i];
        if (!p || p == myPlayer) continue;

        int8_t team = *(int8_t *)((uintptr_t)p + OFF_PLAYER_TEAM);
        int32_t hp = *(int32_t *)((uintptr_t)p + OFF_PLAYER_HP);
        int32_t px = *(int32_t *)((uintptr_t)p + OFF_PLAYER_X);
        int32_t py = *(int32_t *)((uintptr_t)p + OFF_PLAYER_Y);
        int32_t pid = *(int32_t *)((uintptr_t)p + OFF_PLAYER_ID);

        // Chỉ nhắm vào kẻ địch (khác team) và còn sống (hp > 0)
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

    // Đảm bảo target index hợp lệ
    if (g_currentTargetIdx >= g_enemyCount) {
        g_currentTargetIdx = 0;
    }

    EnemyTarget *target = &g_enemyList[g_currentTargetIdx];
    g_lastSolution = calculateAim(g_lastMyX, g_lastMyY, target->x, target->y, g_gravityFactor, g_forceScale, g_highArcMode);
}

// ==========================================
// 4. HOOK HÀM BẮN (SEND SHOOT HOOK)
// ==========================================
static void hook_SendShoot(void *self, int8_t shootType, int16_t angle, int16_t x, int16_t y, int8_t force, int8_t force2, int8_t unk, const MethodInfo *method) {
    updateTargetsFromMemory();

    if (g_aimbotEnabled && g_lastSolution.found) {
        int16_t originalAngle = angle;
        int8_t  originalForce = force;

        // Tự động thay thế góc và lực tính toán được
        angle = g_lastSolution.angle;
        force = g_lastSolution.force;

        NSLog(@"[MobiAimbot] AUTO-AIM ACTIVE! Gốc: (Góc:%d, Lực:%d) -> Aimbot: (Góc:%d, Lực:%d) | Lệch: %.1f px",
              originalAngle, originalForce, angle, force, g_lastSolution.landingError);
    }

    orig_SendShoot(self, shootType, angle, x, y, force, force2, unk, method);
}

// ==========================================
// 5. GIAO DIỆN NỔI (FLOATING HUD MENU)
// ==========================================
@interface MobiHUDController : UIViewController
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
@property (nonatomic, strong) NSTimer *refreshTimer;
@end

@implementation MobiHUDController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor clearColor];

    [self setupFloatingButton];
    [self setupPanel];

    // Timer cập nhật thông số liên tục 0.5s/lần
    self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(onTimerTick) userInfo:nil repeats:YES];
}

- (void)setupFloatingButton {
    self.floatingButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.floatingButton.frame = CGRectMake(20, 100, 50, 50);
    self.floatingButton.layer.cornerRadius = 25;
    self.floatingButton.layer.borderWidth = 1.5;
    self.floatingButton.layer.borderColor = [UIColor colorWithRed:0.2 green:0.8 blue:1.0 alpha:0.8].CGColor;
    self.floatingButton.backgroundColor = [UIColor colorWithRed:0.05 green:0.1 blue:0.18 alpha:0.85];
    [self.floatingButton setTitle:@"🎯" forState:UIControlStateNormal];
    self.floatingButton.titleLabel.font = [UIFont systemFontOfSize:24];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [self.floatingButton addGestureRecognizer:pan];
    [self.floatingButton addTarget:self action:@selector(togglePanel) forControlEvents:UIControlEventTouchUpInside];

    [self.view addSubview:self.floatingButton];
}

- (void)setupPanel {
    CGFloat panelW = 320;
    CGFloat panelH = 430;
    CGFloat x = (self.view.bounds.size.width - panelW) / 2;
    CGFloat y = 80;

    self.panelView = [[UIView alloc] initWithFrame:CGRectMake(x, y, panelW, panelH)];
    self.panelView.layer.cornerRadius = 16;
    self.panelView.layer.borderWidth = 1.0;
    self.panelView.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.2].CGColor;
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

    // Section 1: ZOOM
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

    // Section 2: AIMBOT SWITCH & ARC
    UILabel *aimTitle = [[UILabel alloc] initWithFrame:CGRectMake(16, curY + 4, 100, 24)];
    aimTitle.text = @"AIMBOT TỰ ĐỘNG";
    aimTitle.font = [UIFont boldSystemFontOfSize:12];
    aimTitle.textColor = [UIColor colorWithWhite:0.7 alpha:1.0];
    [self.panelView addSubview:aimTitle];

    self.aimbotSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(panelW - 68, curY, 50, 24)];
    self.aimbotSwitch.on = g_aimbotEnabled;
    [self.aimbotSwitch addTarget:self action:@selector(onAimbotToggled:) forControlEvents:UIControlEventValueChanged];
    [self.panelView addSubview:self.aimbotSwitch];
    curY += 38;

    // Arc Mode Segment
    self.arcSegment = [[UISegmentedControl alloc] initWithItems:@[@"Góc cao (High Arc)", @"Góc thấp (Low Arc)"]];
    self.arcSegment.frame = CGRectMake(16, curY, panelW - 32, 28);
    self.arcSegment.selectedSegmentIndex = g_highArcMode ? 0 : 1;
    [self.arcSegment addTarget:self action:@selector(onArcChanged:) forControlEvents:UIControlEventValueChanged];
    [self.panelView addSubview:self.arcSegment];
    curY += 36;

    // Section 3: TARGET SELECTOR
    UIButton *prevTargetBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    prevTargetBtn.frame = CGRectMake(16, curY, 36, 28);
    [prevTargetBtn setTitle:@"◀" forState:UIControlStateNormal];
    [prevTargetBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    prevTargetBtn.backgroundColor = [UIColor colorWithWhite:0.25 alpha:0.8];
    prevTargetBtn.layer.cornerRadius = 6;
    [prevTargetBtn addTarget:self action:@selector(onPrevTarget) forControlEvents:UIControlEventTouchUpInside];
    [self.panelView addSubview:prevTargetBtn];

    self.targetInfoLabel = [[UILabel alloc] initWithFrame:CGRectMake(56, curY, panelW - 112, 28)];
    self.targetInfoLabel.text = @"Đang quét địch...";
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
    self.statusLabel.text = @"Khoảng cách: -- px";
    self.statusLabel.font = [UIFont systemFontOfSize:11];
    self.statusLabel.textColor = [UIColor colorWithWhite:0.7 alpha:1.0];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    [teleBox addSubview:self.statusLabel];
    [self.panelView addSubview:teleBox];
    curY += 64;

    // Fine tuning sliders (Trọng lực & Lực bắn)
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

    [self.view addSubview:self.panelView];
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    CGPoint translation = [pan translationInView:self.view];
    self.floatingButton.center = CGPointMake(self.floatingButton.center.x + translation.x, self.floatingButton.center.y + translation.y);
    [pan setTranslation:CGPointZero inView:self.view];
}

- (void)togglePanel {
    self.panelView.hidden = !self.panelView.hidden;
    if (!self.panelView.hidden) {
        [self onTimerTick];
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
    [self onTimerTick];
}

- (void)onPrevTarget {
    if (g_enemyCount == 0) return;
    g_currentTargetIdx = (g_currentTargetIdx - 1 + g_enemyCount) % g_enemyCount;
    [self onTimerTick];
}

- (void)onNextTarget {
    if (g_enemyCount == 0) return;
    g_currentTargetIdx = (g_currentTargetIdx + 1) % g_enemyCount;
    [self onTimerTick];
}

- (void)onGravityChanged:(UISlider *)sender {
    g_gravityFactor = sender.value;
    self.gravityLabel.text = [NSString stringWithFormat:@"Hệ số trọng lực: %.2fx", g_gravityFactor];
    [self onTimerTick];
}

- (void)onForceChanged:(UISlider *)sender {
    g_forceScale = sender.value;
    self.forceLabel.text = [NSString stringWithFormat:@"Hệ số lực bắn: %.2fx", g_forceScale];
    [self onTimerTick];
}

- (void)onTimerTick {
    updateTargetsFromMemory();

    if (g_enemyCount == 0) {
        self.targetInfoLabel.text = @"Chưa vào trận hoặc không có địch";
        self.aimInfoLabel.text = @"Góc: --°  |  Lực: --";
        self.statusLabel.text = @"Vào trận để tự động quét toạ độ địch";
        return;
    }

    if (g_currentTargetIdx >= g_enemyCount) {
        g_currentTargetIdx = 0;
    }

    EnemyTarget *target = &g_enemyList[g_currentTargetIdx];
    self.targetInfoLabel.text = [NSString stringWithFormat:@"[%d/%d] %s", g_currentTargetIdx + 1, g_enemyCount, target->name];

    if (g_lastSolution.found) {
        self.aimInfoLabel.text = [NSString stringWithFormat:@"🎯 Góc: %d°  |  Lực: %d", g_lastSolution.angle, g_lastSolution.force];
        self.statusLabel.text = [NSString stringWithFormat:@"Khoảng cách: %.0f px (dX: %d, dY: %d)", target->distance, (target->x - g_lastMyX), (g_lastMyY - target->y)];
    } else {
        self.aimInfoLabel.text = @"Không tìm được góc trúng!";
        self.statusLabel.text = [NSString stringWithFormat:@"Mục tiêu ngoài tầm bắn (%.0f px)", target->distance];
    }
}

@end

// ==========================================
// 6. KHỞI TẠO VÀ HOOK SYSTEM (INIT)
// ==========================================
static UIWindow *g_hudWindow = nil;

static void setupHUD(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindowScene *scene = nil;
        for (UIWindowScene *s in [UIApplication sharedApplication].connectedScenes) {
            if ([s isKindOfClass:[UIWindowScene class]] && s.activationState == UISceneActivationStateForegroundActive) {
                scene = s;
                break;
            }
        }

        if (scene) {
            g_hudWindow = [[UIWindow alloc] initWithWindowScene:scene];
        } else {
            g_hudWindow = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        }

        g_hudWindow.windowLevel = UIWindowLevelAlert + 100;
        g_hudWindow.backgroundColor = [UIColor clearColor];
        MobiHUDController *ctrl = [[MobiHUDController alloc] init];
        g_hudWindow.rootViewController = ctrl;
        g_hudWindow.hidden = NO;
        NSLog(@"[MobiArmyMod] Floating HUD Window initialized successfully!");
    });
}

static void install_mod_once(void) {
    if (g_installed) return;

    uintptr_t base = find_unity_base();
    if (!base) return;

    unity_base = base;
    p_domain_get = (domain_get_t)(base + OFF_DOMAIN_GET);
    p_domain_get_assemblies = (domain_get_assemblies_t)(base + OFF_DOMAIN_GET_ASSEMBLIES);
    p_assembly_get_image = (assembly_get_image_t)(base + OFF_ASSEMBLY_GET_IMAGE);
    p_image_get_name = (image_get_name_t)(base + OFF_IMAGE_GET_NAME);
    p_class_from_name = (class_from_name_t)(base + OFF_CLASS_FROM_NAME);
    p_class_get_method_from_name = (class_get_method_from_name_t)(base + OFF_CLASS_GET_METHOD_FROM_NAME);
    p_thread_attach = (thread_attach_t)(base + OFF_THREAD_ATTACH);

    Il2CppDomain *domain = p_domain_get();
    if (!domain) return;
    p_thread_attach(domain);

    size_t asm_count = 0;
    Il2CppAssembly **asms = p_domain_get_assemblies(domain, &asm_count);
    if (!asms) return;

    // 1. Hook Screen.get_width & get_height cho Zoom
    for (size_t i = 0; i < asm_count; i++) {
        Il2CppImage *img = p_assembly_get_image(asms[i]);
        if (!img) continue;
        const char *img_name = p_image_get_name(img);
        if (!img_name) continue;

        if (strstr(img_name, "Assembly-CSharp")) {
            csharp_image = img;
        }

        Il2CppClass *screen = p_class_from_name(img, "UnityEngine", "Screen");
        if (screen && !orig_get_width) {
            MethodInfo *mw = p_class_get_method_from_name(screen, "get_width", 0);
            MethodInfo *mh = p_class_get_method_from_name(screen, "get_height", 0);
            if (mw && mh && mw->methodPointer && mh->methodPointer) {
                orig_get_width = (get_width_t)mw->methodPointer;
                orig_get_height = (get_height_t)mh->methodPointer;
                patch_method(mw, (void *)hook_get_width);
                patch_method(mh, (void *)hook_get_height);
                NSLog(@"[MobiArmyMod] Zoom hooks installed successfully!");
            }
        }
    }

    // 2. Tìm BattleManager & MyPlayer
    if (csharp_image) {
        battle_manager_class = p_class_from_name(csharp_image, "lllIIlllllllIlIIIIllIIIIIlllIIIlIlIl", "llIlIlIIlllllllllllIlllIIllIlllIIIlIIIlIIllIllIIIIIIlIlIIIlIlIIlIIlIllIl");
        p_GetMyPlayer = (get_my_player_t)(base + OFF_BATTLE_GET_MY_PLAYER);

        // 3. Hook hàm bắn SendShoot
        Il2CppClass *serviceClass = p_class_from_name(csharp_image, "llIIIIIIlIlllIIllIlllIlIlIllIlllIIII", "lIIlIlIIlIllIIlIIlIIIIllllIIlIIllIllIIIlIIlIIlIIIllIIIIIIllIllIlIIlllIIl");
        if (serviceClass) {
            MethodInfo *shootMethod = p_class_get_method_from_name(serviceClass, "lllIIIIIllIllIIlIIIIlIlIIlIIllIIlIlIIllIIlIlIIIIIIlIllIlllIllIIIIlllllII", 7);
            if (shootMethod && shootMethod->methodPointer) {
                orig_SendShoot = (send_shoot_t)shootMethod->methodPointer;
                patch_method(shootMethod, (void *)hook_SendShoot);
                NSLog(@"[MobiArmyMod] Aimbot SendShoot hook installed successfully!");
            }
        }
    }

    g_installed = 1;
    NSLog(@"[MobiArmyMod] Fully installed! Zoom=%.2f, Aimbot=%d", g_zoomFactor, g_aimbotEnabled);

    // Khởi tạo Floating HUD sau khi app chạy
    setupHUD();
}

__attribute__((constructor)) static void MobiArmyModInit(void) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
        for (int i = 0; i < 600 && !g_installed; i++) {
            install_mod_once();
            if (!g_installed) usleep(500000); // 0.5s
        }
        if (!g_installed) {
            NSLog(@"[MobiArmyMod] Timeout waiting for UnityFramework");
        }
    });
}
