# Why the work lives in two repositories

The board is described in one repository and ported in another.

| | [`dhb-ax-guide`](https://github.com/niallsmart/dhb-ax-guide) | `dhb-ax-buildroot` |
|---|---|---|
| Answers | What is this hardware, and how did the vendor drive it? | How do we boot mainline Linux on it? |
| Contents | Subsystem documentation, datasheets, the vendor SDK, board photographs, flash images | Buildroot external tree, device trees, kernel patch queue, board tooling |
| Output | Prose a kernel developer can act on | `uImage-hi3531-dhb-ax` |
| Standard of proof | Sourced and labelled by origin; can be wrong | Executable; boots or does not |
| Completion | Ends when the hardware is described | Maintained indefinitely |

Both are scoped to the same board — the TVT Digital `DHB_AX V1.2`, sold as the
LTS LTD2704XE-P — which is why both carry the `dhb-ax` prefix. Three names
apply to this hardware at different layers: the SoC (Hi3531), the PCB
silkscreen (`DHB_AX V1.2`) and the retail SKU (LTD2704XE-P). The board sits in
the middle and is the one both repositories share, so it anchors the naming.

## Why they are separate

The guide came first, and its founding constraint is stated in its own
`AGENTS.md`: document the hardware, and do not attempt the port. Three
properties keep the separation worthwhile.

**Different lifecycles.** The silicon and the PCB will not change. This
repository tracks kernel releases, Buildroot versions and a patch queue that
gets rebased. Binding documentation of fixed hardware to the churn of a build
tree means rewriting it for reasons unrelated to the hardware.

**Different standards of proof.** The guide reconstructs an undocumented board
from a datasheet, a vendor SDK, flash dumps and register reads. It carries a
five-level source hierarchy and a rule that every inference be labelled as one,
because much of it cannot be tested directly. This repository needs none of
that apparatus: code either binds to the hardware or it does not.

**Separability.** The guide is useful to anyone holding this board, whatever
they intend to run on it. This repository is one answer to one question.

There is also a failure mode the split avoids. A repository trying to make
something boot will document whatever made it boot, including the accidents. A
repository that only describes the hardware has to say where each claim comes
from.

## Which repository does a change belong in?

- A fact about the hardware that would remain true under any operating system
  goes in the guide.
- A patch, defconfig, device tree or script goes here.
- A measurement taken from a running system goes in the guide, with the kernel
  it was taken under recorded. Both the vendor 3.0.8 kernel and the mainline
  port boot on this board, and register state differs between them.
- A workaround for a driver's behaviour goes here, in the patch or its comment.
  The hardware behaviour that forced the workaround goes in the guide.

## When the two disagree

They are not equal sources. Results here are first-hand: a driver that binds
and a peripheral that carries traffic settle questions the guide can only
infer. Where they conflict, this repository is usually right, and the guide
should be corrected rather than the working source changed to match it.

Both `AGENTS.md` files state this from their own side.

## Shared reference assets

The board photographs (`pcb/`), the extracted vendor filesystem (`rootfs/`) and
the verified factory-flash images (`backups/`) live in the guide. They describe
the hardware rather than build it, and no build or board tooling here reads
them.

They are excluded from source control in both repositories and exist only on
local disk. `backups/` holds the only images of the factory SPI-NOR and NAND
contents, which cannot be recovered from either GitHub remote; back it up
separately.
