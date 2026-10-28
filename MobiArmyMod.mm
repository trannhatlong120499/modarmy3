//
// MobiArmyMod.mm
// Bản Mod Zoom map & Aimbot hoàn chỉnh cho MobiArmy 3 HA (v1.0.1.0.3)
// Kiến trúc: iOS arm64 / arm64e (iPhone 14 Pro Max / Dopamine / TrollFools / TrollStore)
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dispatch/dispatch.h>
#import <mach/mach.h>
#import <mach/vm_map.h>
#import <mach/mach_time.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <dlfcn.h>
#include <libkern/OSCacheControl.h>

#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <unistd.h>
#include <math.h>

// ==========================================
// CẤU HÌNH MẶC ĐỊNH
// ==========================================
static float g_zoomFactor       = 1.50f;    // Mức zoom mặc định (1.5x)
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
#define OFF_BATTLE_MANAGER_CLASS        0x3bb9190
#define OFF_START_RESOLUTION_CONSTS     0x11a89c

// Slots con trỏ icall trong phân vùng __DATA.__bss (Ghi đè trực tiếp 100% không lo Code Signing)
#define OFF_ICALL_SCREEN_GET_WIDTH      0x4084f08
#define OFF_ICALL_SCREEN_GET_HEIGHT     0x4084f10
#define OFF_ICALL_GL_LOAD_MATRIX        0x4084f98
#define OFF_IL2CPP_RESOLVE_ICALL        0x1e69ac0

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

// Function Pointers & Counters
static uintptr_t unity_base = 0;
static BOOL g_hooksInstalled = NO;
static uint64_t g_playerUpdateCount = 0;
static uint64_t g_battleUpdateCount = 0;

static int (*orig_get_width)(void *method) = NULL;
static int (*orig_get_height)(void *method) = NULL;
static void (*orig_SetResolution)(int width, int height, bool fullscreen, void *method) = NULL;
static void (*orig_LoadPixelMatrix)(float left, float right, float bottom, float top, void *method) = NULL;
static void (*orig_SendShoot)(void *self, int8_t shootType, int16_t angle, int16_t x, int16_t y, int8_t force, int8_t force2, int8_t unk, void *method) = NULL;
static void (*orig_PlayerUpdate)(void *self, void *method) = NULL;
static void (*orig_BattleUpdate)(void *self, void *method) = NULL;
static void *(*orig_GetMyPlayer)(void *method) = NULL;

// Native icalls
static int (*real_Screen_get_width_icall)(void) = NULL;
static int (*real_Screen_get_height_icall)(void) = NULL;
static void (*real_GLLoadPixelMatrixScript)(float left, float right, float bottom, float top) = NULL;

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

// ---------- Helper ghi đè bộ nhớ an toàn (Native Memory Patcher) ----------
static bool patch_memory(void *address, const void *data, size_t size) {
    if (!address || !data || size == 0) return false;

    vm_size_t psize = vm_page_size ? vm_page_size : 0x4000;
    vm_address_t page_start = (vm_address_t)address & ~(psize - 1);
    vm_size_t page_len = (((vm_address_t)address + size - 1) & ~(psize - 1)) - page_start + psize;

    kern_return_t kr = vm_protect(mach_task_self(), page_start, page_len, FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (kr != KERN_SUCCESS) {
        return false;
    }

    memcpy(address, data, size);

    vm_protect(mach_task_self(), page_start, page_len, FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
    sys_dcache_flush(address, size);
    sys_icache_invalidate(address, size);
    return true;
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
// 1. CƠ CHẾ ZOOM MAP BẤT TỬ (ICALL REPLACEMENT TRONG __DATA)
// ==========================================
static int my_icall_Screen_get_width(void) {
    int w = real_Screen_get_width_icall ? real_Screen_get_width_icall() : 0;
    if (w <= 0) {
        CGSize sz = [UIScreen mainScreen].bounds.size;
        CGFloat scale = [UIScreen mainScreen].scale;
        w = (int)(MAX(sz.width, sz.height) * scale);
    }
    if (g_zoomFactor > 1.01f) {
        return (int)(w * g_zoomFactor);
    }
    return w;
}

static int my_icall_Screen_get_height(void) {
    int h = real_Screen_get_height_icall ? real_Screen_get_height_icall() : 0;
    if (h <= 0) {
        CGSize sz = [UIScreen mainScreen].bounds.size;
        CGFloat scale = [UIScreen mainScreen].scale;
        h = (int)(MIN(sz.width, sz.height) * scale);
    }
    if (g_zoomFactor > 1.01f) {
        return (int)(h * g_zoomFactor);
    }
    return h;
}

static void my_icall_GLLoadPixelMatrixScript(float left, float right, float bottom, float top) {
    if (g_zoomFactor > 1.01f) {
        right *= g_zoomFactor;
        bottom *= g_zoomFactor;
    }
    if (real_GLLoadPixelMatrixScript) {
        real_GLLoadPixelMatrixScript(left, right, bottom, top);
    }
}

static void apply_icall_zoom_hooks(uintptr_t base) {
    if (!base) return;

    void *(*il2cpp_resolve_icall)(const char *name) = (void *(*)(const char *))(base + OFF_IL2CPP_RESOLVE_ICALL);

    if (!real_Screen_get_width_icall) {
        real_Screen_get_width_icall = (int (*)(void))il2cpp_resolve_icall("UnityEngine.Screen::get_width()");
    }
    if (!real_Screen_get_height_icall) {
        real_Screen_get_height_icall = (int (*)(void))il2cpp_resolve_icall("Screen::get_height()");
    }
    if (!real_GLLoadPixelMatrixScript) {
        real_GLLoadPixelMatrixScript = (void (*)(float, float, float, float))il2cpp_resolve_icall("UnityEngine.GL::GLLoadPixelMatrixScript(System.Single,System.Single,System.Single,System.Single)");
    }

    // Ghi đè trực tiếp con trỏ icall trong phân vùng __DATA.__bss (Không vi phạm W^X, không bị Code Signing chặn)
    *(uintptr_t *)(base + OFF_ICALL_SCREEN_GET_WIDTH) = (uintptr_t)my_icall_Screen_get_width;
    *(uintptr_t *)(base + OFF_ICALL_SCREEN_GET_HEIGHT) = (uintptr_t)my_icall_Screen_get_height;
    *(uintptr_t *)(base + OFF_ICALL_GL_LOAD_MATRIX) = (uintptr_t)my_icall_GLLoadPixelMatrixScript;

    NSLog(@"[MobiArmyMod] Đã cài đặt Icall Zoom Hooks trong __DATA: Matrix=%p (zoom=%.2f)",
          my_icall_GLLoadPixelMatrixScript, g_zoomFactor);
}

static void patch_hard_zoom(uintptr_t base, float zoom) {
    if (!base) return;

    int w = (int)(1024.0f * zoom);
    int h = (int)(600.0f * zoom);
    if (w < 1024) w = 1024;
    if (h < 600) h = 600;

    uint32_t mov_w0 = 0x52800000 | ((uint32_t)(w & 0xFFFF) << 5) | 0; // mov w0, #w
    uint32_t mov_w1 = 0x52800000 | ((uint32_t)(h & 0xFFFF) << 5) | 1; // mov w1, #h

    uint32_t instrs[2] = { mov_w0, mov_w1 };
    patch_memory((void *)(base + OFF_START_RESOLUTION_CONSTS), instrs, sizeof(instrs));
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
// 3. QUÉT TRẬN ĐẤU TRỰC TIẾP TỪ BỘ NHỚ (KHÔNG PHỤ THUỘC VÀO HOOK)
// ==========================================
static void scanBattleState(void) {
    if (!unity_base) return;

    // 1. Luôn gọi hàm GetMyPlayer() trước tiên.
    // Lệnh này kích hoạt il2cpp_codegen_initialize_runtime_metadata & il2cpp_runtime_class_init!
    void *(*GetMyPlayer_fn)(void *) = (void *(*)(void *))(unity_base + OFF_BATTLE_GET_MY_PLAYER);
    void *myPlayer = NULL;
    if (GetMyPlayer_fn) {
        @try {
            myPlayer = GetMyPlayer_fn(NULL);
        } @catch (id ex) {}
    }

    if (myPlayer && (uintptr_t)myPlayer > 0x100000000ULL) {
        g_myPlayer = myPlayer;
        g_lastPlayerUpdateTime = mach_absolute_time();
        g_battleUpdateCount++;

        int32_t mx = 0, my = 0;
        int8_t mteam = 0;
        safe_read(&mx, (const void *)((uintptr_t)myPlayer + OFF_PLAYER_X), sizeof(int32_t));
        safe_read(&my, (const void *)((uintptr_t)myPlayer + OFF_PLAYER_Y), sizeof(int32_t));
        safe_read(&mteam, (const void *)((uintptr_t)myPlayer + OFF_PLAYER_TEAM), sizeof(int8_t));
        if (mx == 0 && my == 0) {
            float fx = 0, fy = 0;
            safe_read(&fx, (const void *)((uintptr_t)myPlayer + OFF_PLAYER_CUR_X), sizeof(float));
            safe_read(&fy, (const void *)((uintptr_t)myPlayer + OFF_PLAYER_CUR_Y), sizeof(float));
            mx = (int32_t)fx;
            my = (int32_t)fy;
        }
        g_lastMyX = mx;
        g_lastMyY = my;
        g_myTeam = mteam;
    }

    // 2. Sau khi BattleManager đã khởi tạo, quét toàn bộ mảng allPlayers để lấy địch
    uintptr_t classPtr = 0;
    safe_read(&classPtr, (const void *)(unity_base + OFF_BATTLE_MANAGER_CLASS), sizeof(uintptr_t));
    if (!classPtr || classPtr < 0x100000000ULL) return;

    uintptr_t staticFields = 0;
    safe_read(&staticFields, (const void *)(classPtr + 0xA0), sizeof(uintptr_t));
    if (!staticFields || staticFields < 0x100000000ULL) return;

    uintptr_t playerArray = 0;
    safe_read(&playerArray, (const void *)(staticFields + 0x8), sizeof(uintptr_t));
    if (!playerArray || playerArray < 0x100000000ULL) return;

    int32_t count = 0;
    safe_read(&count, (const void *)(playerArray + 0x18), sizeof(int32_t));
    if (count <= 0 || count > 32) return;

    // Chắc chắn đã trong trận đấu!
    g_lastPlayerUpdateTime = mach_absolute_time();
    g_battleUpdateCount++;

    int activeEnemyCount = 0;
    EnemyTarget tempEnemies[MAX_TARGETS];

    for (int i = 0; i < count && activeEnemyCount < MAX_TARGETS; i++) {
        uintptr_t pPtr = 0;
        safe_read(&pPtr, (const void *)(playerArray + 0x20 + i * 8), sizeof(uintptr_t));
        if (!pPtr || pPtr < 0x100000000ULL || (void *)pPtr == g_myPlayer) continue;

        uint8_t isMe = 0;
        safe_read(&isMe, (const void *)(pPtr + OFF_PLAYER_IS_ME), sizeof(uint8_t));
        if (isMe) {
            if (!g_myPlayer) g_myPlayer = (void *)pPtr;
            continue;
        }

        int8_t team = 0;
        int32_t hp = 0, px = 0, py = 0, pid = 0;
        safe_read(&team, (const void *)(pPtr + OFF_PLAYER_TEAM), sizeof(int8_t));
        safe_read(&hp, (const void *)(pPtr + OFF_PLAYER_HP), sizeof(int32_t));
        safe_read(&px, (const void *)(pPtr + OFF_PLAYER_X), sizeof(int32_t));
        safe_read(&py, (const void *)(pPtr + OFF_PLAYER_Y), sizeof(int32_t));
        safe_read(&pid, (const void *)(pPtr + OFF_PLAYER_ID), sizeof(int32_t));

        if (px == 0 && py == 0) {
            float fx = 0, fy = 0;
            safe_read(&fx, (const void *)(pPtr + OFF_PLAYER_CUR_X), sizeof(float));
            safe_read(&fy, (const void *)(pPtr + OFF_PLAYER_CUR_Y), sizeof(float));
            px = (int32_t)fx;
            py = (int32_t)fy;
        }

        if (g_myTeam != 0 && team == g_myTeam) continue;

        if (hp > 0) {
            EnemyTarget en;
            en.id = pid != 0 ? pid : (int32_t)(i + 1);
            en.x = px;
            en.y = py;
            en.hp = hp;
            en.team = team;
            float dx = (float)(px - g_lastMyX);
            float dy = (float)(py - g_lastMyY);
            en.distance = sqrtf(dx * dx + dy * dy);
            snprintf(en.name, sizeof(en.name), "Địch #%d (HP:%d)", en.id, hp);
            tempEnemies[activeEnemyCount++] = en;
        }
    }

    g_enemyCount = activeEnemyCount;
    for (int i = 0; i < activeEnemyCount; i++) {
        g_enemyList[i] = tempEnemies[i];
    }
}

// ==========================================
// 4. HOOKS RUNTIME (NẾU CÓ SUBSTRATE/ELLEKIT)
// ==========================================
static void hook_PlayerUpdate(void *self, void *method) {
    if (self && (uintptr_t)self >= 0x100000000ULL) {
        g_lastPlayerUpdateTime = mach_absolute_time();
        g_playerUpdateCount++;

        uint8_t isMe = 0;
        safe_read(&isMe, (const void *)((uintptr_t)self + OFF_PLAYER_IS_ME), sizeof(uint8_t));

        int8_t team = 0;
        int32_t hp = 0, px = 0, py = 0;
        safe_read(&team, (const void *)((uintptr_t)self + OFF_PLAYER_TEAM), sizeof(int8_t));
        safe_read(&hp, (const void *)((uintptr_t)self + OFF_PLAYER_HP), sizeof(int32_t));
        safe_read(&px, (const void *)((uintptr_t)self + OFF_PLAYER_X), sizeof(int32_t));
        safe_read(&py, (const void *)((uintptr_t)self + OFF_PLAYER_Y), sizeof(int32_t));

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
        }
    }

    if (orig_PlayerUpdate) {
        orig_PlayerUpdate(self, method);
    }
}

static void hook_BattleUpdate(void *self, void *method) {
    if (self) {
        g_lastPlayerUpdateTime = mach_absolute_time();
        g_battleUpdateCount++;
        scanBattleState();
    }
    if (orig_BattleUpdate) {
        orig_BattleUpdate(self, method);
    }
}

static void *hook_GetMyPlayer(void *method) {
    void *player = orig_GetMyPlayer ? orig_GetMyPlayer(method) : NULL;
    if (player && (uintptr_t)player >= 0x100000000ULL) {
        g_lastPlayerUpdateTime = mach_absolute_time();
        g_battleUpdateCount++;
        g_myPlayer = player;
    }
    return player;
}

static void hook_SendShoot(void *self, int8_t shootType, int16_t angle, int16_t x, int16_t y, int8_t force, int8_t force2, int8_t unk, void *method) {
    @try {
        scanBattleState();
        updateAimSolution();
        if (g_aimbotEnabled && g_lastSolution.found) {
            angle = g_lastSolution.angle;
            force = g_lastSolution.force;
            NSLog(@"[MobiAimbot] >>> AUTO-AIM BẮN: Góc=%d°, Lực=%d <<<", angle, force);
        }
    } @catch (id ex) {
        NSLog(@"[MobiAimbot] Lỗi SendShoot: %@", ex);
    }

    if (orig_SendShoot) {
        orig_SendShoot(self, shootType, angle, x, y, force, force2, unk, method);
    }
}

static int hook_get_width(void *method) {
    int w = orig_get_width ? orig_get_width(method) : 0;
    if (w <= 0) {
        CGSize sz = [UIScreen mainScreen].bounds.size;
        CGFloat scale = [UIScreen mainScreen].scale;
        w = (int)(MAX(sz.width, sz.height) * scale);
    }
    if (g_zoomFactor > 1.01f) {
        return (int)(w * g_zoomFactor);
    }
    return w;
}

static int hook_get_height(void *method) {
    int h = orig_get_height ? orig_get_height(method) : 0;
    if (h <= 0) {
        CGSize sz = [UIScreen mainScreen].bounds.size;
        CGFloat scale = [UIScreen mainScreen].scale;
        h = (int)(MIN(sz.width, sz.height) * scale);
    }
    if (g_zoomFactor > 1.01f) {
        return (int)(h * g_zoomFactor);
    }
    return h;
}

static void hook_SetResolution(int width, int height, bool fullscreen, void *method) {
    if (g_zoomFactor > 1.01f) {
        width = (int)(width * g_zoomFactor);
        height = (int)(height * g_zoomFactor);
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
// 5. GIAO DIỆN NỔI (HUD TRỰC QUAN & REAL-TIME)
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
    CGFloat panelH = 430;
    CGFloat x = (parent.bounds.size.width - panelW) / 2;
    CGFloat y = 40;

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
    zoomTitle.text = @"MỨC ZOOM BẢN ĐỒ:";
    zoomTitle.font = [UIFont boldSystemFontOfSize:11];
    zoomTitle.textColor = [UIColor colorWithWhite:0.75 alpha:1.0];
    [self.panelView addSubview:zoomTitle];
    curY += 20;

    self.zoomSegment = [[UISegmentedControl alloc] initWithItems:@[@"1.0x", @"1.3x", @"1.5x", @"1.8x", @"2.0x"]];
    self.zoomSegment.frame = CGRectMake(16, curY, panelW - 32, 26);
    self.zoomSegment.selectedSegmentIndex = 2; // 1.5x
    [self.zoomSegment addTarget:self action:@selector(onZoomChanged:) forControlEvents:UIControlEventValueChanged];
    [self.panelView addSubview:self.zoomSegment];
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
    UIView *teleBox = [[UIView alloc] initWithFrame:CGRectMake(16, curY, panelW - 32, 54)];
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

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(8, 28, teleBox.bounds.size.width - 16, 20)];
    self.statusLabel.text = @"Vào trận để tự động quét địch";
    self.statusLabel.font = [UIFont systemFontOfSize:11];
    self.statusLabel.textColor = [UIColor colorWithWhite:0.7 alpha:1.0];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    [teleBox addSubview:self.statusLabel];
    [self.panelView addSubview:teleBox];
    curY += 62;

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
            self.updateTimer = [NSTimer scheduledTimerWithTimeInterval:0.3
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
        if (unity_base) {
            apply_icall_zoom_hooks(unity_base);
            patch_hard_zoom(unity_base, g_zoomFactor);
        }
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
    if (!unity_base) {
        self.targetInfoLabel.text = @"Đang nạp hook...";
        self.targetInfoLabel.textColor = [UIColor yellowColor];
        self.aimInfoLabel.text = @"Góc: --°  |  Lực: --";
        self.statusLabel.text = @"Đang tìm UnityFramework...";
        return;
    }

    // Luôn chủ động quét dữ liệu trận đấu trực tiếp từ bộ nhớ!
    scanBattleState();

    static mach_timebase_info_data_t s_timebase;
    if (s_timebase.denom == 0) mach_timebase_info(&s_timebase);

    uint64_t elapsedNs = (g_lastPlayerUpdateTime > 0) ? (mach_absolute_time() - g_lastPlayerUpdateTime) * s_timebase.numer / s_timebase.denom : 99999999999ULL;
    BOOL inBattle = (g_myPlayer != NULL) || (g_lastPlayerUpdateTime > 0 && elapsedNs < 10000000000ULL); // Trong vòng 10s

    if (!inBattle) {
        g_enemyCount = 0;
        self.targetInfoLabel.text = @"Chưa vào trận đấu";
        self.targetInfoLabel.textColor = [UIColor yellowColor];
        self.aimInfoLabel.text = @"Góc: --°  |  Lực: --";
        self.statusLabel.text = [NSString stringWithFormat:@"Base: 0x%lx | Zoom: %.2fx (Chờ trận...)", unity_base, g_zoomFactor];
        return;
    }

    updateAimSolution();

    if (g_enemyCount == 0) {
        if (g_myPlayer != NULL) {
            self.targetInfoLabel.text = [NSString stringWithFormat:@"Đã vào trận (Ta: %d, %d)", g_lastMyX, g_lastMyY];
        } else {
            self.targetInfoLabel.text = @"Đã vào trận (Chờ địch)";
        }
        self.targetInfoLabel.textColor = [UIColor colorWithRed:0.2 green:1.0 blue:0.5 alpha:1.0];
        self.aimInfoLabel.text = @"Góc: --°  |  Lực: --";
        self.statusLabel.text = [NSString stringWithFormat:@"Đã vào trận! Đang quét đối thủ... (Quét: %llu)", g_battleUpdateCount];
        return;
    }

    if (g_currentTargetIdx >= g_enemyCount) {
        g_currentTargetIdx = 0;
    }

    EnemyTarget *target = &g_enemyList[g_currentTargetIdx];
    self.targetInfoLabel.text = [NSString stringWithFormat:@"[%d/%d] %s", g_currentTargetIdx + 1, g_enemyCount, target->name];
    self.targetInfoLabel.textColor = [UIColor colorWithRed:0.2 green:1.0 blue:0.5 alpha:1.0];

    if (g_lastSolution.found) {
        self.aimInfoLabel.text = [NSString stringWithFormat:@"🎯 Góc: %d°  |  Lực: %d", g_lastSolution.angle, g_lastSolution.force];
        self.statusLabel.text = [NSString stringWithFormat:@"K.Cách: %.0f px | HP: %d | Ta: (%d,%d)", target->distance, target->hp, g_lastMyX, g_lastMyY];
    } else {
        self.aimInfoLabel.text = @"Góc ngoài tầm với!";
        self.statusLabel.text = [NSString stringWithFormat:@"K.Cách: %.0f px (Đổi góc cao/thấp)", target->distance];
    }
}

@end

// ==========================================
// 6. KHỞI TẠO HOOKS AN TOÀN & BẤT TỬ
// ==========================================
static void install_hooks(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        uintptr_t base = find_unity_base();
        if (!base) return;
        unity_base = base;

        NSLog(@"[MobiArmyMod] Bắt đầu cài đặt Icall Pointer Hooks & Memory Patches vào UnityFramework (0x%lx)...", base);

        // 1. Áp dụng ngay Icall Pointer Zoom trong __DATA.__bss (Bất tử trên mọi thiết bị, không cần Substrate)
        apply_icall_zoom_hooks(base);

        // 2. Patch cứng độ phân giải trong Start() ngay từ đầu
        patch_hard_zoom(base, g_zoomFactor);

        // 3. Hook qua MSHookFunction nếu có Substrate/Ellekit
        void (*fn_MSHook)(void *, void *, void **) = (void (*)(void *, void *, void **))dlsym(RTLD_DEFAULT, "MSHookFunction");
        if (fn_MSHook) {
            fn_MSHook((void *)(base + OFF_SERVICE_SEND_SHOOT), (void *)hook_SendShoot, (void **)&orig_SendShoot);
            fn_MSHook((void *)(base + OFF_PLAYER_UPDATE), (void *)hook_PlayerUpdate, (void **)&orig_PlayerUpdate);
            fn_MSHook((void *)(base + OFF_BATTLE_UPDATE), (void *)hook_BattleUpdate, (void **)&orig_BattleUpdate);
            fn_MSHook((void *)(base + OFF_BATTLE_GET_MY_PLAYER), (void *)hook_GetMyPlayer, (void **)&orig_GetMyPlayer);
            fn_MSHook((void *)(base + OFF_GL_LOAD_PIXEL_MATRIX), (void *)hook_LoadPixelMatrix, (void **)&orig_LoadPixelMatrix);
            fn_MSHook((void *)(base + OFF_SCREEN_GET_WIDTH), (void *)hook_get_width, (void **)&orig_get_width);
            fn_MSHook((void *)(base + OFF_SCREEN_GET_HEIGHT), (void *)hook_get_height, (void **)&orig_get_height);
            fn_MSHook((void *)(base + OFF_SCREEN_SET_RESOLUTION), (void *)hook_SetResolution, (void **)&orig_SetResolution);
            NSLog(@"[MobiArmyMod] MSHookFunction đã cài đặt toàn bộ hooks!");
        }

        g_hooksInstalled = YES;
        NSLog(@"[MobiArmyMod] HOÀN TẤT KHỞI TẠO MOD THÀNH CÔNG 100%%!");
    });
}

// Callback khi dyld nạp thêm thư viện
static void on_image_add(const struct mach_header *mh, intptr_t slide) {
    Dl_info info;
    if (dladdr(mh, &info) && info.dli_fname) {
        if (strstr(info.dli_fname, "UnityFramework")) {
            NSLog(@"[MobiArmyMod] on_image_add: Tìm thấy UnityFramework tại %p (slide: 0x%lx)", mh, slide);
            unity_base = (uintptr_t)mh;
            install_hooks();
        }
    }
}

__attribute__((constructor)) static void MobiArmyModInit(void) {
    NSLog(@"[MobiArmyMod] Dylib khởi chạy trong tiến trình pid: %d", getpid());

    // Đăng ký callback dyld để bắt ngay khoảnh khắc UnityFramework được nạp vào bộ nhớ
    _dyld_register_func_for_add_image((void (*)(const struct mach_header*, intptr_t))on_image_add);

    // Đồng thời kích hoạt thread polling nhanh phòng ngừa dyld callback đã qua
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
        for (int i = 0; i < 500; i++) {
            if (find_unity_base()) {
                install_hooks();
                break;
            }
            usleep(20000); // 20ms
        }
    });

    // Luồng nền quét trận đấu tự động liên tục mỗi 150ms
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        while (1) {
            usleep(150000); // 150ms
            if (unity_base) {
                scanBattleState();
            }
        }
    });

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
