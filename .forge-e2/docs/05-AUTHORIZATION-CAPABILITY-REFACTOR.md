# Authorization and Capability Refactor

## Current defect

`ToolAuthorizationService` canonicalizes paths and returns strings.
`FilesystemToolPack` later reopens those strings. That separation permits
namespace rebinding and prevents the router from proving which authorized
root actually supplied authority.

## Required refactor

### Step 1 — split policy from resolution

Policy decides:

- tool grant;
- project and generation;
- permitted root records;
- read or mutation access;
- workspace-root protection.

The secure filesystem authorizer decides:

- exact root identity;
- relative component list;
- descriptor pinning;
- security-scope lease.

### Step 2 — typed invocation

Change the internal router contract to carry
`AuthorizedToolInvocation`. Preserve the external MCP request and response
schemas.

Characterize every mock authorization service before changing the
protocol. Provide compatibility adapters only inside tests; do not fall
back to path authority in production.

### Step 3 — root migration

For legacy root records without identity:

1. resolve any existing bookmark;
2. open with strict flags;
3. capture identity;
4. persist the migration receipt before authorizing mutation;
5. bind it to the current project generation.

Never silently adopt a replacement at a previously recorded path when an
identity already exists.

### Step 4 — home read-only access

Keep the existing permitted-home read feature, but represent each permitted
home subtree as a read-only root capability. Denied secret/system prefixes
remain denied. Mutation tools never receive these capabilities.

### Step 5 — Git and runtime cwd

Git and runtime tools receive a verified root/cwd capability. They may
convert a security-scoped URL to a path only after access is active, because
the string itself does not carry sandbox scope. Record that subprocess
containment is not equivalent to descriptor confinement.

## Audit storage

Persist sanitized display paths and root IDs, not raw bookmark data,
descriptor numbers, or internal capability objects.
