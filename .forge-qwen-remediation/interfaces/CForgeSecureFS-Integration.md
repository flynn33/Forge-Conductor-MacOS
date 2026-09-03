# CForgeSecureFS integration boundary

Use the C target only for narrow public Darwin API operations that Swift cannot express safely or ergonomically. Policy, project/generation authority, transaction persistence, recovery, and user-facing errors remain in Swift actors.

Required C operations should expose typed return codes and never allocate unbounded memory:

- open a descriptor-bound root with no-follow/beneath constraints;
- atomically capture a named entry into a private transaction directory;
- exclusively publish a staged entry;
- atomically swap for compare/replace workflows where supported;
- query volume rename/copy capabilities;
- copy regular-file data between descriptors with bounded buffers;
- synchronize file and directory descriptors;
- return `errno` and structured operation stage.

No C function accepts an unrestricted absolute path after the root capability is established. All relative names are validated as single components or prevalidated component arrays.
