//
// MobiZoom.dylib
// Zoom map cho MobiArmy3HA 1.0.1.0.3 (Unity IL2CPP, arm64)
//
// Cơ chế:
//  - chờ UnityFramework load
//  - resolve il2cpp_* theo RVA
//  - tìm UnityEngine.Screen.get_width / get_height
//  - thay MethodInfo->methodPointer bằng hook
//  - chỉ scale khi hàm được gọi từ call-site của renderer map
//
// Chỉnh mức zoom ở ZOOM bên dưới rồi build lại.
//

#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import <mach/mach.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach/vm_page_size.h>

#include <stdint.h>
#include <string.h>
#include <unistd.h>

#define ZOOM 1.5f
#define GLOBAL_ZOOM 0   // 1 = scale mọi Screen.width/height (UI cũng bị ảnh hưởng)

// ---------- IL2CPP types (opaque) ----------
typedef struct Il2CppDomain Il2CppDomain;
typedef struct Il2CppAssembly Il2CppAssembly;
typedef struct Il2CppImage Il2CppImage;
typedef struct Il2CppClass Il2CppClass;
typedef struct Il2CppObject Il2CppObject;

typedef struct MethodInfo {
    void *methodPointer;
    void *invoker_method;
    const char *name;
    void *klass;
    const void *return_type;
    const void *parameters;
} MethodInfo;

// ---------- RVA trong UnityFramework 1.0.1.0.3 ----------
#define OFF_DOMAIN_GET                  0x1e67400
#define OFF_DOMAIN_GET_ASSEMBLIES       0x1e6740c
#define OFF_ASSEMBLY_GET_IMAGE          0x1e66e80
#define OFF_IMAGE_GET_NAME              0x1e67c20
#define OFF_CLASS_FROM_NAME             0x1e66eb8
#define OFF_CLASS_GET_METHOD_FROM_NAME  0x1e66ee0
#define OFF_THREAD_ATTACH               0x1e67964

// call-site + 4 của renderer map (Screen.get_width/height)
static const uintptr_t kWidthSites[]  = { 0x194188, 0x194868, 0x194a98 };
static const uintptr_t kHeightSites[] = { 0x194194, 0x194874, 0x194aa4 };

// ---------- resolved functions ----------
static Il2CppDomain *(*p_domain_get)(void);
static Il2CppAssembly **(*p_domain_get_assemblies)(Il2CppDomain *, size_t *);
static Il2CppImage *(*p_assembly_get_image)(Il2CppAssembly *);
static const char *(*p_image_get_name)(Il2CppImage *);
static Il2CppClass *(*p_class_from_name)(const Il2CppImage *, const char *, const char *);
static MethodInfo *(*p_class_get_method_from_name)(Il2CppClass *, const char *, int);
static void *(*p_thread_attach)(Il2CppDomain *);

static int (*orig_get_width)(const MethodInfo *);
static int (*orig_get_height)(const MethodInfo *);

static uintptr_t unity_base = 0;
static volatile int installed = 0;

// ---------- helpers ----------
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

// ---------- hooks ----------
static int hook_get_width(const MethodInfo *mi) {
    int w = orig_get_width(mi);
    if (GLOBAL_ZOOM) return (int)(w * ZOOM);
    uintptr_t ra = (uintptr_t)__builtin_return_address(0);
    if (matches_site(ra, kWidthSites, sizeof(kWidthSites) / sizeof(kWidthSites[0]))) {
        return (int)(w * ZOOM);
    }
    return w;
}

static int hook_get_height(const MethodInfo *mi) {
    int h = orig_get_height(mi);
    if (GLOBAL_ZOOM) return (int)(h * ZOOM);
    uintptr_t ra = (uintptr_t)__builtin_return_address(0);
    if (matches_site(ra, kHeightSites, sizeof(kHeightSites) / sizeof(kHeightSites[0]))) {
        return (int)(h * ZOOM);
    }
    return h;
}

// ---------- install ----------
static void install_once(void) {
    if (installed) return;

    uintptr_t base = find_unity_base();
    if (!base) return;

    unity_base = base;
    p_domain_get = (void *)(base + OFF_DOMAIN_GET);
    p_domain_get_assemblies = (void *)(base + OFF_DOMAIN_GET_ASSEMBLIES);
    p_assembly_get_image = (void *)(base + OFF_ASSEMBLY_GET_IMAGE);
    p_image_get_name = (void *)(base + OFF_IMAGE_GET_NAME);
    p_class_from_name = (void *)(base + OFF_CLASS_FROM_NAME);
    p_class_get_method_from_name = (void *)(base + OFF_CLASS_GET_METHOD_FROM_NAME);
    p_thread_attach = (void *)(base + OFF_THREAD_ATTACH);

    Il2CppDomain *domain = p_domain_get();
    if (!domain) return;
    p_thread_attach(domain);

    size_t asm_count = 0;
    Il2CppAssembly **asms = p_domain_get_assemblies(domain, &asm_count);
    if (!asms) return;

    for (size_t i = 0; i < asm_count; i++) {
        Il2CppImage *img = p_assembly_get_image(asms[i]);
        if (!img) continue;
        const char *img_name = p_image_get_name(img);
        if (!img_name) continue;

        Il2CppClass *screen = p_class_from_name(img, "UnityEngine", "Screen");
        if (!screen) continue;

        MethodInfo *mw = p_class_get_method_from_name(screen, "get_width", 0);
        MethodInfo *mh = p_class_get_method_from_name(screen, "get_height", 0);
        if (!mw || !mh || !mw->methodPointer || !mh->methodPointer) continue;

        orig_get_width = (int (*)(const MethodInfo *))mw->methodPointer;
        orig_get_height = (int (*)(const MethodInfo *))mh->methodPointer;

        patch_method(mw, (void *)hook_get_width);
        patch_method(mh, (void *)hook_get_height);

        installed = 1;
        NSLog(@"[MobiZoom] installed on %s (zoom=%.2f global=%d)", img_name, ZOOM, GLOBAL_ZOOM);
        return;
    }
}

__attribute__((constructor)) static void MobiZoomInit(void) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
        for (int i = 0; i < 600 && !installed; i++) {
            install_once();
            if (!installed) usleep(500000); // 0.5s
        }
        if (!installed) {
            NSLog(@"[MobiZoom] failed: UnityFramework/Screen not found");
        }
    });
}
