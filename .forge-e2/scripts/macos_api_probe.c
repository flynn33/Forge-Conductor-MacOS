#include <copyfile.h>
#include <errno.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#ifndef O_RESOLVE_BENEATH
#error O_RESOLVE_BENEATH is unavailable in the selected public SDK
#endif
#ifndef O_NOFOLLOW_ANY
#error O_NOFOLLOW_ANY is unavailable in the selected public SDK
#endif
#ifndef O_UNIQUE
#error O_UNIQUE is unavailable in the selected public SDK
#endif
#ifndef RENAME_EXCL
#error RENAME_EXCL is unavailable in the selected public SDK
#endif
#ifndef RENAME_NOFOLLOW_ANY
#error RENAME_NOFOLLOW_ANY is unavailable in the selected public SDK
#endif
#ifndef RENAME_RESOLVE_BENEATH
#error RENAME_RESOLVE_BENEATH is unavailable in the selected public SDK
#endif
#ifndef RENAME_SWAP
#error RENAME_SWAP is unavailable in the selected public SDK
#endif

static char root_path[] = "/private/tmp/forge-e2-probe.XXXXXX";
static int root_fd = -1;
static int inside_fd = -1;

static void cleanup(void) {
    if (inside_fd >= 0) {
        const char *entries[] = {
            "a", "a2", "b", "outside-link", "link-moved", "link",
            "symlink-target", "escape-source", "escaped", "parent-link",
            "copy-dst"
        };
        for (size_t i = 0; i < sizeof(entries) / sizeof(entries[0]); ++i) {
            (void)unlinkat(inside_fd, entries[i], 0);
        }
        (void)close(inside_fd);
        inside_fd = -1;
    }
    if (root_fd >= 0) {
        (void)unlinkat(root_fd, "outside", 0);
        (void)unlinkat(root_fd, "escape-destination", 0);
        (void)unlinkat(root_fd, "inside", AT_REMOVEDIR);
        (void)close(root_fd);
        root_fd = -1;
    }
    (void)rmdir(root_path);
}

static void fail(const char *message) {
    const int saved = errno;
    cleanup();
    errno = saved;
    perror(message);
    exit(1);
}

static int create_file_at(int parent, const char *name, const char *bytes) {
    int fd = openat(parent, name, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC, 0600);
    if (fd < 0) return -1;
    if (bytes != NULL) {
        const size_t length = strlen(bytes);
        if (write(fd, bytes, length) != (ssize_t)length) {
            const int saved = errno;
            close(fd);
            errno = saved;
            return -1;
        }
        if (fsync(fd) != 0) {
            const int saved = errno;
            close(fd);
            errno = saved;
            return -1;
        }
    }
    return close(fd);
}

static bool expected_confinement_errno(int value) {
    return value == ENOTCAPABLE || value == ELOOP;
}

int main(void) {
    if (atexit(cleanup) != 0) fail("atexit");
    if (mkdtemp(root_path) == NULL) fail("mkdtemp");

    root_fd = open(root_path, O_SEARCH | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY);
    if (root_fd < 0) fail("open root");
    if (mkdirat(root_fd, "inside", 0700) != 0) fail("mkdirat inside");
    inside_fd = openat(
        root_fd,
        "inside",
        O_SEARCH | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY | O_RESOLVE_BENEATH
    );
    if (inside_fd < 0) fail("openat inside");
    if (create_file_at(root_fd, "outside", "outside-sentinel") != 0) fail("create outside");

    // Beneath rejects direct parent escape.
    int fd = openat(inside_fd, "../outside", O_RDONLY | O_CLOEXEC | O_RESOLVE_BENEATH);
    if (fd >= 0 || errno != ENOTCAPABLE) {
        if (fd >= 0) close(fd);
        fprintf(stderr, "O_RESOLVE_BENEATH escape test failed; errno=%d\n", errno);
        return 2;
    }

    // No-follow-any rejects an intermediate symlink even if it could otherwise resolve.
    if (symlinkat("..", inside_fd, "parent-link") != 0) fail("symlink parent-link");
    fd = openat(
        inside_fd,
        "parent-link/outside",
        O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY | O_RESOLVE_BENEATH
    );
    if (fd >= 0 || !expected_confinement_errno(errno)) {
        if (fd >= 0) close(fd);
        fprintf(stderr, "O_NOFOLLOW_ANY intermediate symlink test failed; errno=%d\n", errno);
        return 3;
    }
    if (unlinkat(inside_fd, "parent-link", 0) != 0) fail("unlink parent-link");

    // Unique-open behavior for hard links.
    if (create_file_at(inside_fd, "a", "alpha") != 0) fail("create a");
    fd = openat(inside_fd, "a", O_RDONLY | O_CLOEXEC | O_UNIQUE);
    if (fd < 0) fail("O_UNIQUE single-link open");
    close(fd);
    if (linkat(inside_fd, "a", inside_fd, "a2", 0) != 0) fail("linkat a2");
    fd = openat(inside_fd, "a", O_RDONLY | O_CLOEXEC | O_UNIQUE);
    if (fd >= 0 || errno != ENOTCAPABLE) {
        if (fd >= 0) close(fd);
        fprintf(stderr, "O_UNIQUE did not reject multi-link file; errno=%d\n", errno);
        return 4;
    }
    if (unlinkat(inside_fd, "a2", 0) != 0) fail("unlink a2");

    // Exclusive publication and identity swap.
    if (create_file_at(inside_fd, "b", "bravo") != 0) fail("create b");
    struct stat a_before = {0};
    struct stat b_before = {0};
    struct stat a_after = {0};
    struct stat b_after = {0};
    if (fstatat(inside_fd, "a", &a_before, AT_SYMLINK_NOFOLLOW) != 0) fail("stat a before");
    if (fstatat(inside_fd, "b", &b_before, AT_SYMLINK_NOFOLLOW) != 0) fail("stat b before");
    if (renameatx_np(
            inside_fd, "a", inside_fd, "b",
            RENAME_EXCL | RENAME_NOFOLLOW_ANY | RENAME_RESOLVE_BENEATH
        ) == 0 || errno != EEXIST) {
        fprintf(stderr, "RENAME_EXCL did not reject existing destination; errno=%d\n", errno);
        return 5;
    }
    if (renameatx_np(
            inside_fd, "a", inside_fd, "b",
            RENAME_SWAP | RENAME_NOFOLLOW_ANY | RENAME_RESOLVE_BENEATH
        ) != 0) fail("rename swap");
    if (fstatat(inside_fd, "a", &a_after, AT_SYMLINK_NOFOLLOW) != 0) fail("stat a after");
    if (fstatat(inside_fd, "b", &b_after, AT_SYMLINK_NOFOLLOW) != 0) fail("stat b after");
    if (a_after.st_ino != b_before.st_ino || b_after.st_ino != a_before.st_ino) {
        fprintf(stderr, "RENAME_SWAP did not exchange identities\n");
        return 6;
    }

    // Resolve-beneath must reject source and destination escape in rename.
    if (create_file_at(inside_fd, "escape-source", "escape") != 0) fail("create escape-source");
    if (renameatx_np(
            inside_fd, "../outside", inside_fd, "escaped",
            RENAME_EXCL | RENAME_RESOLVE_BENEATH
        ) == 0 || errno != ENOTCAPABLE) {
        fprintf(stderr, "rename source escape was not rejected; errno=%d\n", errno);
        return 7;
    }
    if (renameatx_np(
            inside_fd, "escape-source", inside_fd, "../escape-destination",
            RENAME_EXCL | RENAME_RESOLVE_BENEATH
        ) == 0 || errno != ENOTCAPABLE) {
        fprintf(stderr, "rename destination escape was not rejected; errno=%d\n", errno);
        return 8;
    }

    // Measure strict final-symlink behavior. When strict flags reject the final link,
    // prove that leaf-only descriptor rename moves the link entry itself.
    if (create_file_at(inside_fd, "symlink-target", "target") != 0) fail("create symlink target");
    if (symlinkat("symlink-target", inside_fd, "link") != 0) fail("create final symlink");
    bool strict_final_symlink_supported = false;
    int strict_symlink_errno = 0;
    if (renameatx_np(
            inside_fd, "link", inside_fd, "link-moved",
            RENAME_EXCL | RENAME_NOFOLLOW_ANY | RENAME_RESOLVE_BENEATH
        ) == 0) {
        strict_final_symlink_supported = true;
    } else {
        strict_symlink_errno = errno;
        if (!expected_confinement_errno(errno) && errno != EINVAL) {
            fprintf(stderr, "unexpected strict final-symlink errno=%d\n", errno);
            return 9;
        }
        if (renameatx_np(inside_fd, "link", inside_fd, "link-moved", RENAME_EXCL) != 0) {
            fail("leaf-only final symlink rename");
        }
    }
    struct stat moved_link = {0};
    if (fstatat(inside_fd, "link-moved", &moved_link, AT_SYMLINK_NOFOLLOW) != 0) {
        fail("stat moved link");
    }
    if ((moved_link.st_mode & S_IFMT) != S_IFLNK) {
        fprintf(stderr, "final symlink target was followed instead of moving link entry\n");
        return 10;
    }

    // Descriptor-to-descriptor regular-file copy preserves the metadata contract
    // without reopening a model-controlled path.
    int copy_source = openat(inside_fd, "a", O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY);
    if (copy_source < 0) fail("open copy source");
    int copy_destination = openat(
        inside_fd, "copy-dst", O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC | O_NOFOLLOW_ANY, 0600
    );
    if (copy_destination < 0) fail("open copy destination");
    if (fcopyfile(copy_source, copy_destination, NULL, COPYFILE_ALL) != 0) {
        fail("fcopyfile");
    }
    struct stat copy_source_stat = {0};
    struct stat copy_destination_stat = {0};
    if (fstat(copy_source, &copy_source_stat) != 0) fail("stat copy source");
    if (fstat(copy_destination, &copy_destination_stat) != 0) fail("stat copy destination");
    if (copy_source_stat.st_size != copy_destination_stat.st_size) {
        fprintf(stderr, "fcopyfile size mismatch\n");
        return 11;
    }
    if (fsync(copy_destination) != 0) fail("fsync copy destination");
    close(copy_source);
    close(copy_destination);

    if (fsync(inside_fd) != 0) fail("fsync inside directory");
    if (fsync(root_fd) != 0) fail("fsync root directory");

    printf(
        "{\"ok\":true,\"strict_final_symlink_rename\":%s,"
        "\"strict_final_symlink_errno\":%d,\"root\":\"%s\"}\n",
        strict_final_symlink_supported ? "true" : "false",
        strict_symlink_errno,
        root_path
    );
    return 0;
}
