#ifndef C_FORGE_SECURE_FS_H
#define C_FORGE_SECURE_FS_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/stat.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    int error_number;
    uint64_t device;
    uint64_t inode;
    uint32_t mode;
    uint32_t owner;
    uint32_t group;
    uint64_t link_count;
    int64_t size;
    int64_t modified_seconds;
    int64_t modified_nanoseconds;
    int64_t changed_seconds;
    int64_t changed_nanoseconds;
} fc_fs_identity;

typedef struct {
    bool has_open_resolve_beneath;
    bool has_open_no_follow_any;
    bool has_open_unique;
    bool has_rename_exclusive;
    bool has_rename_no_follow_any;
    bool has_rename_resolve_beneath;
    bool has_rename_swap;
} fc_fs_api_capabilities;

typedef enum {
    FC_FS_RENAME_LEAF_ONLY = 0,
    FC_FS_RENAME_STRICT_RESOLUTION = 1
} fc_fs_rename_resolution_policy;

fc_fs_api_capabilities fc_fs_compile_time_capabilities(void);
bool fc_fs_valid_leaf(const char *name);

int fc_open_search_root(const char *absolute_path);
int fc_open_directory_beneath(int parent_fd, const char *relative_component);
int fc_open_regular_beneath(
    int parent_fd,
    const char *relative_component,
    bool reject_any_symlink,
    bool require_unique_link
);
int fc_mkdirat_component(int parent_fd, const char *name, uint32_t mode);
int fc_rename_exclusive_leaf(
    int source_parent_fd,
    const char *source_name,
    int destination_parent_fd,
    const char *destination_name,
    fc_fs_rename_resolution_policy resolution_policy
);
int fc_rename_swap_leaf(
    int left_parent_fd,
    const char *left_name,
    int right_parent_fd,
    const char *right_name,
    fc_fs_rename_resolution_policy resolution_policy
);
int fc_copy_regular_all(int source_fd, int destination_fd);
int fc_unlink_leaf(int parent_fd, const char *name, bool directory);
int fc_lstatat_identity(int parent_fd, const char *name, fc_fs_identity *out);
int fc_fstat_identity(int fd, fc_fs_identity *out);

#ifdef __cplusplus
}
#endif

#endif
