#include "CForgeSecureFS.h"

#include <copyfile.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

bool fc_fs_valid_leaf(const char *name) {
    if (name == NULL || name[0] == '\0') return false;
    if (strcmp(name, ".") == 0 || strcmp(name, "..") == 0) return false;
    return strchr(name, '/') == NULL;
}

static void fc_fill_identity(const struct stat *st, fc_fs_identity *out) {
    out->error_number = 0;
    out->device = (uint64_t)st->st_dev;
    out->inode = (uint64_t)st->st_ino;
    out->mode = (uint32_t)st->st_mode;
    out->owner = (uint32_t)st->st_uid;
    out->group = (uint32_t)st->st_gid;
    out->link_count = (uint64_t)st->st_nlink;
    out->size = (int64_t)st->st_size;
    out->modified_seconds = (int64_t)st->st_mtimespec.tv_sec;
    out->modified_nanoseconds = (int64_t)st->st_mtimespec.tv_nsec;
    out->changed_seconds = (int64_t)st->st_ctimespec.tv_sec;
    out->changed_nanoseconds = (int64_t)st->st_ctimespec.tv_nsec;
}

fc_fs_api_capabilities fc_fs_compile_time_capabilities(void) {
    fc_fs_api_capabilities result = {0};
#if defined(O_RESOLVE_BENEATH)
    result.has_open_resolve_beneath = true;
#endif
#if defined(O_NOFOLLOW_ANY)
    result.has_open_no_follow_any = true;
#endif
#if defined(O_UNIQUE)
    result.has_open_unique = true;
#endif
#if defined(RENAME_EXCL)
    result.has_rename_exclusive = true;
#endif
#if defined(RENAME_NOFOLLOW_ANY)
    result.has_rename_no_follow_any = true;
#endif
#if defined(RENAME_RESOLVE_BENEATH)
    result.has_rename_resolve_beneath = true;
#endif
#if defined(RENAME_SWAP)
    result.has_rename_swap = true;
#endif
    return result;
}

int fc_open_search_root(const char *absolute_path) {
#if !defined(O_NOFOLLOW_ANY)
    errno = ENOTSUP;
    return -1;
#else
    return open(absolute_path, O_SEARCH | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY);
#endif
}

int fc_open_directory_beneath(int parent_fd, const char *relative_component) {
#if !defined(O_RESOLVE_BENEATH) || !defined(O_NOFOLLOW_ANY)
    errno = ENOTSUP;
    return -1;
#else
    if (!fc_fs_valid_leaf(relative_component)) {
        errno = EINVAL;
        return -1;
    }
    return openat(
        parent_fd,
        relative_component,
        O_SEARCH | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY | O_RESOLVE_BENEATH
    );
#endif
}

int fc_open_regular_beneath(
    int parent_fd,
    const char *relative_component,
    bool reject_any_symlink,
    bool require_unique_link
) {
#if !defined(O_RESOLVE_BENEATH)
    errno = ENOTSUP;
    return -1;
#else
    if (!fc_fs_valid_leaf(relative_component)) {
        errno = EINVAL;
        return -1;
    }
    int flags = O_RDONLY | O_CLOEXEC | O_RESOLVE_BENEATH;
#if defined(O_NOFOLLOW_ANY)
    if (reject_any_symlink) flags |= O_NOFOLLOW_ANY;
#else
    if (reject_any_symlink) {
        errno = ENOTSUP;
        return -1;
    }
#endif
#if defined(O_UNIQUE)
    if (require_unique_link) flags |= O_UNIQUE;
#else
    if (require_unique_link) {
        errno = ENOTSUP;
        return -1;
    }
#endif
    return openat(parent_fd, relative_component, flags);
#endif
}

int fc_mkdirat_component(int parent_fd, const char *name, uint32_t mode) {
    if (!fc_fs_valid_leaf(name)) {
        errno = EINVAL;
        return -1;
    }
    return mkdirat(parent_fd, name, (mode_t)mode);
}

static int fc_resolution_flags(fc_fs_rename_resolution_policy policy, unsigned int *out) {
    if (out == NULL) {
        errno = EINVAL;
        return -1;
    }
    *out = 0;
    if (policy == FC_FS_RENAME_LEAF_ONLY) return 0;
    if (policy != FC_FS_RENAME_STRICT_RESOLUTION) {
        errno = EINVAL;
        return -1;
    }
#if !defined(RENAME_NOFOLLOW_ANY) || !defined(RENAME_RESOLVE_BENEATH)
    errno = ENOTSUP;
    return -1;
#else
    *out = RENAME_NOFOLLOW_ANY | RENAME_RESOLVE_BENEATH;
    return 0;
#endif
}

int fc_rename_exclusive_leaf(
    int source_parent_fd,
    const char *source_name,
    int destination_parent_fd,
    const char *destination_name,
    fc_fs_rename_resolution_policy resolution_policy
) {
#if !defined(RENAME_EXCL)
    errno = ENOTSUP;
    return -1;
#else
    if (!fc_fs_valid_leaf(source_name) || !fc_fs_valid_leaf(destination_name)) {
        errno = EINVAL;
        return -1;
    }
    unsigned int flags = 0;
    if (fc_resolution_flags(resolution_policy, &flags) != 0) return -1;
    return renameatx_np(
        source_parent_fd,
        source_name,
        destination_parent_fd,
        destination_name,
        RENAME_EXCL | flags
    );
#endif
}

int fc_rename_swap_leaf(
    int left_parent_fd,
    const char *left_name,
    int right_parent_fd,
    const char *right_name,
    fc_fs_rename_resolution_policy resolution_policy
) {
#if !defined(RENAME_SWAP)
    errno = ENOTSUP;
    return -1;
#else
    if (!fc_fs_valid_leaf(left_name) || !fc_fs_valid_leaf(right_name)) {
        errno = EINVAL;
        return -1;
    }
    unsigned int flags = 0;
    if (fc_resolution_flags(resolution_policy, &flags) != 0) return -1;
    return renameatx_np(
        left_parent_fd,
        left_name,
        right_parent_fd,
        right_name,
        RENAME_SWAP | flags
    );
#endif
}

int fc_copy_regular_all(int source_fd, int destination_fd) {
    if (source_fd < 0 || destination_fd < 0) {
        errno = EINVAL;
        return -1;
    }
    return fcopyfile(source_fd, destination_fd, NULL, COPYFILE_ALL);
}

int fc_unlink_leaf(int parent_fd, const char *name, bool directory) {
    if (!fc_fs_valid_leaf(name)) {
        errno = EINVAL;
        return -1;
    }
    return unlinkat(parent_fd, name, directory ? AT_REMOVEDIR : 0);
}

int fc_lstatat_identity(int parent_fd, const char *name, fc_fs_identity *out) {
    if (out == NULL || !fc_fs_valid_leaf(name)) {
        errno = EINVAL;
        return -1;
    }
    struct stat st;
    if (fstatat(parent_fd, name, &st, AT_SYMLINK_NOFOLLOW) != 0) return -1;
    fc_fill_identity(&st, out);
    return 0;
}

int fc_fstat_identity(int fd, fc_fs_identity *out) {
    if (out == NULL) {
        errno = EINVAL;
        return -1;
    }
    struct stat st;
    if (fstat(fd, &st) != 0) return -1;
    fc_fill_identity(&st, out);
    return 0;
}
