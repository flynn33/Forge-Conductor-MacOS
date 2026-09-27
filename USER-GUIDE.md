# Forge Conductor user guide

Version **0.16.0**, build **17**.

This guide describes the current LM Studio-driven workflow. The user works in a
normal LM Studio chat; Forge Conductor supplies project context, tools, policy
governance, memory, and automatic continuity.

## 1. Start Forge Conductor

Open Forge Conductor and confirm that **Manager** is running. Manager owns the
authenticated local control boundary, project registry, provider preparation,
policy services, and automatic continuity watchdog.

If a Provider action reports a Manager transport or authentication failure,
use the Manager surface to start or repair the current-build Manager, then
repeat the Provider action. Forge reports that condition separately from an LM
Studio connection or model error.

## 2. Connect LM Studio

1. Open LM Studio and load the model you intend to use.
2. In Forge Conductor, open **Provider**.
3. Select **LM Studio**.
4. Choose **Connect and Check**.

Provider selection, **Connect and Check**, the Advanced connection check, and
the probe use the same preparation path. For same-host LM Studio, the check
authenticates only to Forge Manager and uses LM Studio's private loopback server
without an operator login or token. It performs bounded supported-CLI recovery,
discovers loaded models, resolves the configured model, validates the tool
contract, and saves a readiness receipt.

Forge does not load a model on the user's behalf and does not scan arbitrary
ports. Local Advanced settings expose endpoint and model but no token field.
Linked HTTPS providers retain an optional credential control. Saving is allowed
while LM Studio is offline; live readiness still requires **Connect and Check**.

## 3. Select projects

Open **Projects** and use the folder picker to select one or more project
folders. Each registered folder receives a stable project ID and generation.
Project files, memory, instructions, policy observations, and continuity remain
isolated by that identity.

Available maintenance actions include:

- relink a moved project folder;
- remove a project registration;
- reset the selected project's generation;
- clear selected project content; and
- **Clear Cache…**, which removes only disposable Forge cache data.

Destructive actions require confirmation. Cache clearing preserves projects,
instructions, policy, memory, credentials, and continuity.

## 4. Add and order instruction packages

Use **Add Instructions…** to select one or more files, folders, ZIP archives, or
supported packages. Selected packages appear in an ordered frame.

- Drag package rows to change their priority.
- Use **Move earlier** or **Move later** for keyboard-accessible ordering.
- Choose **Delete Package** to remove the selected package.

The displayed order is durable and authoritative. The model observes the
latest committed order on its next instruction-catalog query. Adding or
ordering packages does not start a model session.

See [instruction packages](docs/INSTRUCTION-PACKAGES.md) for accepted formats
and storage limits.

## 5. Add Development Policy in Rune Forge

Open **Rune Forge** and choose **Add Development Policy…**. Select one or more
files or folders. The selected sources appear in an ordered frame.

- Drag sources to set their order of importance.
- Use explicit earlier/later controls when needed.
- Remove only the selected source with its delete action.

CLU is the governance-enforcement agent. It monitors model observations against
the ordered policy, records a separate bounded log for each project, and sends
the model a structured notice containing the exact violated policy identity and
applicable policy content. CLU does not take over task execution.

Use Rune Forge export controls to write the selected project's log as JSONL,
JSON, Markdown, or CSV.

## 6. Start work in LM Studio

Open a normal chat in LM Studio. Ask the model to call:

```text
get_forge_status
```

The result lists registered project IDs and the query tools and locations for
project files, ordered instructions, and continuity. If more
than one project is registered, have the model pass the applicable
`project_id` on later calls. Then give the model the task in LM Studio as usual.

Forge Conductor does not start this work through a Managed Run.

## 7. Automatic continuity

The model can save compact checkpoints while it works. At context pressure it
saves a resume-ready handoff. Continuity then proceeds without an operator
action in the Continuity view:

1. Forge durably commits the exact handoff.
2. Dashboard shows a 30-second countdown.
3. At expiry Manager creates exactly one stored successor chat through LM
   Studio's supported stateful-chat API.
4. Forge submits:

   ```text
   get_forge_status
   resume=true
   ```

5. The successor must acknowledge the exact handoff identifier.
6. Forge records the predecessor as sealed only after that acknowledgement.

The operation is idempotent across watchdog ticks and Manager restart. A
failure retains the handoff and reports the exact endpoint, authentication,
model, MCP, bootstrap, or acknowledgement problem.

LM Studio's public API supports stored stateful chats but does not promise that
an API-created chat becomes the foreground GUI tab. Forge does not use private
UI automation.

## 8. Manage continuity data

The **Continuity** view contains:

- a scrollable list of project IDs that have continuity data;
- project selection;
- **Copy Project ID**;
- a packet list under the selected project showing each checkpoint/handoff ID,
  type, source, and timestamp;
- one confirmed **Delete** action that removes only the selected packet or
  multi-selection;
- **Reset** for the selected project's settled automatic continuity history;
- **Clear Cache** for disposable Forge cache data.

There are no checkpoint, rollover, run-selection, timeline, or recovery
controls on this screen. The maintenance controls are directly usable on
Continuity without opening Projects. Packet deletion does not remove other
packets, ordinary project files, instruction packages, policy, credentials, or
project memory. Reset does not advance the project generation, and durable
packets remain until explicitly selected and deleted. Instruction-package
deletion remains on Projects.

## 9. Read Dashboard and evidence

Dashboard presents bounded system telemetry, Forge service health, policy
state, and the automatic continuity countdown. Hidden gauges stop recurring
render work. Events & Evidence provides bounded diagnostics and exports; it
does not replace live provider or rollover acceptance.

## 10. Verification boundary

A green source build proves compilation. A focused unit or UI test proves only
its selected behavior. Release acceptance separately requires the current
signed candidate to pass the complete owner workflow against the owner's
running LM Studio configuration, plus signing, notarization, Gatekeeper,
privileged-service, hardware, and owner acceptance gates recorded in
[ROADMAP.md](ROADMAP.md).
