# Telemetry and Metal remediation

## Telemetry history

Replace front-removal arrays with a fixed-capacity ring buffer. Append system history only when a new host sample is collected. Forge/MCP card recomposition may publish a new snapshot without inventing a second host point.

Separate:

- raw collector cadence;
- model/card recomposition cadence;
- GUI publication cadence;
- persistence cadence.

Coalesce unchanged frames and publish bounded snapshots.

## Gauge metrics

Track separate counts:

- allocated surfaces;
- window-attached surfaces;
- logically visible surfaces;
- surfaces currently drawing;
- draw calls and skipped frames.

Visibility follows window/tab/scroll lifecycle rather than attach count alone.

## Surface scale

The current Rig may create hundreds of native surfaces. Qwen Code must profile and choose a measured design:

- one or a small number of shared Metal canvases for dense grids;
- virtualization that creates surfaces only for visible rows;
- SwiftUI/Canvas rendering for low-complexity microgauges;
- shared renderer with explicit on-demand draw.

Do not remove gauge content. Hidden surfaces draw no recurring frames.

## Tests

- exact history count per host samples;
- ring-buffer wrap correctness;
- zero recurring hidden draw calls;
- surface counts track visible rows;
- memory pressure reduces cadence;
- 100-cycle navigation and resize stress;
- Metal trace demonstrates bounded command/buffer creation.
