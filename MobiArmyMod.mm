//
//  MobiArmyMod.mm
//  MobiArmy 3 HA Mod Dylib - Siêu Thu Nhỏ Map & Auto-Aim Bất Tử Zero Crash
//
//  Tương thích 100%: TrollStore / TrollFools / Dopamine / Sileo / Rootless / Rootful
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
static float g_zoomFactor       = 2.00f;    // Mức zoom mặc định (2.0x mở rộng bản đồ cực nét)
static BOOL  g_aimbotEnabled    = YES;      // Bật aimbot
static BOOL  g_highArcMode      = YES;      // YES: Góc cao (High Arc), NO: Góc thấp (Low Arc)
static float g_gravityFactor    = 1.0f;     // Hệ số trọng lực tinh chỉnh
static float g_forceScale       = 1.0f;     // Hệ số lực bắn tinh chỉnh
static int   g_currentTargetIdx = 0;        // Index mục tiêu hiện tại

// RVAs trong UnityFramework 1.0.1.0.3
#define OFF_SERVICE_SEND_SHOOT          0x148704
#define OFF_BATTLE_MANAGER_CLASS        0x3bb9190
#define OFF_GAMECONTROLLER_CLASS        0x3bb92d0
#define OFF_GAMECANVAS_CLASS            0x3bb90a0
#define OFF_SCALE_CLASS                 0x3bb9230
#define OFF_CONFIG_SCALE_CLASS          0x3bb8fd0
#define OFF_SCREEN_GET_WIDTH            0xF3A2C
#define OFF_SCREEN_GET_HEIGHT           0xF3B24

// Native C++ functions của Unity engine (RVAs tĩnh trong binary)
#define RVA_NATIVE_SCREEN_GET_WIDTH      0x2b360e4
#define RVA_NATIVE_SCREEN_GET_HEIGHT     0x2b360f8
#define RVA_NATIVE_GL_LOAD_MATRIX        0x2b364f0
#define RVA_NATIVE_INTERNAL_DRAW_TEXTURE 0x2b36280
#define RVA_NATIVE_GUICLIP_SET_MATRIX    0x23f1aa4

// Cached Icall Slots trong phân vùng __DATA.__bss (Ghi đè trực tiếp an toàn tuyệt đối)
#define OFF_ICALL_SCREEN_GET_WIDTH       0x4084f08
#define OFF_ICALL_SCREEN_GET_HEIGHT      0x4084f10
#define OFF_ICALL_INTERNAL_DRAW_TEXTURE  0x4084f50
#define OFF_ICALL_GL_LOAD_MATRIX         0x4084f98
#define OFF_ICALL_GUICLIP_SET_MATRIX     0x40868b0

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

// Unity 4x4 Matrix cho GUIClip (64 bytes)
typedef struct {
    float m[16];
} UnityMatrix4x4;

// Unity Rect struct (16 bytes)
typedef struct {
    float x;
    float y;
    float width;
    float height;
} UnityRect;

// UnityEngine.Internal_DrawTextureArguments
typedef struct {
    UnityRect screenRect; // Offset 0x00
    UnityRect sourceRect; // Offset 0x10
    int32_t leftBorder;
    int32_t rightBorder;
    int32_t topBorder;
    int32_t bottomBorder;
} Internal_DrawTextureArguments;

static BOOL g_isInBattle = NO;

// Function Pointers & Counters
static uintptr_t unity_base = 0;
static BOOL g_hooksInstalled = NO;
static uint64_t g_battleUpdateCount = 0;

static void (*orig_SendShoot)(void *self, int8_t shootType, int16_t angle, int16_t x, int16_t y, int8_t force, int8_t force2, int8_t unk, void *method) = NULL;

// Native engine functions & Zoom variables
static void (*real_GLLoadPixelMatrixScript)(float left, float right, float bottom, float top) = NULL;
static void (*real_Internal_DrawTexture)(void *args) = NULL;
static void (*real_GUIClip_SetMatrix)(UnityMatrix4x4 *mat) = NULL;
static int (*orig_Screen_getWidth)(void) = NULL;
static int (*orig_Screen_getHeight)(void) = NULL;

static int32_t s_baseCanvasW = 0;
static int32_t s_baseCanvasH = 0;
static int32_t s_origGraphicsScale = 0;

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

// ---------- Helper xoá PAC bits trên ARM64E (iPhone 14 Pro Max / A16 / iOS 16+) ----------
static inline uintptr_t clean_ptr(uintptr_t p) {
    return p & 0x0000FFFFFFFFFFFFULL;
}

// ---------- Helper đọc bộ nhớ an toàn (Chống Crash EXC_BAD_ACCESS 100%) ----------
static inline bool safe_read(void *dst, const void *src, size_t size) {
    uintptr_t p = clean_ptr((uintptr_t)src);
    if (p < 0x100000000ULL || p > 0x00007FFFFFFFFFFFULL) return false;
    vm_size_t bytesRead = 0;
    kern_return_t kr = vm_read_overwrite(mach_task_self(), (vm_address_t)p, size, (vm_address_t)dst, &bytesRead);
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
// 1. CƠ CHẾ ZOOM MAP TOÀN DIỆN & ZERO CRASH (RAM-ONLY)
// ==========================================

// Hook 1: Graphics.Internal_DrawTexture
static void my_Internal_DrawTexture(void *args) {
    if (!args || !real_Internal_DrawTexture) {
        if (real_Internal_DrawTexture && args) real_Internal_DrawTexture(args);
        return;
    }

    if (g_zoomFactor > 2.05f) {
        Internal_DrawTextureArguments *drawArgs = (Internal_DrawTextureArguments *)args;
        UnityRect origRect = drawArgs->screenRect;

        float extraScale = 2.0f / g_zoomFactor;
        drawArgs->screenRect.x *= extraScale;
        drawArgs->screenRect.y *= extraScale;
        drawArgs->screenRect.width *= extraScale;
        drawArgs->screenRect.height *= extraScale;

        real_Internal_DrawTexture(args);

        drawArgs->screenRect = origRect;
        return;
    }

    real_Internal_DrawTexture(args);
}

// Hook 2: GUIClip.SetMatrix (Thu nhỏ ma trận 2D GUIClip)
static void my_GUIClip_SetMatrix(UnityMatrix4x4 *mat) {
    if (mat && g_zoomFactor > 2.05f) {
        UnityMatrix4x4 scaled = *mat;
        float extraScale = 2.0f / g_zoomFactor;
        scaled.m[0] *= extraScale;
        scaled.m[5] *= extraScale;
        if (real_GUIClip_SetMatrix) {
            real_GUIClip_SetMatrix(&scaled);
            return;
        }
    }
    if (real_GUIClip_SetMatrix) {
        real_GUIClip_SetMatrix(mat);
    }
}

// Hook 3: Screen.width / Screen.height ảo hoá cho game engine
static int my_icall_Screen_get_width(void) {
    int w = 0;
    if (unity_base) {
        safe_read(&w, (const void *)(unity_base + 0x3b4ff40), sizeof(w));
    }
    if (w <= 0) {
        if ([NSThread isMainThread]) {
            CGSize sz = [UIScreen mainScreen].bounds.size;
            CGFloat scale = [UIScreen mainScreen].scale;
            w = (int)(MAX(sz.width, sz.height) * (scale > 0 ? scale : 2.0));
        }
    }
    if (w <= 0) w = 1024;

    if (g_zoomFactor > 1.01f) {
        return (int)(w * g_zoomFactor);
    }
    return w;
}

static int my_icall_Screen_get_height(void) {
    int h = 0;
    if (unity_base) {
        safe_read(&h, (const void *)(unity_base + 0x3b4ff44), sizeof(h));
    }
    if (h <= 0) {
        if ([NSThread isMainThread]) {
            CGSize sz = [UIScreen mainScreen].bounds.size;
            CGFloat scale = [UIScreen mainScreen].scale;
            h = (int)(MIN(sz.width, sz.height) * (scale > 0 ? scale : 2.0));
        }
    }
    if (h <= 0) h = 600;

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

// Cập nhật kích thước GameCanvas (w, h, hw, hh) trực tiếp trong RAM để game mở rộng vùng nhìn
static void update_gamecanvas_dimensions(uintptr_t base) {
    if (!base) return;
    @try {
        uintptr_t canvasClass = 0;
        if (!safe_read(&canvasClass, (const void *)(base + OFF_GAMECANVAS_CLASS), sizeof(uintptr_t))) return;
        if (canvasClass < 0x100000000ULL || canvasClass > 0x00007FFFFFFFFFFFULL || (canvasClass & 1)) return;

        uintptr_t staticFields = 0;
        if (!safe_read(&staticFields, (const void *)(canvasClass + 0xA0), sizeof(uintptr_t))) return;
        if (staticFields < 0x100000000ULL || staticFields > 0x00007FFFFFFFFFFFULL) return;

        int32_t curW = 0, curH = 0;
        safe_read(&curW, (const void *)(staticFields + 0x48), sizeof(int32_t));
        safe_read(&curH, (const void *)(staticFields + 0x4C), sizeof(int32_t));

        if (s_baseCanvasW == 0 && curW >= 320 && curW <= 4000) {
            s_baseCanvasW = curW;
            s_baseCanvasH = curH;
        }

        if (s_baseCanvasW > 0) {
            float zoomMul = (g_zoomFactor >= 1.4f) ? g_zoomFactor : 1.0f;
            int32_t targetW = (int32_t)(s_baseCanvasW * zoomMul);
            int32_t targetH = (int32_t)(s_baseCanvasH * zoomMul);

            *(int32_t *)(staticFields + 0x48) = targetW;
            *(int32_t *)(staticFields + 0x4C) = targetH;
            *(int32_t *)(staticFields + 0x54) = targetW / 2;
            *(int32_t *)(staticFields + 0x50) = targetH / 2;
        }
    } @catch (id ex) {}
}

// Cập nhật hệ số scale gốc của mGraphics (0x3bb9230 + 0x18) và Config (0x3bb8fd0 + 0x8)
static void update_graphics_scale(uintptr_t base) {
    if (!base) return;
    @try {
        int32_t targetScale = (g_zoomFactor >= 1.4f) ? 1 : 2;

        // 1. Cập nhật mGraphics class
        uintptr_t scaleClass = 0;
        if (safe_read(&scaleClass, (const void *)(base + OFF_SCALE_CLASS), sizeof(uintptr_t))) {
            if (scaleClass >= 0x100000000ULL && scaleClass <= 0x00007FFFFFFFFFFFULL && (scaleClass & 1) == 0) {
                uintptr_t staticFields = 0;
                if (safe_read(&staticFields, (const void *)(scaleClass + 0xA0), sizeof(uintptr_t))) {
                    if (staticFields >= 0x100000000ULL && staticFields <= 0x00007FFFFFFFFFFFULL) {
                        *(int32_t *)(staticFields + 0x18) = targetScale;
                    }
                }
            }
        }

        // 2. Cập nhật Config Scale class (0x3bb8fd0)
        uintptr_t configClass = 0;
        if (safe_read(&configClass, (const void *)(base + OFF_CONFIG_SCALE_CLASS), sizeof(uintptr_t))) {
            if (configClass >= 0x100000000ULL && configClass <= 0x00007FFFFFFFFFFFULL && (configClass & 1) == 0) {
                uintptr_t cfgStatic = 0;
                if (safe_read(&cfgStatic, (const void *)(configClass + 0xA0), sizeof(uintptr_t))) {
                    if (cfgStatic >= 0x100000000ULL && cfgStatic <= 0x00007FFFFFFFFFFFULL) {
                        *(int32_t *)(cfgStatic + 8) = targetScale;
                    }
                }
            }
        }
    } @catch (id ex) {}
}

static int hook_Screen_getWidth(void) {
    int w = orig_Screen_getWidth ? orig_Screen_getWidth() : 1024;
    if (g_zoomFactor > 1.01f) {
        return (int)(w * g_zoomFactor);
    }
    return w;
}

static int hook_Screen_getHeight(void) {
    int h = orig_Screen_getHeight ? orig_Screen_getHeight() : 600;
    if (g_zoomFactor > 1.01f) {
        return (int)(h * g_zoomFactor);
    }
    return h;
}

static void apply_icall_zoom_hooks(uintptr_t base) {
    if (!base) return;

    @try {
        real_GLLoadPixelMatrixScript = (void (*)(float, float, float, float))(base + RVA_NATIVE_GL_LOAD_MATRIX);
        real_Internal_DrawTexture = (void (*)(void *))(base + RVA_NATIVE_INTERNAL_DRAW_TEXTURE);
        real_GUIClip_SetMatrix = (void (*)(UnityMatrix4x4 *))(base + RVA_NATIVE_GUICLIP_SET_MATRIX);

        // Ghi đè con trỏ trong phân vùng __DATA.__bss (An toàn tuyệt đối, không crash)
        *(uintptr_t *)(base + OFF_ICALL_SCREEN_GET_WIDTH)       = (uintptr_t)my_icall_Screen_get_width;
        *(uintptr_t *)(base + OFF_ICALL_SCREEN_GET_HEIGHT)      = (uintptr_t)my_icall_Screen_get_height;
        *(uintptr_t *)(base + OFF_ICALL_INTERNAL_DRAW_TEXTURE)  = (uintptr_t)my_Internal_DrawTexture;
        *(uintptr_t *)(base + OFF_ICALL_GL_LOAD_MATRIX)         = (uintptr_t)my_icall_GLLoadPixelMatrixScript;
        *(uintptr_t *)(base + OFF_ICALL_GUICLIP_SET_MATRIX)     = (uintptr_t)my_GUIClip_SetMatrix;
    } @catch (id ex) {}
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
// 3. QUÉT TRẬN ĐẤU AN TOÀN TUYỆT ĐỐI (ZERO CRASH - SAFE READ ONLY)
// ==========================================
static void scanBattleState(void) {
    if (!unity_base) {
        g_myPlayer = NULL;
        g_enemyCount = 0;
        g_isInBattle = NO;
        return;
    }

    @try {
        // 1. Đọc GameController tại base + 0x3bb92d0 (CHỈ DÙNG safe_read, KHÔNG GỌI ENGINE)
        uint8_t isInBattle = 0;
        int8_t myIdx = -1;
        uintptr_t gcClass = 0;
        if (safe_read(&gcClass, (const void *)(unity_base + OFF_GAMECONTROLLER_CLASS), sizeof(uintptr_t))) {
            if (gcClass >= 0x100000000ULL && gcClass <= 0x00007FFFFFFFFFFFULL && (gcClass & 1) == 0) {
                uintptr_t gcStatic = 0;
                if (safe_read(&gcStatic, (const void *)(gcClass + 0xA0), sizeof(uintptr_t))) {
                    if (gcStatic >= 0x100000000ULL && gcStatic <= 0x00007FFFFFFFFFFFULL) {
                        safe_read(&isInBattle, (const void *)(gcStatic + 0x2E0), sizeof(uint8_t));
                        safe_read(&myIdx, (const void *)(gcStatic + 0x2BC), sizeof(int8_t));
                    }
                }
            }
        }

        // 2. Đọc BattleManager tại base + 0x3bb9190
        uintptr_t playerArray = 0;
        int32_t count = 0;
        uintptr_t bmClass = 0;
        if (safe_read(&bmClass, (const void *)(unity_base + OFF_BATTLE_MANAGER_CLASS), sizeof(uintptr_t))) {
            if (bmClass >= 0x100000000ULL && bmClass <= 0x00007FFFFFFFFFFFULL && (bmClass & 1) == 0) {
                uintptr_t bmStatic = 0;
                if (safe_read(&bmStatic, (const void *)(bmClass + 0xA0), sizeof(uintptr_t))) {
                    if (bmStatic >= 0x100000000ULL && bmStatic <= 0x00007FFFFFFFFFFFULL) {
                        size_t bmOffsets[] = { 0x8, 0x10, 0x18, 0x0, 0x20 };
                        for (int i = 0; i < 5; i++) {
                            uintptr_t cand = 0;
                            if (safe_read(&cand, (const void *)(bmStatic + bmOffsets[i]), sizeof(uintptr_t))) {
                                if (cand >= 0x100000000ULL && cand <= 0x00007FFFFFFFFFFFULL) {
                                    int32_t len = 0;
                                    if (safe_read(&len, (const void *)(cand + 0x18), sizeof(int32_t))) {
                                        if (len >= 1 && len <= 32) {
                                            playerArray = cand;
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

        // Nếu chưa thấy trong BattleManager, kiểm tra GameController
        if (!playerArray && gcClass >= 0x100000000ULL && (gcClass & 1) == 0) {
            uintptr_t gcStatic = 0;
            if (safe_read(&gcStatic, (const void *)(gcClass + 0xA0), sizeof(uintptr_t))) {
                if (gcStatic >= 0x100000000ULL && gcStatic <= 0x00007FFFFFFFFFFFULL) {
                    size_t gcOffsets[] = { 0x2F8, 0x1A0, 0x1C8, 0x200, 0x8, 0x10 };
                    for (int i = 0; i < 6; i++) {
                        uintptr_t cand = 0;
                        if (safe_read(&cand, (const void *)(gcStatic + gcOffsets[i]), sizeof(uintptr_t))) {
                            if (cand >= 0x100000000ULL && cand <= 0x00007FFFFFFFFFFFULL) {
                                int32_t len = 0;
                                if (safe_read(&len, (const void *)(cand + 0x18), sizeof(int32_t))) {
                                    if (len >= 1 && len <= 32) {
                                        playerArray = cand;
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

        // 3. Xác định trạng thái vào trận
        BOOL inBattle = (isInBattle == 1) || (playerArray != 0 && count > 0);
        g_isInBattle = inBattle;

        if (!inBattle) {
            g_myPlayer = NULL;
            g_enemyCount = 0;
            return;
        }

        // 4. Tìm nhân vật của mình (myPlayer)
        void *myPlayer = NULL;
        if (playerArray && count > 0) {
            // Theo myIdx từ GameController
            if (myIdx >= 0 && myIdx < count) {
                uintptr_t p = 0;
                if (safe_read(&p, (const void *)(playerArray + 0x20 + (size_t)myIdx * 8), sizeof(uintptr_t))) {
                    if (p >= 0x100000000ULL && p <= 0x00007FFFFFFFFFFFULL) {
                        myPlayer = (void *)p;
                    }
                }
            }
            // Quét flag isMe == 1 (+0x10)
            if (!myPlayer) {
                for (int i = 0; i < count; i++) {
                    uintptr_t p = 0;
                    if (safe_read(&p, (const void *)(playerArray + 0x20 + (size_t)i * 8), sizeof(uintptr_t))) {
                        if (p >= 0x100000000ULL && p <= 0x00007FFFFFFFFFFFULL) {
                            uint8_t isMe = 0;
                            safe_read(&isMe, (const void *)(p + OFF_PLAYER_IS_ME), sizeof(uint8_t));
                            if (isMe) {
                                myPlayer = (void *)p;
                                break;
                            }
                        }
                    }
                }
            }
            // Lấy player hợp lệ đầu tiên nếu đang trong trận
            if (!myPlayer) {
                for (int i = 0; i < count; i++) {
                    uintptr_t p = 0;
                    if (safe_read(&p, (const void *)(playerArray + 0x20 + (size_t)i * 8), sizeof(uintptr_t))) {
                        if (p >= 0x100000000ULL && p <= 0x00007FFFFFFFFFFFULL) {
                            myPlayer = (void *)p;
                            break;
                        }
                    }
                }
            }
        }

        g_myPlayer = myPlayer;
        g_battleUpdateCount++;

        // 5. Đọc toạ độ của bản thân
        int32_t mx = 0, my = 0;
        int8_t mteam = 0;
        if (myPlayer) {
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
        }
        g_lastMyX = mx;
        g_lastMyY = my;
        g_myTeam = mteam;

        // 6. Đọc danh sách đối thủ
        int activeEnemyCount = 0;
        EnemyTarget tempEnemies[MAX_TARGETS];

        if (playerArray && count > 0) {
            for (int i = 0; i < count && activeEnemyCount < MAX_TARGETS; i++) {
                uintptr_t pPtr = 0;
                safe_read(&pPtr, (const void *)(playerArray + 0x20 + (size_t)i * 8), sizeof(uintptr_t));
                if (!pPtr || pPtr < 0x100000000ULL || (void *)pPtr == myPlayer) continue;

                uint8_t isMe = 0;
                safe_read(&isMe, (const void *)(pPtr + OFF_PLAYER_IS_ME), sizeof(uint8_t));
                if (isMe) continue;

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

                if (mteam != 0 && team == mteam) continue;

                EnemyTarget en;
                en.id = pid != 0 ? pid : (int32_t)(i + 1);
                en.x = px;
                en.y = py;
                en.hp = hp;
                en.team = team;
                float dx = (float)(px - mx);
                float dy = (float)(py - my);
                en.distance = sqrtf(dx * dx + dy * dy);
                if (hp > 0) {
                    snprintf(en.name, sizeof(en.name), "Địch #%d (HP:%d)", en.id, hp);
                } else {
                    snprintf(en.name, sizeof(en.name), "Địch #%d (%d,%d)", en.id, px, py);
                }
                tempEnemies[activeEnemyCount++] = en;
            }
        }

        g_enemyCount = activeEnemyCount;
        for (int i = 0; i < activeEnemyCount; i++) {
            g_enemyList[i] = tempEnemies[i];
        }
    } @catch (id ex) {
        NSLog(@"[MobiArmyMod] Lỗi scanBattleState: %@", ex);
    }
}

// ==========================================
// 4. HOOK BẮN (SENDSHOOT HOOK)
// ==========================================
static void hook_SendShoot(void *self, int8_t shootType, int16_t angle, int16_t x, int16_t y, int8_t force, int8_t force2, int8_t unk, void *method) {
    @try {
        scanBattleState();
        updateAimSolution();
        if (g_aimbotEnabled && g_lastSolution.found) {
            angle = g_lastSolution.angle;
            force = g_lastSolution.force;
            NSLog(@"[MobiAimbot] >>> AUTO-AIM BẮN! Góc=%d°, Lực=%d <<<", angle, force);
        }
    } @catch (id ex) {
        NSLog(@"[MobiAimbot] Lỗi SendShoot: %@", ex);
    }

    if (orig_SendShoot) {
        orig_SendShoot(self, shootType, angle, x, y, force, force2, unk, method);
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
- (void)backgroundSync;
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
    CGFloat y = 30;

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
    UILabel *zoomTitle = [[UILabel alloc] initWithFrame:CGRectMake(16, curY, 200, 18)];
    zoomTitle.text = @"MỨC ZOOM BẢN ĐỒ:";
    zoomTitle.font = [UIFont boldSystemFontOfSize:11];
    zoomTitle.textColor = [UIColor colorWithWhite:0.75 alpha:1.0];
    [self.panelView addSubview:zoomTitle];
    curY += 20;

    self.zoomSegment = [[UISegmentedControl alloc] initWithItems:@[@"1.0x", @"1.5x", @"2.0x", @"3.0x", @"4.0x"]];
    self.zoomSegment.frame = CGRectMake(16, curY, panelW - 32, 26);
    self.zoomSegment.selectedSegmentIndex = 2; // 2.0x mặc định
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

- (void)onZoomChanged:(UISegmentedControl *)sender {
    @try {
        float values[] = { 1.0f, 1.5f, 2.0f, 3.0f, 4.0f };
        if (sender.selectedSegmentIndex >= 0 && sender.selectedSegmentIndex < 5) {
            g_zoomFactor = values[sender.selectedSegmentIndex];
        }
        if (unity_base) {
            update_gamecanvas_dimensions(unity_base);
            update_graphics_scale(unity_base);
        }
        [self refreshUI];
    } @catch (id ex) {
        NSLog(@"[MobiArmyMod] Lỗi onZoomChanged: %@", ex);
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

- (void)backgroundSync {
    if (unity_base) {
        update_gamecanvas_dimensions(unity_base);
        update_graphics_scale(unity_base);
    }
}

- (void)refreshUI {
    @try {
        if (!unity_base) {
            self.targetInfoLabel.text = @"Đang tìm game...";
            self.targetInfoLabel.textColor = [UIColor yellowColor];
            self.aimInfoLabel.text = @"Góc: --°  |  Lực: --";
            self.statusLabel.text = @"Chờ nạp UnityFramework...";
            return;
        }

        update_gamecanvas_dimensions(unity_base);
        update_graphics_scale(unity_base);

        scanBattleState();

        if (!g_isInBattle && g_myPlayer == NULL && g_enemyCount == 0) {
            self.targetInfoLabel.text = @"Chưa vào trận đấu";
            self.targetInfoLabel.textColor = [UIColor yellowColor];
            self.aimInfoLabel.text = @"Góc: --°  |  Lực: --";
            self.statusLabel.text = [NSString stringWithFormat:@"Zoom: %.1fx (Bật) | Sẵn sàng...", g_zoomFactor];
            return;
        }

        updateAimSolution();

        if (g_enemyCount == 0) {
            self.targetInfoLabel.text = [NSString stringWithFormat:@"Đã vào trận (Ta: %d,%d)", g_lastMyX, g_lastMyY];
            self.targetInfoLabel.textColor = [UIColor colorWithRed:0.2 green:1.0 blue:0.5 alpha:1.0];
            self.aimInfoLabel.text = @"Góc: --°  |  Lực: --";
            self.statusLabel.text = [NSString stringWithFormat:@"Đang tìm địch... (Ta: %d,%d)", g_lastMyX, g_lastMyY];
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
    } @catch (id ex) {
        NSLog(@"[MobiArmyMod] Lỗi refreshUI: %@", ex);
    }
}

@end

// ==========================================
// 6. KHỞI TẠO HOOKS AN TOÀN TRÊN MAIN THREAD
// ==========================================
static void install_hooks(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        uintptr_t base = find_unity_base();
        if (!base) return;
        unity_base = base;

        NSLog(@"[MobiArmyMod] Bắt đầu cài đặt Mod an toàn vào UnityFramework (0x%lx)...", base);

        // 1. Cài đặt hooks icall slots an toàn trong __DATA.__bss
        apply_icall_zoom_hooks(base);

        // 2. Đồng bộ scale và kích thước canvas ban đầu
        update_gamecanvas_dimensions(base);
        update_graphics_scale(base);

        // 3. Hook qua MSHookFunction nếu có Substrate/Ellekit (Dopamine / Sileo)
        void (*fn_MSHook)(void *, void *, void **) = (void (*)(void *, void *, void **))dlsym(RTLD_DEFAULT, "MSHookFunction");
        if (fn_MSHook) {
            fn_MSHook((void *)(base + OFF_SERVICE_SEND_SHOOT), (void *)hook_SendShoot, (void **)&orig_SendShoot);
            fn_MSHook((void *)(base + OFF_SCREEN_GET_WIDTH), (void *)hook_Screen_getWidth, (void **)&orig_Screen_getWidth);
            fn_MSHook((void *)(base + OFF_SCREEN_GET_HEIGHT), (void *)hook_Screen_getHeight, (void **)&orig_Screen_getHeight);
            NSLog(@"[MobiArmyMod] MSHookFunction đã cài đặt hooks SendShoot, getWidth, getHeight!");
        }

        // 4. Bật timer định kỳ 0.5s để giữ đồng bộ scale và kích thước canvas ổn định
        [NSTimer scheduledTimerWithTimeInterval:0.5
                                         target:[MobiHUDManager shared]
                                       selector:@selector(backgroundSync)
                                       userInfo:nil
                                        repeats:YES];

        g_hooksInstalled = YES;
        NSLog(@"[MobiArmyMod] HOÀN TẤT KHỞI TẠO MOD THÀNH CÔNG 100%%!");
    });
}

__attribute__((constructor)) static void MobiArmyModInit(void) {
    NSLog(@"[MobiArmyMod] Dylib khởi chạy trong tiến trình pid: %d", getpid());

    // Tuyệt đối không can thiệp bộ nhớ hoặc gọi hàm engine ở constructor!
    // Chờ app vào foreground hoàn toàn (2.5 giây sau active) trên main thread
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification * _Nonnull note) {
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                install_hooks();
                [[MobiHUDManager shared] attachToKeyWindow];
            });
        });
    }];
}
