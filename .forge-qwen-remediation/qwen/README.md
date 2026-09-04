# Qwen customization assets

This directory is installed with the remediation package.

- `settings.template.json` documents the repository-local Qwen Code settings shape.
- `work-package-cards/` contains one compact context card for each P00–P14 work package.
- The authoritative machine-readable work plan remains `plans/work-packages.json`.
- The current card is selected into `.forge-qwen-state/current-task.md`; cards do not replace durable state or gate validators.

