// Code mods: an exlaunch module (a "subsdk9" made for the console) loaded with the game.
//
// tools/layout.py places a subsdk that isn't the game's after the sdk when it has a manifest next to it
// (extracted/exefs/<name>.mod, the mod's symbols: tools/mod_add.py), tools/gen.py recompiles it like the game's own
// modules, and runtime/loader.c loads it. What exlaunch does to the console's process has no meaning here - it reads
// the kernel's memory map to find the modules, maps the game's code writable and writes branches into it - so three
// of its functions are this file's (gen.py MOD_HLE):
//   exl_init                      the module table it would have read from the memory map
//   exl::hook::nx64::Initialize   nothing (its JIT area for trampolines)
//   exl::hook::nx64::Hook         a hook is an entry in a table, not a patched instruction
// A hooked function reaches the mod's callback in one of two ways. Functions listed in extracted/exefs/hooks.txt are
// generated with a check of their slot (game_hook_slots) at their start (every call passes it, direct ones too). Any other is only
// redirected where a call goes through the dispatcher (runtime/dispatch.c): calls through a pointer and between
// modules, which is how the game reaches the SDK's functions - enough for those, not for a function the game calls
// directly. The callback's "original" is a fake address the dispatcher answers with the function's own body.
//
// The mod's imports that this runtime has no service for are host functions for mods only ("mod:" names, tried first
// for a mod's imports by runtime/loader.c): nn::socket on the host's sockets, nn::nifm saying the network is up.
#include "mods.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
typedef int socklen_t_;
#else
#include <arpa/inet.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>
#endif

#include "hle.h"
#include "kernel.h"
#include "rt.h"

// ------------------------------------------------------------------ manifests
typedef struct { char *name; uint64_t addr; } ModSym;
typedef struct { const Module *m; ModSym *syms; int n; } ModInfo;
static ModInfo g_mods[MAX_MODULES];
static int g_nmods;

void mods_reset(void) {
    for (int i = 0; i < g_nmods; i++) {
        for (int j = 0; j < g_mods[i].n; j++) free(g_mods[i].syms[j].name);
        free(g_mods[i].syms);
    }
    g_nmods = 0;
}

// <exefs>/<module>.mod: `nm` lines, "<hex address> <type> <name>" (addresses from the module's start)
void mods_module_loaded(const Module *m, const char *nso_path) {
    char path[1100];
    snprintf(path, sizeof path, "%s.mod", nso_path);
    FILE *f = fopen(path, "r");
    if (!f) return;
    ModInfo *mi = &g_mods[g_nmods++];
    memset(mi, 0, sizeof *mi);
    mi->m = m;
    char line[2048], type[8], name[1024];
    unsigned long long a;
    int cap = 0;
    while (fgets(line, sizeof line, f)) {
        if (sscanf(line, "%llx %7s %1023s", &a, type, name) != 3) continue;
        if (mi->n == cap) mi->syms = realloc(mi->syms, (cap = cap ? cap * 2 : 1024) * sizeof *mi->syms);
        mi->syms[mi->n].name = strdup(name);
        mi->syms[mi->n++].addr = m->base + a;
    }
    fclose(f);
    LOG("[mods] %s is a mod: %d symbols in its manifest\n", m->name, mi->n);
}

bool mods_is_mod(const Module *m) {
    for (int i = 0; i < g_nmods; i++)
        if (g_mods[i].m == m) return true;
    return false;
}

static ModInfo *mod_at(uint64_t addr) {
    for (int i = 0; i < g_nmods; i++)
        if (addr >= g_mods[i].m->base && addr < g_mods[i].m->base + g_mods[i].m->size) return &g_mods[i];
    return g_nmods == 1 ? &g_mods[0] : NULL;
}

static uint64_t mod_sym(ModInfo *mi, const char *name) {
    for (int j = 0; mi && j < mi->n; j++)
        if (!strcmp(mi->syms[j].name, name)) return mi->syms[j].addr;
    return 0;
}

// ------------------------------------------------------------------ exlaunch start-up
// exl::util::ModuleIndex: Rtld, Main, Subsdk0..9, Sdk
static int exl_index(const char *name) {
    if (!strcmp(name, "main")) return 1;
    if (!strcmp(name, "sdk")) return 12;
    if (!strncmp(name, "subsdk", 6)) return 2 + atoi(name + 6);
    return -1;
}

// void exl_init(): exl::util::impl::InitMemLayout's result (the modules, from the loader instead of svcQueryMemory).
// The patcher, the version lookup and the symbol tables it also sets up are left as they start: the first writes
// into the game's code, the others are for hooks placed by symbol, which need tables the mod would bring.
void hle_mod_exl_init(Cpu *c) {
    ModInfo *mi = mod_at(c->x[30]);
    uint64_t infos = mod_sym(mi, "_ZN3exl4util4impl10mem_layout13s_ModuleInfosE");
    uint64_t bits = mod_sym(mi, "_ZN3exl4util4impl10mem_layout14s_ModuleBitsetE");
    uint64_t self = mod_sym(mi, "_ZN3exl4util10mem_layout15s_SelfModuleIdxE");
    if (!infos || !bits || !self) FATAL("[mods] %s: not an exlaunch module this runtime knows (no module table)\n",
                                        mi ? mi->m->name : "?");
    uint64_t set = 0;
    for (int i = 0; i < g_nmodules; i++) {
        const Module *m = &g_modules[i];
        int k = exl_index(m->name);
        if (k < 0) continue;
        uint64_t *e = (uint64_t *)(infos + 72ull * k);  // ModuleInfo: Range m_Total, m_Text, m_Rodata, m_Data; Mod0 *
        e[0] = m->base;                e[1] = m->data_off + m->data_size;
        e[2] = m->base + m->text_off;  e[3] = m->text_size;
        e[4] = m->base + m->ro_off;    e[5] = m->ro_size;
        e[6] = m->base + m->data_off;  e[7] = m->data_size;
        e[8] = m->base + *(uint32_t *)(m->base + 4);
        set |= 1ull << k;
        if (m == mi->m) *(uint32_t *)self = (uint32_t)k;
    }
    *(uint64_t *)bits = set;
    LOG("[mods] %s: exlaunch set up (modules %#llx)\n", mi->m->name, (unsigned long long)set);
}

void hle_mod__ZN3exl4hook4nx6410InitializeEv(Cpu *c) { (void)c; }

// ------------------------------------------------------------------ hooks
extern const uint64_t *g_game_hook_addrs;  // runtime/gamelib.c: the game code's hookable functions
extern const GuestFn *g_game_hook_origs;
extern uint64_t *g_game_hook_slots;  // by hooks.txt index: the callback of a hookable function (0: none)
extern uint32_t g_game_hook_count;

// Hooks on functions that aren't hookable: answered by the dispatcher only
typedef struct { uint64_t target, callback; GuestFn orig; } DynHook;
static DynHook g_dyn[MODS_MAX_HOOKS];
static int g_ndyn;

#define TRAMP_BASE (HLE_BASE + HLE_SIZE - 0x20000)  // fake addresses of "the original function": 16 bytes each
#define TRAMP_DYN  (TRAMP_BASE + 16ull * MODS_MAX_HOOKS)

void mods_hooks_reset(void) {
    if (g_game_hook_slots) memset(g_game_hook_slots, 0, g_game_hook_count * sizeof *g_game_hook_slots);
    g_ndyn = 0;
}

GuestFn mods_dispatch(uint64_t pc) {
    if (pc >= TRAMP_BASE && pc < TRAMP_DYN + 16ull * MODS_MAX_HOOKS) {
        uint64_t i = (pc - TRAMP_BASE) / 16;
        if (i < MODS_MAX_HOOKS) return i < g_game_hook_count ? g_game_hook_origs[i] : NULL;
        i -= MODS_MAX_HOOKS;
        return i < (uint64_t)g_ndyn ? g_dyn[i].orig : NULL;
    }
    for (int i = 0; i < g_ndyn; i++)
        if (g_dyn[i].target == pc) return dispatch_resolve(g_dyn[i].callback);
    return NULL;
}

// uintptr_t exl::hook::nx64::Hook(uintptr_t hook, uintptr_t callback, bool do_trampoline): the address to call for
// the original function
void hle_mod__ZN3exl4hook4nx644HookEmmb(Cpu *c) {
    uint64_t target = c->x[0], callback = c->x[1];
    uint64_t off;
    const char *s = loader_symbol_at(target, &off);
    for (uint32_t i = 0; i < g_game_hook_count && i < MODS_MAX_HOOKS; i++) {
        if (g_game_hook_addrs[i] != target || !g_game_hook_origs[i]) continue;
        g_game_hook_slots[i] = callback;
        LOG("[mods] hook %llx (%s+%llx) -> %llx: at the function\n", (unsigned long long)target, s ? s : "?",
            (unsigned long long)off, (unsigned long long)callback);
        c->x[0] = TRAMP_BASE + 16ull * i;
        return;
    }
    GuestFn orig = dispatch_resolve(target);
    if (!orig || g_ndyn == MODS_MAX_HOOKS) FATAL("[mods] hook: no function at %llx\n", (unsigned long long)target);
    g_dyn[g_ndyn] = (DynHook){target, callback, orig};
    bool in_game = target >= MAIN_BASE && target < MODULES_END;
    LOG("[mods] hook %llx (%s+%llx) -> %llx: where calls are dispatched%s\n", (unsigned long long)target, s ? s : "?",
        (unsigned long long)off, (unsigned long long)callback,
        in_game ? " (calls from its own module miss it: add it to hooks.txt and build the game code again)" : "");
    if (in_game) {  // (what to add, ready to copy)
        for (int i = 0; i < g_nmodules; i++)
            if (target >= g_modules[i].base && target < g_modules[i].base + g_modules[i].size)
                LOG("[mods]   hooks.txt: %s+%llx\n", g_modules[i].name, (unsigned long long)(target - g_modules[i].base));
    }
    dispatch_flush();
    c->x[0] = TRAMP_DYN + 16ull * g_ndyn++;
}

// ------------------------------------------------------------------ nn::socket, nn::nifm (mods only)
#define A(i) (c->x[i])
#define RET(v) (c->x[0] = (uint64_t)(v))

static __thread int t_sock_errno;
// The console's errno numbers are FreeBSD's
static int bsd_errno(int e) {
#ifdef _WIN32
    switch (e) {
    case WSAEWOULDBLOCK: return 35; case WSAEINPROGRESS: return 36; case WSAECONNREFUSED: return 61;
    case WSAETIMEDOUT: return 60; case WSAECONNRESET: return 54; case WSAENOTCONN: return 57; case WSAEINTR: return 4;
    }
    return e ? 5 : 0;
#else
    switch (e) {
    case 0: return 0;
    case EINTR: return 4; case EBADF: return 9; case EINVAL: return 22; case EPIPE: return 32;
    case EAGAIN: return 35; case EINPROGRESS: return 36; case ECONNRESET: return 54; case ENOTCONN: return 57;
    case ETIMEDOUT: return 60; case ECONNREFUSED: return 61; case EHOSTUNREACH: return 65; case ENETUNREACH: return 51;
    }
    return 5;  // EIO
#endif
}
static int sock_err(void) {
#ifdef _WIN32
    return bsd_errno(WSAGetLastError());
#else
    return bsd_errno(errno);
#endif
}
static int64_t sock_ret(int64_t r) {
    t_sock_errno = r < 0 ? sock_err() : 0;
    return r;
}

HLE_FUNC("mod:_ZN2nn6socket10InitializeEPvmmi", mod_socket_initialize) {
#ifdef _WIN32
    WSADATA w;
    WSAStartup(MAKEWORD(2, 2), &w);
#endif
    LOG("[mods] nn::socket::Initialize: the host's sockets\n");
    RET(0);
}
HLE_FUNC("mod:_ZN2nn6socket6SocketENS0_6FamilyENS0_4TypeENS0_8ProtocolE", mod_socket_socket) {
    int type = (int)A(1) == 2 ? SOCK_DGRAM : SOCK_STREAM, proto = (int)A(2) == 17 ? IPPROTO_UDP : (int)A(2) == 6 ? IPPROTO_TCP : 0;
    RET(sock_ret((int64_t)socket(AF_INET, type, proto)));
}
HLE_FUNC("mod:_ZN2nn6socket7ConnectEiPKNS0_8SockAddrEj", mod_socket_connect) {
    const uint8_t *ga = (const uint8_t *)(uintptr_t)A(1);  // u8 len, u8 family, u16 port, u32 addr (network order)
    struct sockaddr_in sa;
    memset(&sa, 0, sizeof sa);
    sa.sin_family = AF_INET;
    memcpy(&sa.sin_port, ga + 2, 2);
    memcpy(&sa.sin_addr, ga + 4, 4);
    kernel_host_work_begin();  // (blocks: the thread's core goes to the game's other threads meanwhile)
    int r = connect((int)A(0), (struct sockaddr *)&sa, sizeof sa);
    int64_t ret = sock_ret(r);
    kernel_host_work_end();
    LOG("[mods] connect %s:%d -> %d (errno %d)\n", inet_ntoa(sa.sin_addr), ntohs(sa.sin_port), r, t_sock_errno);
    RET(ret);
}
HLE_FUNC("mod:_ZN2nn6socket10SetSockOptEiNS0_5LevelENS0_6OptionEPKvj", mod_socket_setsockopt) {
    int level = (int)A(1), opt = (int)A(2);
    if (level == 6 && opt == 1) {
        int one = A(3) && A(4) >= 4 ? *(int *)(uintptr_t)A(3) : 1;
        RET(sock_ret(setsockopt((int)A(0), IPPROTO_TCP, TCP_NODELAY, (const void *)&one, sizeof one)));
        return;
    }
    t_sock_errno = 0;
    RET(0);  // (others: not needed on the host)
}
HLE_FUNC("mod:_ZN2nn6socket4PollEPNS0_6PollFdEmi", mod_socket_poll) {
    // PollFd { s32 fd; s16 events; s16 revents; } with FreeBSD's event bits: macOS's and Linux's struct pollfd as
    // it is. Windows has a wider one (the socket is 8 bytes) and other bits: translated both ways.
    kernel_host_work_begin();
#ifdef _WIN32
    struct { int32_t fd; int16_t events, revents; } *g = (void *)(uintptr_t)A(0);
    WSAPOLLFD w[16];
    ULONG n = A(1) < 16 ? (ULONG)A(1) : 16;
    for (ULONG i = 0; i < n; i++) {
        w[i].fd = (SOCKET)g[i].fd;
        w[i].events = (SHORT)((g[i].events & 0x1 ? POLLRDNORM : 0) | (g[i].events & 0x4 ? POLLWRNORM : 0));
        w[i].revents = 0;
    }
    int r = WSAPoll(w, n, (int)A(2));
    for (ULONG i = 0; i < n; i++)
        g[i].revents = (int16_t)((w[i].revents & (POLLRDNORM | POLLRDBAND) ? 0x1 : 0) | (w[i].revents & POLLWRNORM ? 0x4 : 0) |
                                 (w[i].revents & POLLERR ? 0x8 : 0) | (w[i].revents & POLLHUP ? 0x10 : 0) |
                                 (w[i].revents & POLLNVAL ? 0x20 : 0));
#else
    struct pollfd *p = (struct pollfd *)(uintptr_t)A(0);
    int r = poll(p, (nfds_t)A(1), (int)A(2));
#endif
    int64_t ret = sock_ret(r);
    kernel_host_work_end();
    RET(ret);
}
HLE_FUNC("mod:_ZN2nn6socket4RecvEiPvmNS0_7MsgFlagE", mod_socket_recv) {
    int flags = 0;
    bool wait = !(A(3) & 0x80);  // (MsgFlag::Msg_DontWait)
#ifdef _WIN32
    if (!wait) {  // no such flag on Windows: nothing to read yet is the same answer, "would block"
        WSAPOLLFD w = {(SOCKET)(int)A(0), POLLRDNORM, 0};
        if (WSAPoll(&w, 1, 0) == 0) { t_sock_errno = 35; RET(-1); return; }
    }
#else
    if (!wait) flags |= MSG_DONTWAIT;
#endif
    if (wait) kernel_host_work_begin();
#ifdef _WIN32
    int64_t r = sock_ret((int64_t)recv((SOCKET)(int)A(0), (char *)(uintptr_t)A(1), (int)A(2), flags));
#else
    int64_t r = sock_ret((int64_t)recv((int)A(0), (void *)(uintptr_t)A(1), (size_t)A(2), flags));
#endif
    if (wait) kernel_host_work_end();
    RET(r);
}
HLE_FUNC("mod:_ZN2nn6socket4SendEiPKvmNS0_7MsgFlagE", mod_socket_send) {
    int flags = 0;
#ifdef MSG_NOSIGNAL
    flags |= MSG_NOSIGNAL;  // (a closed connection is an error to the mod, not a signal to the game)
#endif
    kernel_host_work_begin();
#ifdef _WIN32
    int64_t r = sock_ret((int64_t)send((SOCKET)(int)A(0), (const char *)(uintptr_t)A(1), (int)A(2), flags));
#else
    int64_t r = sock_ret((int64_t)send((int)A(0), (const void *)(uintptr_t)A(1), (size_t)A(2), flags));
#endif
    kernel_host_work_end();
    RET(r);
}
HLE_FUNC("mod:_ZN2nn6socket5CloseEi", mod_socket_close) {
#ifdef _WIN32
    RET(sock_ret(closesocket((SOCKET)A(0))));
#else
    RET(sock_ret(close((int)A(0))));
#endif
}
HLE_FUNC("mod:_ZN2nn6socket12GetLastErrorEv", mod_socket_errno) { RET(t_sock_errno); }
HLE_FUNC("mod:_ZN2nn6socket8InetAtonEPKcPNS0_6InAddrE", mod_socket_aton) {
    struct in_addr a;
    int ok = inet_pton(AF_INET, (const char *)(uintptr_t)A(0), &a) == 1;
    if (ok && A(1)) memcpy((void *)(uintptr_t)A(1), &a, 4);
    RET(ok);
}
HLE_FUNC("mod:_ZN2nn6socket9InetHtonsEt", mod_socket_htons) { RET(htons((uint16_t)A(0))); }

HLE_FUNC("mod:_ZN2nn4nifm10InitializeEv", mod_nifm_initialize) { RET(0); }
HLE_FUNC("mod:_ZN2nn4nifm20SubmitNetworkRequestEv", mod_nifm_submit) { (void)c; }
HLE_FUNC("mod:_ZN2nn4nifm22IsNetworkRequestOnHoldEv", mod_nifm_on_hold) { RET(0); }
HLE_FUNC("mod:_ZN2nn4nifm18IsNetworkAvailableEv", mod_nifm_available) { RET(1); }
