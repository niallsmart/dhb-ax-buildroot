Repository root: `{{REPO_ROOT}}`.

Resolve all project paths against this directory and set command working directories explicitly. Keep file inspection within this repository; do not search the home directory to locate it.

# Goal

Recommend a setting for the Linux kernel symbol `{{CONFIG_NAME}}` for this project.

This project ports mainline Linux to the LTS LTD2704XE-P DVR, which uses the HiSilicon Hi3531 SoC on a TVT DHB_AX V1.2 motherboard. It is a headless ARMv7 system. 

Buildroot supplies the kernel and recovery initramfs; Debian armhf supplies the persistent server userspace.

Intended workloads under Debian for this device include:

* Home Assistant
* Network Attached Storage
* Software Development
* TailNet Exit Node

# Guidelines

Before recommending changes to architecture, memory, or boot settings, verify the relevant board-specific constraints in the device tree and project documentation; do not infer them from generic ARM defaults.

Evaluate the setting against boot requirements, hardware, and the intended workloads.

Do not use `doc/linux-defconfig-review.md`, review spreadsheets, or previous audit results as evidence.

Do not edit files, build, stage, boot, or access the DVR.

Do not consult files under `{{REPO_ROOT}}/tools/audit-defconfig/` (this folder).

Do not examine `{{REPO_ROOT}}/artifacts/` or `{{REPO_ROOT}}/doc/`, including their contents in searches. Read access to these directories is denied for this audit project.

Do not consult the Linux source code files (`*.c`, `*.h`).

# Output

Return only the structured result required by the supplied schema: an object containing a `recommendations` array. Include one row for `{{CONFIG_NAME}}` and additional rows for dependencies when needed. Each row has the following fields:

- `config`: `{{CONFIG_NAME}}` for the main recommendation, or the dependency's full `CONFIG_` symbol name. Include each symbol only once.
- `description`: User-facing explanation of what this symbol controls.
- `recommended_setting`: Recommended literal Kconfig value, expressed as a JSON string. Use `y`, `m`, or `n` for boolean/tristate values; preserve numeric/hex syntax and include the Kconfig double quotes for string values. `n` means `# CONFIG_… is not set`. Use `remove` only when the symbol is obsolete or an explicit setting is unnecessary based on Kconfig semantics and project requirements; removing a line defers to defaults and dependencies and does not explicitly disable the symbol.
- `rationale`: Concise justification for your recommendation. Omit superfluous implementation details. For `remove`, explain why an explicit setting is unnecessary. State any assumptions underlying the recommendation.
