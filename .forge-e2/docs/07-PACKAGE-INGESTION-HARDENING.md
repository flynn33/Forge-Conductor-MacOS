# Package Ingestion Hardening

The autonomy plan requires immutable managed package storage. E2 closure
must apply to ingestion as well as model-facing filesystem tools.

## Rule

Never execute, validate deeply, or delete from the Finder-selected or
watched source location.

## Archive input

1. authorize and open the source through a read capability;
2. require a regular file;
3. use `O_UNIQUE` when supported to reject multi-link sources;
4. stream-copy from the descriptor into a managed private staging file;
5. `fstat` before and after copy;
6. compute SHA-256 while copying;
7. synchronize and publish by exclusive rename;
8. validate paths and manifests only from the immutable managed copy.

## Directory input

1. open the root by descriptor;
2. descriptor-walk without following symlinks;
3. copy into managed staging;
4. enforce limits for depth, entries, path bytes, total bytes, sparse
   expansion, extended attributes, and file types;
5. synchronize;
6. hash the resulting manifest;
7. publish the managed snapshot;
8. queue only the published content-addressed object.

## Source change behavior

If the source changes during snapshot:

- discard the private staging copy;
- return `package_source_changed`;
- retry under bounded policy;
- do not mutate the selected source.

## ZIP extraction

Use a library or a narrowly scoped extractor that validates every entry
before creation:

- no absolute paths;
- no `..`;
- no NUL;
- no path length overflow;
- no symlink or hard-link escape;
- no duplicate collision after Unicode/case normalization;
- no device/FIFO/socket entries;
- bounded compressed and expanded sizes;
- descriptor-relative creation under managed staging.

Do not rely solely on an archive library's destination-path
canonicalization.

## Completion

The queue receives only an immutable store hash and a validated manifest.
A model never scans an arbitrary watched directory to select work.
