# PR #11 Residual Imported into This Package

Merged PR #11 reports that the descriptor-relative hardening passed its
focused suite but leaves E2 open because:

- final-component verification and mutation are separate syscalls;
- pathname anchoring is incomplete;
- destination hierarchy creation remains outside the secure capability;
- a hard-link ctime interval remains.

This package closes those items by replacing compare-then-mutate with
atomic capture/publish and by making root capabilities authoritative.
