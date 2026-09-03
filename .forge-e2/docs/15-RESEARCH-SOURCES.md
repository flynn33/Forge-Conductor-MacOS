# Primary Research Sources

Research was limited to Apple primary sources for Darwin/macOS filesystem
semantics.

## Apple XNU — current public headers and man pages

### `bsd/sys/fcntl.h`

Repository:

```text
https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/fcntl.h
```

Relevant definitions:

- `O_NOFOLLOW`
- `O_RESOLVE_BENEATH`
- `O_UNIQUE`
- `O_DIRECTORY`
- `O_CLOEXEC`
- `O_NOFOLLOW_ANY`
- `O_SEARCH`

### `bsd/man/man2/open.2`

```text
https://github.com/apple-oss-distributions/xnu/blob/main/bsd/man/man2/open.2
```

Relevant documented semantics:

- `openat` resolves a relative path from the supplied directory descriptor;
- `O_NOFOLLOW_ANY` rejects a symlink in any path component;
- `O_RESOLVE_BENEATH` fails when resolution escapes the starting
  descriptor;
- `O_UNIQUE` fails when a file has more than one hard link.

### `bsd/sys/stdio.h`

```text
https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/stdio.h
```

Relevant public declarations and flags:

- `renameatx_np`
- `RENAME_SWAP`
- `RENAME_EXCL`
- `RENAME_NOFOLLOW_ANY`
- `RENAME_RESOLVE_BENEATH`

### `bsd/man/man2/rename.2`

```text
https://github.com/apple-oss-distributions/xnu/blob/main/bsd/man/man2/rename.2
```

Relevant documented semantics:

- rename is atomic;
- final-component symlink rename acts on the link entry;
- source and destination must be on the same filesystem;
- `RENAME_EXCL` prevents replacement;
- no-follow and resolve-beneath flags constrain path resolution.

## Apple XNU tests

### `tests/vfs/resolve_beneath.c`

```text
https://github.com/apple-oss-distributions/xnu/blob/main/tests/vfs/resolve_beneath.c
```

The test suite exercises escaping `..`, absolute paths, escaping symlinks,
nested paths, and `ENOTCAPABLE`.

### `tests/vfs/open_unique.c`

```text
https://github.com/apple-oss-distributions/xnu/blob/main/tests/vfs/open_unique.c
```

The test demonstrates success with one link and `ENOTCAPABLE` after a
second hard link is created.

## Apple Developer Documentation

### Security-scoped bookmarks and file-ID preference

```text
https://developer.apple.com/documentation/foundation/nsurl/bookmarkcreationoptions/preferfileidresolution
https://developer.apple.com/documentation/foundation/nsurl/bookmarkcreationoptions/withsecurityscope
```

Use bookmarks to recover user-selected roots and prefer their embedded file
identity. A resolved security-scoped URL must be actively accessed, and
start/stop calls must be balanced.


## Apple `copyfile(3)` manual

```text
https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man3/copyfile.3.html
```

The documented `fcopyfile` form copies from and to already-open file
descriptors. `COPYFILE_ALL` covers file data plus POSIX metadata, ACLs, and
extended attributes. Forge may use it for a captured regular file, but must
still create both descriptors through the secure broker, apply bounded
cancellation policy, synchronize the destination, and independently verify
the copied identity/content manifest before publication. The path-based
`copyfile` form is not mutation authority.

## Research limits

The public sources do not provide a compare-by-inode conditional unlink or
rename. The implementation therefore must not claim one exists. Atomic
capture plus validate/restore/quarantine is the supported design.
