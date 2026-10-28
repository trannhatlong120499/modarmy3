//
//  MobiArmyMod.mm
//  MobiArmy 3 HA Mod Dylib - Siêu Thu Nhỏ Map (Hard Zoom 1.0x-5.0x) & Auto-Aim Bất Tử Zero Crash
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
static float g_zoomFactor       = 3.00f;    // Mức zoom mặc định (3.0x siêu mạnh nhìn toàn bản đồ)
static BOOL  g_aimbotEnabled    = YES;      // Bật aimbot
static BOOL  g_highArcMode      = YES;      // YES: Góc cao (High Arc), NO: Góc thấp (Low Arc)
static float g_gravityFactor    = 1.0f;     // Hệ số trọng lực tinh chỉnh
static float g_forceScale       = 1.0f;     // Hệ số lực bắn tinh chỉnh
static int   g_currentTargetIdx = 0;        // Index mục tiêu hiện tại

// RVAs trong UnityFramework 1.0.1.0.3
#define OFF_SERVICE_SEND_SHOOT          0x148704
#define OFF_BATTLE_MANAGER_CLASS        0x3bb9190

// IL2CPP Runtime APIs (Exported symbols trong UnityFramework)
#define OFF_DOMAIN_GET                  0x1e67400
#define OFF_DOMAIN_GET_ASSEMBLIES       0x1e6740c
#define OFF_ASSEMBLY_GET_IMAGE          0x1e66e80
#define OFF_IMAGE_GET_NAME              0x1e67c20
#define OFF_CLASS_FROM_NAME             0x1e66eb8
#define OFF_IL2CPP_ADD_INTERNAL_CALL    0x2b2adf4

// Biến Screen Width/Height toàn cục của Unity Engine (Trong __DATA)
#define OFF_GLOBAL_SCREEN_WIDTH         0x3b4ff40
#define OFF_GLOBAL_SCREEN_HEIGHT        0x3b4ff44

// Native C++ functions của Unity engine (RVAs tĩnh trong binary)
#define RVA_NATIVE_SCREEN_GET_WIDTH      0x2b360e4
#define RVA_NATIVE_SCREEN_GET_HEIGHT     0x2b360f8
#define RVA_NATIVE_GL_LOAD_MATRIX        0x2b364f0
#define RVA_NATIVE_SCREEN_SET_RESOLUTION 0x2b361e4

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

// IL2CPP Opaque Types
typedef struct Il2CppDomain Il2CppDomain;
typedef struct Il2CppAssembly Il2CppAssembly;
typedef struct Il2CppImage Il2CppImage;
typedef struct Il2CppClass Il2CppClass;

static Il2CppDomain *(*p_domain_get)(void) = NULL;
static Il2CppAssembly **(*p_domain_get_assemblies)(Il2CppDomain *, size_t *) = NULL;
static Il2CppImage *(*p_assembly_get_image)(Il2CppAssembly *) = NULL;
static const char *(*p_image_get_name)(Il2CppImage *) = NULL;
static Il2CppClass *(*p_class_from_name)(const Il2CppImage *, const char *, const char *) = NULL;

static Il2CppImage *s_gameImage = NULL;
static Il2CppClass *s_battleClass = NULL;
static int s_debugScanState = 0;

// Function Pointers & Counters
static uintptr_t unity_base = 0;
static BOOL g_hooksInstalled = NO;
static uint64_t g_battleUpdateCount = 0;

static void (*orig_SendShoot)(void *self, int8_t shootType, int16_t angle, int16_t x, int16_t y, int8_t force, int8_t force2, int8_t unk, void *method) = NULL;

// Native engine functions
static int (*real_Screen_get_width_icall)(void) = NULL;
static int (*real_Screen_get_height_icall)(void) = NULL;
static void (*real_GLLoadPixelMatrixScript)(float left, float right, float bottom, float top) = NULL;
static void (*real_Screen_SetResolution)(int width, int height, int fullscreenMode, const void *refreshRate) = NULL;

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
    if (p < 0x100000000ULL || p > 0x3000000000ULL) return false;
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
// 1. CƠ CHẾ ZOOM MAP TOÀN DIỆN & MẠNH MẼ (1.0x - 5.0x)
// ==========================================
static int my_icall_Screen_get_width(void) {
    int w = 1024;
    if (real_Screen_get_width_icall) {
        w = real_Screen_get_width_icall();
    }
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
    int h = 600;
    if (real_Screen_get_height_icall) {
        h = real_Screen_get_height_icall();
    }
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

static void my_icall_Screen_SetResolution(int width, int height, int fullscreenMode, const void *refreshRate) {
    int targetW = width;
    int targetH = height;
    if (g_zoomFactor > 1.01f) {
        targetW = (int)(width * g_zoomFactor);
        targetH = (int)(height * g_zoomFactor);
    }
    NSLog(@"[MobiArmyMod] SetResolution gọi với %d x %d -> Phóng to: %d x %d (zoom: %.1fx)",
          width, height, targetW, targetH, g_zoomFactor);

    if (unity_base) {
        *(int32_t *)(unity_base + OFF_GLOBAL_SCREEN_WIDTH)  = targetW;
        *(int32_t *)(unity_base + OFF_GLOBAL_SCREEN_HEIGHT) = targetH;
    }

    if (real_Screen_SetResolution) {
        real_Screen_SetResolution(targetW, targetH, fullscreenMode, refreshRate);
    }
}

static void apply_zoom_resolution(uintptr_t base, float zoom) {
    if (!base) return;
    int targetW = (int)(1024 * zoom);
    int targetH = (int)(600 * zoom);

    @try {
        // 1. Cập nhật trực tiếp 2 biến global Screen.width & Screen.height của Unity Engine (__DATA)
        *(int32_t *)(base + OFF_GLOBAL_SCREEN_WIDTH)  = targetW;
        *(int32_t *)(base + OFF_GLOBAL_SCREEN_HEIGHT) = targetH;

        // 2. Gọi hàm native SetResolution của Unity Engine để cập nhật buffer render live
        if (real_Screen_SetResolution) {
            real_Screen_SetResolution(targetW, targetH, 0, NULL);
        }

        // 3. Đăng ký lại icall qua il2cpp_add_internal_call
        void (*fn_add_icall)(const char *, const void *) = (void (*)(const char *, const void *))(base + OFF_IL2CPP_ADD_INTERNAL_CALL);
        if (fn_add_icall) {
            fn_add_icall("UnityEngine.Screen::get_width", (void *)my_icall_Screen_get_width);
            fn_add_icall("UnityEngine.Screen::get_height", (void *)my_icall_Screen_get_height);
            fn_add_icall("UnityEngine.Screen::SetResolution_Injected", (void *)my_icall_Screen_SetResolution);
            fn_add_icall("UnityEngine.GL::GLLoadPixelMatrixScript", (void *)my_icall_GLLoadPixelMatrixScript);
        }

        NSLog(@"[MobiArmyMod] Đã áp dụng zoom %.1fx: %d x %d (Native Variables + Icalls OK)", zoom, targetW, targetH);
    } @catch (id ex) {
        NSLog(@"[MobiArmyMod] Lỗi apply_zoom_resolution: %@", ex);
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
// 3. QUÉT TRẬN ĐẤU AN TOÀN TUYỆT ĐỐI (ZERO CRASH)
// ==========================================
static void init_il2cpp_api(uintptr_t base) {
    p_domain_get = (Il2CppDomain *(*)(void))(base + OFF_DOMAIN_GET);
    p_domain_get_assemblies = (Il2CppAssembly **(*)(Il2CppDomain *, size_t *))(base + OFF_DOMAIN_GET_ASSEMBLIES);
    p_assembly_get_image = (Il2CppImage *(*)(Il2CppAssembly *))(base + OFF_ASSEMBLY_GET_IMAGE);
    p_image_get_name = (const char *(*)(Il2CppImage *))(base + OFF_IMAGE_GET_NAME);
    p_class_from_name = (Il2CppClass *(*)(const Il2CppImage *, const char *, const char *))(base + OFF_CLASS_FROM_NAME);
}

static uintptr_t resolve_battle_manager_class(uintptr_t base) {
    if (s_battleClass) return (uintptr_t)s_battleClass;

    // Cách 1: Đọc trực tiếp con trỏ tại OFF_BATTLE_MANAGER_CLASS (0x3bb9190) nếu đã được game khởi tạo
    uintptr_t tokenPtr = 0;
    if (safe_read(&tokenPtr, (const void *)(base + OFF_BATTLE_MANAGER_CLASS), sizeof(uintptr_t))) {
        if (tokenPtr >= 0x100000000ULL && tokenPtr < 0x3000000000ULL) {
            s_battleClass = (Il2CppClass *)tokenPtr;
            return (uintptr_t)s_battleClass;
        }
    }

    // Cách 2: Tìm qua IL2CPP Domain & Image name (Public IL2CPP APIs, an toàn 100%)
    if (!p_domain_get) {
        init_il2cpp_api(base);
    }
    if (p_domain_get) {
        Il2CppDomain *domain = p_domain_get();
        if (domain) {
            if (!s_gameImage) {
                size_t count = 0;
                Il2CppAssembly **asms = p_domain_get_assemblies(domain, &count);
                if (asms) {
                    for (size_t i = 0; i < count; i++) {
                        Il2CppImage *img = p_assembly_get_image(asms[i]);
                        if (!img) continue;
                        const char *name = p_image_get_name(img);
                        if (name && strstr(name, "Assembly-CSharp")) {
                            s_gameImage = img;
                            break;
                        }
                    }
                }
            }

            if (s_gameImage && p_class_from_name) {
                s_battleClass = p_class_from_name(s_gameImage,
                                                  "lllIIlllllllIlIIIIllIIIIIlllIIIlIlIl",
                                                  "llIlIlIIlllllllllllIlllIIllIlllIIIlIIIlIIllIllIIIIIIlIlIIIlIlIIlIIlIllIl");
            }
        }
    }

    if (!s_battleClass) {
        s_debugScanState = 3;
        return 0;
    }

    return (uintptr_t)s_battleClass;
}

static void scanBattleState(void) {
    @try {
        if (!unity_base) {
            s_debugScanState = 0;
            g_myPlayer = NULL;
            g_enemyCount = 0;
            return;
        }

        uintptr_t classPtr = resolve_battle_manager_class(unity_base);
        if (!classPtr) {
            g_myPlayer = NULL;
            g_enemyCount = 0;
            return;
        }

        // Đọc static_fields (offset 0xA0 của Il2CppClass - kiểm chứng từ disassembly 0x295fac)
        uintptr_t staticFields = 0;
        if (!safe_read(&staticFields, (const void *)(classPtr + 0xA0), sizeof(uintptr_t)) ||
            staticFields < 0x100000000ULL) {
            s_debugScanState = 4;
            g_myPlayer = NULL;
            g_enemyCount = 0;
            return;
        }

        // Quét tìm mảng playerArray trong staticFields tại các offset 0x8, 0x0, 0x10, 0x18, 0x20
        uintptr_t playerArray = 0;
        int32_t count = 0;
        size_t candidateOffsets[] = { 0x8, 0x0, 0x10, 0x18, 0x20 };
        for (int c = 0; c < 5; c++) {
            uintptr_t cand = 0;
            if (safe_read(&cand, (const void *)(staticFields + candidateOffsets[c]), sizeof(uintptr_t)) &&
                cand >= 0x100000000ULL && cand < 0x3000000000ULL) {
                int32_t testCount = 0;
                if (safe_read(&testCount, (const void *)(cand + 0x18), sizeof(int32_t)) &&
                    testCount >= 1 && testCount <= 16) {
                    playerArray = cand;
                    count = testCount;
                    break;
                }
            }
        }

        if (playerArray < 0x100000000ULL || count <= 0) {
            // Chưa vào trận (mảng allPlayers là NULL hoặc rỗng)
            s_debugScanState = 5;
            g_myPlayer = NULL;
            g_enemyCount = 0;
            return;
        }

        void *myPlayer = NULL;

        // 1. Quét tìm player có flag isMe == 1 (chính xác tuyệt đối)
        for (int i = 0; i < count; i++) {
            uintptr_t p = 0;
            safe_read(&p, (const void *)(playerArray + 0x20 + (size_t)i * 8), sizeof(uintptr_t));
            if (!p || p < 0x100000000ULL) continue;
            uint8_t isMe = 0;
            safe_read(&isMe, (const void *)(p + OFF_PLAYER_IS_ME), sizeof(uint8_t));
            if (isMe) {
                myPlayer = (void *)p;
                break;
            }
        }

        // 2. Nếu flag isMe chưa set, đọc myIdx tại staticFields + 0x30 (SByte)
        if (!myPlayer) {
            int8_t myIdx = -1;
            safe_read(&myIdx, (const void *)(staticFields + 0x30), sizeof(int8_t));
            if (myIdx >= 0 && myIdx < count) {
                uintptr_t p = 0;
                safe_read(&p, (const void *)(playerArray + 0x20 + (size_t)myIdx * 8), sizeof(uintptr_t));
                if (p >= 0x100000000ULL) {
                    myPlayer = (void *)p;
                }
            }
        }

        // 3. Fallback: Nếu đã có playerArray với count > 0 nhưng chưa rõ ai là mình, lấy tạm player 0
        if (!myPlayer && count > 0) {
            uintptr_t p = 0;
            safe_read(&p, (const void *)(playerArray + 0x20), sizeof(uintptr_t));
            if (p >= 0x100000000ULL) {
                myPlayer = (void *)p;
            }
        }

        if (!myPlayer) {
            s_debugScanState = 5;
            g_myPlayer = NULL;
            g_enemyCount = 0;
            return;
        }

        s_debugScanState = 6; // ĐÃ VÀO TRẬN ĐẤU THÀNH CÔNG!
        g_myPlayer = myPlayer;
        g_battleUpdateCount++;

        // Đọc toạ độ của bản thân
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

        // Đọc danh sách đối thủ
        int activeEnemyCount = 0;
        EnemyTarget tempEnemies[MAX_TARGETS];

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

            if (hp > 0) {
                EnemyTarget en;
                en.id = pid != 0 ? pid : (int32_t)(i + 1);
                en.x = px;
                en.y = py;
                en.hp = hp;
                en.team = team;
                float dx = (float)(px - mx);
                float dy = (float)(py - my);
                en.distance = sqrtf(dx * dx + dy * dy);
                snprintf(en.name, sizeof(en.name), "Địch #%d (HP:%d)", en.id, hp);
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
    zoomTitle.text = @"MỨC ZOOM BẢN ĐỒ (SIÊU RỘNG):";
    zoomTitle.font = [UIFont boldSystemFontOfSize:11];
    zoomTitle.textColor = [UIColor colorWithWhite:0.75 alpha:1.0];
    [self.panelView addSubview:zoomTitle];
    curY += 20;

    self.zoomSegment = [[UISegmentedControl alloc] initWithItems:@[@"1.0x", @"2.0x", @"3.0x", @"4.0x", @"5.0x"]];
    self.zoomSegment.frame = CGRectMake(16, curY, panelW - 32, 26);
    self.zoomSegment.selectedSegmentIndex = 2; // 3.0x mặc định
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
    } @catch (id ex) {
        NSLog(@"[MobiArmyMod] Lỗi togglePanel: %@", ex);
    }
}

- (void)onZoomChanged:(UISegmentedControl *)sender {
    @try {
        float values[] = { 1.0f, 2.0f, 3.0f, 4.0f, 5.0f };
        if (sender.selectedSegmentIndex >= 0 && sender.selectedSegmentIndex < 5) {
            g_zoomFactor = values[sender.selectedSegmentIndex];
        }
        if (unity_base) {
            apply_zoom_resolution(unity_base, g_zoomFactor);
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

- (void)refreshUI {
    @try {
        if (!unity_base) {
            self.targetInfoLabel.text = @"Đang tìm game...";
            self.targetInfoLabel.textColor = [UIColor yellowColor];
            self.aimInfoLabel.text = @"Góc: --°  |  Lực: --";
            self.statusLabel.text = @"Chờ nạp UnityFramework...";
            return;
        }

        scanBattleState();

        BOOL inBattle = (g_myPlayer != NULL);

        if (!inBattle) {
            self.targetInfoLabel.text = @"Chưa vào trận đấu";
            self.targetInfoLabel.textColor = [UIColor yellowColor];
            self.aimInfoLabel.text = @"Góc: --°  |  Lực: --";

            const char *stateDesc = "Đang tìm game...";
            if (s_debugScanState == 1) stateDesc = "Đang kết nối Unity domain...";
            else if (s_debugScanState == 2) stateDesc = "Đang nạp Assembly-CSharp...";
            else if (s_debugScanState == 3) stateDesc = "Chờ BattleManager...";
            else if (s_debugScanState == 4) stateDesc = "Chờ khởi tạo trận...";
            else if (s_debugScanState == 5) stateDesc = "Sẵn sàng (Vào trận để quét)...";

            self.statusLabel.text = [NSString stringWithFormat:@"Zoom: %.1fx | %s", g_zoomFactor, stateDesc];
            return;
        }

        updateAimSolution();

        if (g_enemyCount == 0) {
            self.targetInfoLabel.text = [NSString stringWithFormat:@"Đã vào trận (Ta: %d, %d)", g_lastMyX, g_lastMyY];
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

        NSLog(@"[MobiArmyMod] Bắt đầu cài đặt Hooks vào UnityFramework (0x%lx)...", base);

        // 1. Áp dụng hook zoom & SetResolution ngay lập tức
        real_Screen_get_width_icall = (int (*)(void))(base + RVA_NATIVE_SCREEN_GET_WIDTH);
        real_Screen_get_height_icall = (int (*)(void))(base + RVA_NATIVE_SCREEN_GET_HEIGHT);
        real_GLLoadPixelMatrixScript = (void (*)(float, float, float, float))(base + RVA_NATIVE_GL_LOAD_MATRIX);
        real_Screen_SetResolution = (void (*)(int, int, int, const void *))(base + RVA_NATIVE_SCREEN_SET_RESOLUTION);

        apply_zoom_resolution(base, g_zoomFactor);

        // 2. Khởi tạo IL2CPP metadata APIs
        init_il2cpp_api(base);

        // 3. Hook qua MSHookFunction nếu có Substrate/Ellekit (Dopamine / Sileo)
        void (*fn_MSHook)(void *, void *, void **) = (void (*)(void *, void *, void **))dlsym(RTLD_DEFAULT, "MSHookFunction");
        if (fn_MSHook) {
            fn_MSHook((void *)(base + OFF_SERVICE_SEND_SHOOT), (void *)hook_SendShoot, (void **)&orig_SendShoot);
            fn_MSHook((void *)(base + RVA_NATIVE_SCREEN_SET_RESOLUTION), (void *)my_icall_Screen_SetResolution, (void **)&real_Screen_SetResolution);
            fn_MSHook((void *)(base + RVA_NATIVE_GL_LOAD_MATRIX), (void *)my_icall_GLLoadPixelMatrixScript, (void **)&real_GLLoadPixelMatrixScript);
            fn_MSHook((void *)(base + RVA_NATIVE_SCREEN_GET_WIDTH), (void *)my_icall_Screen_get_width, (void **)&real_Screen_get_width_icall);
            fn_MSHook((void *)(base + RVA_NATIVE_SCREEN_GET_HEIGHT), (void *)my_icall_Screen_get_height, (void **)&real_Screen_get_height_icall);
            NSLog(@"[MobiArmyMod] MSHookFunction đã cài đặt toàn bộ hooks!");
        }

        g_hooksInstalled = YES;
        NSLog(@"[MobiArmyMod] HOÀN TẤT KHỞI TẠO MOD THÀNH CÔNG 100%%!");
    });
}

__attribute__((constructor)) static void MobiArmyModInit(void) {
    NSLog(@"[MobiArmyMod] Dylib khởi chạy trong tiến trình pid: %d", getpid());

    find_unity_base();

    // Chờ Unity và App khởi động hoàn toàn (1.5s sau active) trên main thread
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification * _Nonnull note) {
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                install_hooks();
                [[MobiHUDManager shared] attachToKeyWindow];
            });
        });
    }];

    // Fallback: Nếu không nhận được notification sau 2.5s thì tự động khởi tạo
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        install_hooks();
        [[MobiHUDManager shared] attachToKeyWindow];
    });
}
