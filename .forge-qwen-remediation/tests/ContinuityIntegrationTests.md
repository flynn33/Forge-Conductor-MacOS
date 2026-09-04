# Continuity integration tests

## Authority tests

- managed autonomous calls never consult global latest handoff;
- managed autonomous calls never enter the legacy fixed-count tool blocker;
- managed responses never instruct the operator to open a new chat;
- external compatibility mode can still produce a project-bound handoff and truthful limitation;
- a client bound to project A cannot load project B's latest handoff;
- old-generation handoffs cannot acknowledge a current rollover.

## Real provider forced rollover

Use a locally loaded LM Studio model and a low test threshold:

1. manager starts a project/package run;
2. provider executes at least one real tool call;
3. context observation reaches threshold without model request;
4. predecessor admission closes;
5. handoff persists;
6. fresh root is created without predecessor continuation identity;
7. successor receives acknowledgment-only authority;
8. exact project/generation/run/operation/handoff/checksum/nonce acknowledgment succeeds;
9. one successor is accepted;
10. predecessor tools are denied;
11. automatic continuation advances package work;
12. GUI remains closed.

## Crash matrix

Terminate manager after each durable rollover state. Recovery must accept no duplicate successor authority and issue continuation at most once.
