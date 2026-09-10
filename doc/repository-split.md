# Why the work lives in two repositories

The board is described in one repository and ported in another.

| | [`dhb-ax-guide`](https://github.com/niallsmart/dhb-ax-guide) | `dhb-ax-buildroot` |
|---|---|---|
| Answers | What is this hardware, and how did the vendor drive it? | How do we boot mainline Linux on it? |
| Contents | Subsystem documentation, datasheets, the vendor SDK, board photographs, flash images | Buildroot external tree, device trees, kernel patch queue, board tooling |
| Output | Prose a kernel developer can act on | `uImage-hi3531-dhb-ax` |
| Standard of proof | Sourced and labelled by origin; can be wrong | Executable; boots or does not |
| Completion | Ends when the hardware is described | Maintained indefinitely |

## Why they are separate

* **Applicability.** The guide is intended to be useful to anyone holding this board, whatever they intend to run on it. 

* **Lifecycles.** This repository tracks kernel releases, Buildroot versions and a patch queue that gets rebased. The hardware will not change and so is documented separately.

## Which repository does a change belong in?

- A fact about the hardware that would remain true under any operating system goes in the guide.
- A patch, defconfig, device tree or script goes here.
- A workaround for a driver's behaviour goes here, in the patch or its comment. The hardware behaviour that forced the workaround goes in the guide.

## When the two disagree

Observed behaviour and/or a working implementation has priority over the guide. The guide should be corrected or adjusted in those scenarios.

