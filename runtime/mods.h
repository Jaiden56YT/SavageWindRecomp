// Code mods (runtime/mods.c): exlaunch modules loaded with the game, and their hooks.
#pragma once
#include <stdbool.h>
#include <stdint.h>

#include "cpu.h"
#include "rt.h"

#define MODS_MAX_HOOKS 256

// runtime/loader.c: a module was loaded from nso_path; it is a mod if <nso_path>.mod (its symbols) is there
void mods_module_loaded(const Module *m, const char *nso_path);
bool mods_is_mod(const Module *m);
void mods_reset(void);        // before the modules are loaded again
void mods_hooks_reset(void);

// runtime/dispatch.c: the function a call to pc runs because of a hook (a hooked function's callback, or the
// original of one for its callback), NULL if hooks say nothing about pc
GuestFn mods_dispatch(uint64_t pc);
// runtime/dispatch.c: the function at pc without hooks (NULL: none); drop this thread's cached lookups
GuestFn dispatch_resolve(uint64_t pc);
void dispatch_flush(void);
