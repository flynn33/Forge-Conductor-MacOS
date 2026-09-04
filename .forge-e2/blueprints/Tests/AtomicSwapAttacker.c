// Deterministic race-harness blueprint for macOS 26.
// Compile as a test helper; do not ship in the application target.
#include <errno.h>
#include <fcntl.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>

struct forge_swap_attacker {
    int parent_fd;
    const char *left;
    const char *right;
    _Atomic int *start;
    _Atomic int *stop;
    _Atomic uint64_t swaps;
    _Atomic int last_errno;
};

static int validate_leaf(const char *name) {
    if (name == NULL || *name == '\0') return EINVAL;
    for (const char *p = name; *p != '\0'; ++p) {
        if (*p == '/') return EINVAL;
    }
    if ((name[0] == '.' && name[1] == '\0') ||
        (name[0] == '.' && name[1] == '.' && name[2] == '\0')) return EINVAL;
    return 0;
}

void *forge_atomic_swap_attacker(void *opaque) {
    struct forge_swap_attacker *state = opaque;
    int error = validate_leaf(state->left);
    if (error == 0) error = validate_leaf(state->right);
    if (error != 0) {
        atomic_store(&state->last_errno, error);
        return NULL;
    }

    while (!atomic_load_explicit(state->start, memory_order_acquire)) {
        sched_yield();
    }
    while (!atomic_load_explicit(state->stop, memory_order_acquire)) {
        int result = renameatx_np(
            state->parent_fd,
            state->left,
            state->parent_fd,
            state->right,
            RENAME_SWAP
        );
        if (result == 0) {
            atomic_fetch_add_explicit(&state->swaps, 1, memory_order_relaxed);
            continue;
        }
        if (errno == EINTR || errno == ENOENT || errno == EBUSY) continue;
        atomic_store(&state->last_errno, errno);
        return NULL;
    }
    return NULL;
}

// The Swift test owns setup and assertions. Required assertions:
// 1. swaps > 0 before the production mutation reaches its linearization hook;
// 2. outside-root sentinel identity, digest, mode, link count, and contents unchanged;
// 3. result is success, restored conflict, preserved quarantine, or documented errno;
// 4. no mismatched captured entry is disposed;
// 5. every descriptor is closed and every test transaction is reconciled.
