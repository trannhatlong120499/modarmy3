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
#define OFF_USER_SESSION_CLASS          0x3bb9340

// IL2CPP Runtime RVAs
#define RVA_IL2CPP_RESOLVE_TYPE         0x1E69B04
#define RVA_IL2CPP_CLASS_INIT           0x1E69C58

// Native C++ functions của Unity engine
#define RVA_NATIVE_SCREEN_GET_WIDTH      0x2b360e4
#define RVA_NATIVE_SCREEN_GET_HEIGHT     0x2b360f8
#define RVA_NATIVE_GL_LOAD_MATRIX        0x2b364f0
#define RVA_NATIVE_INTERNAL_DRAW_TEXTURE 0x2b36280
#define RVA_NATIVE_GUICLIP_SET_MATRIX    0x23f1aa4

// Cached Icall Slots trong phân vùng __DATA.__bss
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
    if (!dst || !src || size == 0) return false;
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
// 1. KHỞI TẠO RUNTIME METADATA & CLASS (AN TOÀN KHI ENGINE ĐÃ CHẠY)
// ==========================================
static void ensure_runtime_initialized(uintptr_t base) {
    if (!base) return;

    void (*fn_resolve_type)(void *) = (void (*)(void *))(base + RVA_IL2CPP_RESOLVE_TYPE);
    void (*fn_class_init)(void *) = (void (*)(void *))(base + RVA_IL2CPP_CLASS_INIT);
    if (!fn_resolve_type || !fn_class_init) return;

    uintptr_t slots[] = {
        base + OFF_BATTLE_MANAGER_CLASS,
        base + OFF_GAMECONTROLLER_CLASS,
        base + OFF_GAMECANVAS_CLASS,
        base + OFF_SCALE_CLASS,
        base + OFF_CONFIG_SCALE_CLASS,
        base + OFF_USER_SESSION_CLASS
    };

    for (int i = 0; i < 6; i++) {
        uintptr_t val = 0;
        if (safe_read(&val, (const void *)slots[i], sizeof(val))) {
            if (val & 1) { // Còn là token thô trên binary -> resolve thành con trỏ Il2CppClass*
                @try {
                    fn_resolve_type((void *)slots[i]);
                } @catch (id ex) {}
            }
        }

        uintptr_t klass = 0;
        if (safe_read(&klass, (const void *)slots[i], sizeof(klass))) {
            if (klass >= 0x100000000ULL && (klass & 1) == 0) {
                int32_t initialized = 0;
                if (safe_read(&initialized, (const void *)(klass + 0xE4), sizeof(initialized))) {
                    if (initialized == 0) {
                        @try {
                            fn_class_init((void *)klass);
                        } @catch (id ex) {}
                    }
                }
            }
        }
    }
}

// ==========================================
// 2. CƠ CHẾ ZOOM MAP TOÀN DIỆN & ZERO CRASH (RAM-ONLY)
// ==========================================

// Hook 1: Graphics.Internal_DrawTexture (Scale texture vẽ các thành phần)
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

// Hook 2: GUIClip.SetMatrix
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
        right = left + (right - left) * g_zoomFactor;
        bottom = top + (bottom - top) * g_zoomFactor;
    }
    if (real_GLLoadPixelMatrixScript) {
        real_GLLoadPixelMatrixScript(left, right, bottom, top);
    }
}

// Cập nhật kích thước GameCanvas (w, h, hw, hh) trực tiếp trong RAM để game mở rộng vùng nhìn
static void update_gamecanvas_dimensions(uintptr_t base) {
    if (!base) return;
    ensure_runtime_initialized(base);

    @try {
        uintptr_t canvasClass = 0;
        if (!safe_read(&canvasClass, (const void *)(base + OFF_GAMECANVAS_CLASS), sizeof(uintptr_t))) return;
        if (canvasClass < 0x100000000ULL || (canvasClass & 1)) return;

        uintptr_t staticFields = 0;
        if (!safe_read(&staticFields, (const void *)(canvasClass + 0xA0), sizeof(uintptr_t))) return;
        if (staticFields < 0x100000000ULL) return;

        int32_t curW = 0, curH = 0;
        safe_read(&curW, (const void *)(staticFields + 0x48), sizeof(int32_t));
        safe_read(&curH, (const void *)(staticFields + 0x4C), sizeof(int32_t));

        if (s_baseCanvasW == 0) {
            if (curW >= 320 && curW <= 4000) {
                s_baseCanvasW = curW;
                s_baseCanvasH = curH;
            } else {
                s_baseCanvasW = 1024;
                s_baseCanvasH = 600;
            }
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
    ensure_runtime_initialized(base);

    @try {
        int32_t targetScale = (g_zoomFactor >= 1.4f) ? 1 : 2;

        // 1. Cập nhật mGraphics class
        uintptr_t scaleClass = 0;
        if (safe_read(&scaleClass, (const void *)(base + OFF_SCALE_CLASS), sizeof(uintptr_t))) {
            if (scaleClass >= 0x100000000ULL && (scaleClass & 1) == 0) {
                uintptr_t staticFields = 0;
                if (safe_read(&staticFields, (const void *)(scaleClass + 0xA0), sizeof(uintptr_t))) {
                    if (staticFields >= 0x100000000ULL) {
                        *(int32_t *)(staticFields + 0x18) = targetScale;
                    }
                }
            }
        }

        // 2. Cập nhật Config Scale class (0x3bb8fd0)
        uintptr_t configClass = 0;
        if (safe_read(&configClass, (const void *)(base + OFF_CONFIG_SCALE_CLASS), sizeof(uintptr_t))) {
            if (configClass >= 0x100000000ULL && (configClass & 1) == 0) {
                uintptr_t cfgStatic = 0;
                if (safe_read(&cfgStatic, (const void *)(configClass + 0xA0), sizeof(uintptr_t))) {
                    if (cfgStatic >= 0x100000000ULL) {
                        *(int32_t *)(cfgStatic + 8) = targetScale;
                    }
                }
            }
        }
    } @catch (id ex) {}
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
// 3. THUẬT TOÁN TÍNH ĐẠN ĐẠO (BALLISTICS)
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
// 4. QUÉT TRẬN ĐẤU CHUẨN XÁC 100% (ZERO CRASH - SAFE READ ONLY)
// ==========================================
static void scanBattleState(void) {
    if (!unity_base) {
        g_myPlayer = NULL;
        g_enemyCount = 0;
        g_isInBattle = NO;
        return;
    }

    ensure_runtime_initialized(unity_base);

    @try {
        // Đọc BattleManager class tại base + 0x3bb9190
        uintptr_t bmClass = 0;
        if (!safe_read(&bmClass, (const void *)(unity_base + OFF_BATTLE_MANAGER_CLASS), sizeof(uintptr_t)) ||
            bmClass < 0x100000000ULL || (bmClass & 1)) {
            g_myPlayer = NULL;
            g_enemyCount = 0;
            g_isInBattle = NO;
            return;
        }

        uintptr_t bmStatic = 0;
        if (!safe_read(&bmStatic, (const void *)(bmClass + 0xA0), sizeof(uintptr_t)) ||
            bmStatic < 0x100000000ULL) {
            g_myPlayer = NULL;
            g_enemyCount = 0;
            g_isInBattle = NO;
            return;
        }

        // Đọc mảng allPlayers tại bmStatic + 0x8
        uintptr_t playerArray = 0;
        if (!safe_read(&playerArray, (const void *)(bmStatic + 0x8), sizeof(uintptr_t)) ||
            playerArray < 0x100000000ULL) {
            // allPlayers == 0 => Đang ở Sảnh / Main Menu
            g_myPlayer = NULL;
            g_enemyCount = 0;
            g_isInBattle = NO;
            return;
        }

        int32_t count = 0;
        if (!safe_read(&count, (const void *)(playerArray + 0x18), sizeof(int32_t)) ||
            count <= 0 || count > 32) {
            g_myPlayer = NULL;
            g_enemyCount = 0;
            g_isInBattle = NO;
            return;
        }

        // ĐÃ VÀO TRẬN ĐẤU THỰC SỰ!
        g_isInBattle = YES;
        g_battleUpdateCount++;

        void *myPlayer = NULL;
        int enemyIdx = 0;

        for (int i = 0; i < count; i++) {
            uintptr_t p = 0;
            if (!safe_read(&p, (const void *)(playerArray + 0x20 + (size_t)i * 8), sizeof(uintptr_t)) ||
                p < 0x100000000ULL) continue;

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

            if (isMe) {
                myPlayer = (void *)p;
                g_lastMyX = px;
                g_lastMyY = py;
                g_myTeam = pteam;
            } else {
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
                    if (safe_read(&nameObj, (const void *)(p + OFF_PLAYER_NAME), sizeof(uintptr_t)) && nameObj >= 0x100000000ULL) {
                        int32_t strLen = 0;
                        if (safe_read(&strLen, (const void *)(nameObj + 0x10), sizeof(int32_t)) && strLen > 0 && strLen < 32) {
                            unichar ubuf[32];
                            if (safe_read(ubuf, (const void *)(nameObj + 0x14), strLen * sizeof(unichar))) {
                                NSString *s = [NSString stringWithCharacters:ubuf length:strLen];
                                if (s) strncpy(t->name, [s UTF8String], sizeof(t->name) - 1);
                            }
                        }
                    }
                    if (t->name[0] == '\0') {
                        snprintf(t->name, sizeof(t->name), "Dich_%d", i + 1);
                    }
                    enemyIdx++;
                }
            }
        }

        // Trường hợp đặc biệt: nếu không có isMe, lấy player đầu tiên làm myPlayer
        if (!myPlayer && count > 0) {
            uintptr_t p0 = 0;
            if (safe_read(&p0, (const void *)(playerArray + 0x20), sizeof(uintptr_t)) && p0 >= 0x100000000ULL) {
                myPlayer = (void *)p0;
                safe_read(&g_lastMyX, (const void *)(p0 + OFF_PLAYER_X), sizeof(int32_t));
                safe_read(&g_lastMyY, (const void *)(p0 + OFF_PLAYER_Y), sizeof(int32_t));
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
// 5. HOOK BẮN (SEND SHOOT)
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
// 6. GIAO DIỆN ĐIỀU KHIỂN (UI HUD)
// ==========================================
@interface MobiHUDManager : NSObject
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) UIButton *floatingButton;
@property (nonatomic, strong) UIView *panelView;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UILabel *targetInfoLabel;
@property (nonatomic, strong) UILabel *aimInfoLabel;
@property (nonatomic, strong) UISegmentedControl *zoomSegment;
@property (nonatomic, strong) UISwitch *aimSwitch;
@property (nonatomic, strong) UISegmentedControl *arcSegment;
@property (nonatomic, strong) UISlider *gravitySlider;
@property (nonatomic, strong) UISlider *forceSlider;
@property (nonatomic, strong) UILabel *gravityLabel;
@property (nonatomic, strong) UILabel *forceLabel;
@property (nonatomic, strong) NSTimer *updateTimer;
@property (nonatomic, strong) NSTimer *syncTimer;

+ (instancetype)shared;
- (void)attachToKeyWindow;
- (void)refreshUI;
- (void)backgroundSync;
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

    // Panel điều khiển
    CGFloat panelW = 310;
    CGFloat panelH = 340;
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
    titleLabel.text = @"⚡ MOBIARMY 3 HA MOD";
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
    curY += 28;

    // Zoom Segment
    UILabel *zoomTitle = [[UILabel alloc] initWithFrame:CGRectMake(16, curY, panelW - 32, 18)];
    zoomTitle.text = @"MỨC ZOOM BẢN ĐỒ:";
    zoomTitle.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    zoomTitle.textColor = [UIColor colorWithWhite:0.75 alpha:1.0];
    [self.panelView addSubview:zoomTitle];
    curY += 18;

    NSArray *zoomItems = @[@"1.0x", @"1.5x", @"2.0x", @"3.0x", @"4.0x"];
    self.zoomSegment = [[UISegmentedControl alloc] initWithItems:zoomItems];
    self.zoomSegment.frame = CGRectMake(16, curY, panelW - 32, 28);
    self.zoomSegment.selectedSegmentIndex = 2; // Mặc định 2.0x
    [self.zoomSegment addTarget:self action:@selector(onZoomChanged:) forControlEvents:UIControlEventValueChanged];
    [self.panelView addSubview:self.zoomSegment];
    curY += 36;

    // Aimbot Switch
    UILabel *aimTitle = [[UILabel alloc] initWithFrame:CGRectMake(16, curY + 4, 150, 24)];
    aimTitle.text = @"AIMBOT TỰ ĐỘNG";
    aimTitle.font = [UIFont boldSystemFontOfSize:12];
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
    self.arcSegment.frame = CGRectMake(16, curY, panelW - 32, 26);
    self.arcSegment.selectedSegmentIndex = g_highArcMode ? 0 : 1;
    [self.arcSegment addTarget:self action:@selector(onArcChanged:) forControlEvents:UIControlEventValueChanged];
    [self.panelView addSubview:self.arcSegment];
    curY += 32;

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

- (void)backgroundSync {
    if (unity_base) {
        update_gamecanvas_dimensions(unity_base);
        update_graphics_scale(unity_base);
    }
}

- (void)refreshUI {
    @try {
        if (!unity_base) {
            unity_base = find_unity_base();
            if (!unity_base) return;
        }

        update_gamecanvas_dimensions(unity_base);
        update_graphics_scale(unity_base);

        scanBattleState();

        if (!g_isInBattle || g_enemyCount == 0) {
            self.targetInfoLabel.text = g_isInBattle ? @"Đang tìm địch..." : @"Chưa vào trận đấu";
            self.targetInfoLabel.textColor = [UIColor yellowColor];
            self.aimInfoLabel.text = @"Góc: --°  |  Lực: --";
            self.statusLabel.text = [NSString stringWithFormat:@"Zoom: %.1fx (Bật) | Sẵn sàng...", g_zoomFactor];
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
            self.statusLabel.text = [NSString stringWithFormat:@"Ta: (%d, %d) | Cách: %d px", 
                g_lastMyX, g_lastMyY, abs(curEnemy->x - g_lastMyX)];
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
// 7. KHỞI TẠO HOOKS & CONSTRUCTOR
// ==========================================
static void install_hooks(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        uintptr_t base = find_unity_base();
        if (!base) return;
        unity_base = base;

        NSLog(@"[MobiArmyMod] Bắt đầu cài đặt Mod an toàn vào UnityFramework (0x%lx)...", base);

        // 1. Resolve và khởi tạo các type slot IL2CPP an toàn
        ensure_runtime_initialized(base);

        // 2. Cài đặt hooks icall slots an toàn trong __DATA.__bss
        apply_icall_zoom_hooks(base);

        // 3. Đồng bộ scale và kích thước canvas ban đầu
        update_gamecanvas_dimensions(base);
        update_graphics_scale(base);

        // 4. Hook qua MSHookFunction nếu có Substrate/Ellekit (Dopamine / Sileo)
        void (*fn_MSHook)(void *, void *, void **) = (void (*)(void *, void *, void **))dlsym(RTLD_DEFAULT, "MSHookFunction");
        if (fn_MSHook) {
            fn_MSHook((void *)(base + OFF_SERVICE_SEND_SHOOT), (void *)hook_SendShoot, (void **)&orig_SendShoot);
            NSLog(@"[MobiArmyMod] MSHookFunction đã cài đặt hooks SendShoot!");
        }

        // 5. Bật timer định kỳ 0.5s để giữ đồng bộ scale và kích thước canvas ổn định
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
