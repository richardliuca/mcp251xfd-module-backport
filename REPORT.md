# Backporting the mcp251xfd CAN driver to kernel 4.9 (Jetson Nano)

This document explains, in plain language:

1. **What "backporting" means** and why this driver needed it.
2. **What was changed** in each source file, and why — with the original and
   the replacement side by side.
3. **How you compile and load the module** on your Jetson Nano (2 GB,
   JetPack 4.6, kernel `4.9.337-tegra`), step by step.

The driver itself lives in this directory (`mcp251xfd-core.c`,
`mcp251xfd-regmap.c`, `mcp251xfd-crc16.c`, `mcp251xfd.h`, `Makefile`,
`Kconfig`). It supports the Microchip **MCP2515FD / 2516FD / 2517FD / 2518FD**
SPI CAN-FD controller chips. The `src-5.10/` subfolder is an untouched copy of
the original driver for reference; `analysis.md` is the detailed audit that
listed every incompatible API. You never need to touch those to build.

---

## Section 1 — What backporting means, and why it was needed

### A little vocabulary first

- **A driver** is a piece of software that tells the operating system how to
  talk to a specific hardware chip. This one teaches the Linux kernel how to
  talk to an MCP251XFD CAN controller chip connected over the SPI bus.
- **The kernel** (in your case version `4.9.337-tegra`) is the core of Linux
  that runs on the Nano. It exposes a large set of C functions — called the
  **kernel API** — that drivers use to allocate memory, log messages, register
  network devices, and so on.
- **A kernel module** is a driver compiled as a separate file (with a `.ko`
  extension) that can be loaded into a running kernel without rebooting.
  Think of it like a plugin.
- **Out-of-tree** means the driver's source lives in its own folder (here:
  `~/mcp251xfd-backport/`) instead of inside the kernel's source tree.
  "In-tree" drivers are the ones shipped inside the kernel itself. Out-of-tree
  drivers are compiled *against* the installed kernel's header files, which is
  exactly what you will do.
- **Kernel headers** (`linux-headers-4.9.337-tegra`) are the C declaration
  files that describe the kernel's API. They are what the compiler needs to
  build any module; they are not the kernel itself.
- **Probe** is the function the kernel calls when it notices new hardware
  ("hey, an SPI chip with this ID just appeared — can you drive it?"). A
  driver's probe function does the setup: read the chip's config, request the
  interrupt line, create the network interface you'll see as `can0`.
- **Kconfig** is the kernel's build-configuration system — a menu of
  "build this driver or not" switches. Each driver ships a small Kconfig file
  declaring its switch. You don't need Kconfig to build out-of-tree; ours is
  included for completeness.

### Why the 5.10 driver cannot compile on 4.9

The MCP251XFD driver entered the official Linux kernel in version **5.10**
(December 2020). It was written and reviewed against 5.10's kernel API — it
calls functions, includes header files, and uses helper macros that simply
**do not exist** in the older 4.9 API that your Nano runs (4.9 is from
December 2016; NVIDIA has kept it alive with patches, but the CAN and SPI
subsystems it uses are essentially the 4.9 versions).

When you try to compile a 5.10 driver against 4.9 headers, the compiler fails
with errors like `implicit declaration of function 'can_rx_offload_enable'`
or `linux/can/rx-offload.h: No such file or directory`. Those are not bugs in
your setup — the driver is asking the kernel for tools that its age doesn't
have.

### The general backport strategy

Backporting is the process of making newer driver code work on an older
kernel. The method used here (and in almost all real-world backports) is:

1. **Take a pristine copy** of the driver at the version it first appeared
   (v5.10) — not the latest version, which would pull in years of further
   API changes.
2. **Audit every external symbol** the driver uses (there were 346 unique
   kernel functions, macros and headers) and check each one against the 4.9
   API. This produced `analysis.md`: exactly **13 gaps**, all of them
   mechanical. (The audit works at the *symbol* level; four smaller gaps at
   the *struct member* level — Section 2.1, A10–A13 — only surfaced when
   the module was first compiled against the real 4.9 headers.)
3. **Replace each missing symbol** with the 4.9 equivalent — the older
   function that does the same job. Example: 5.10's convenience function
   `dev_err_probe()` logs an error *and* returns an error code in one call;
   4.9 predates it, so it's replaced by the older two-line pattern:
   `dev_err(...)` followed by `return -ENXIO;`. The behavior you see is
   identical.
4. **If a whole feature is newer than 4.9** and has no 4.9 equivalent, you
   either re-implement its behavior with older primitives (which is what
   happened for CAN receive handling — see Section 2) or drop it and accept
   the functional difference (documented honestly below).
5. **Make it buildable out-of-tree**: the 5.10 Makefile only makes sense
   *inside* the kernel tree, so it's rewritten to build from your own folder
   against the installed headers (Section 3 shows the commands).

Every replacement in this project was verified to exist in a genuine 4.9
kernel source tree (the v4.9 git tag, not a snippet from the web), and the
reference copy in `src-5.10/` was verified byte-identical to the official
v5.10 tag — so "original" in Section 2 really means the upstream original.
The complete module was additionally compiled end-to-end against a clean
v4.9 kernel tree: zero errors, zero warnings from the driver code.

---

## Section 2 — What was changed, and why

Four files differ from the 5.10 original. Three of them are substantive
(`mcp251xfd-core.c`, `mcp251xfd.h`, `Makefile`), one is a cosmetic tidy-up
(`Kconfig`), and two are byte-identical to the original
(`mcp251xfd-regmap.c`, `mcp251xfd-crc16.c`).

For each change you get: **(a) the original code, (b) the replacement,
(c) the one-sentence reason.**

### 2.1 `mcp251xfd-core.c` — the main driver logic

This file had 13 changes, in three families:
**(A)** removing the CAN "RX offload" framework (a 5.10-only feature) and
using the older CAN API instead — 7 changes; **(B)** two small API
swaps (A6, A7) — 2 changes; and **(C)** four SPI struct-member fixes
(A10–A13) — 4 changes, found at compile time because struct members are
invisible to a symbol-level audit.

#### A1. Completing a transmitted frame — `mcp251xfd_handle_tefif()`

When the chip finishes sending a frame, the driver must tell userspace that
the frame is done so its memory can be reused.

**(a) Original (5.10):**
```c
stats->tx_bytes +=
    can_rx_offload_get_echo_skb(&priv->offload,
                    mcp251xfd_get_tef_tail(priv),
                    hw_tef_obj->ts);
```
**(b) Replacement:**
```c
stats->tx_bytes +=
    can_get_echo_skb(priv->ndev, mcp251xfd_get_tef_tail(priv));
```
**(c) Why:** `can_rx_offload_get_echo_skb()` belongs to the RX offload
framework that first landed in 5.10; the older `can_get_echo_skb()` has done
this job since the CAN subsystem's early days and is present in 4.9. The
third argument (the hardware timestamp) is gone because the older function
doesn't record one — see "feature dropped" at the end of this section.

#### A2. Receiving a normal data frame — `mcp251xfd_handle_rxif()`

When a CAN frame arrives, the driver packages it into a kernel "skb"
(socket buffer) and hands it to the network stack.

**(a) Original (5.10):**
```c
err = can_rx_offload_queue_sorted(&priv->offload, skb, hw_rx_obj->ts);
if (err)
    stats->rx_fifo_errors++;
```
**(b) Replacement:**
```c
netif_receive_skb(skb);
```
**(c) Why:** 4.9 has no offload queue to hand the frame to, so the frame goes
straight to the kernel's network stack via `netif_receive_skb()` — the
classic, twenty-year-old "deliver a received packet" call present in every
kernel. The `rx_fifo_errors++` counter is removed because with the older path
the network core counts drops itself. The local variable `int err;` declared
at the top of the function was deleted as well, since nothing assigns it
anymore.

#### A3. The same replacement, three more places

The identical "queue to offload → `netif_receive_skb()`" swap was applied to
the other three receive paths in this file, because the 5.10 driver funnels
*everything* through the offload framework:

- RX **error frames** (bus errors reported as CAN error frames) in
  `mcp251xfd_handle_rxif()`;
- RX **overflow notifications** (chip's receive FIFO ran full) in
  `mcp251xfd_handle_rxif()`;
- CERR **bus error frames** in `mcp251xfd_handle_cerrif()` — where the now
  unused local `struct net_device_stats *stats` was also deleted.

**(c) Why (all three):** same as A2 — the framework doesn't exist in 4.9, the
older delivery call does.

#### A4. Enabling the offload when the interface comes up — `mcp251xfd_register()`

**(a) Original (5.10):**
```c
can_rx_offload_enable(&priv->offload);
```
…and if the interrupt registration right after it failed:
```c
goto out_can_rx_offload_disable;
```
with the label further down:
```c
out_can_rx_offload_disable:
    can_rx_offload_disable(&priv->offload);
```
**(b) Replacement:** the `can_rx_offload_enable()` call is deleted; the error
jump now goes straight to the pre-existing label instead:
```c
goto out_transceiver_disable;
```
… and the whole `out_can_rx_offload_disable:` label with its
`can_rx_offload_disable()` is removed.

**(c) Why:** there is no longer an offload object to enable or disable, so
the error path simply skips that cleanup step and continues with the next
existing one.

#### A5. Disabling the offload when the interface goes down

**(a) Original (5.10)** (inside the unregister path):
```c
can_rx_offload_disable(&priv->offload);
```
**(b) Replacement:** line deleted.
**(c) Why:** same as A4 — nothing to disable.

#### A6. Missing interrupt line — `mcp251xfd_probe()`

**(a) Original (5.10):**
```c
if (!spi->irq)
    return dev_err_probe(&spi->dev, -ENXIO,
                 "No IRQ specified (maybe node \"interrupts-extended\" in DT missing)!\n");
```
**(b) Replacement:**
```c
if (!spi->irq) {
    dev_err(&spi->dev, "No IRQ specified (maybe node \"interrupts-extended\" in DT missing)!\n");
    return -ENXIO;
}
```
**(c) Why:** `dev_err_probe()` (log + return in one call) was introduced in
v5.10; 4.9 uses the older log-then-return pattern, which produces exactly the
same kernel log message.

#### A7. Looking up which chip variant you have — `mcp251xfd_probe()`

**(a) Original (5.10):**
```c
match = device_get_match_data(&spi->dev);
```
**(b) Replacement:**
```c
match = of_device_get_match_data(&spi->dev);
```
**(c) Why:** `device_get_match_data()` is a generic helper added in v5.10;
4.9 has the older `of_`-prefixed version, which reads the match data from the
Device Tree — which is how the Nano identifies this chip anyway, so behavior
is identical.

#### A8. Registering the offload at probe time — `mcp251xfd_probe()`

**(a) Original (5.10):**
```c
err = can_rx_offload_add_manual(ndev, &priv->offload,
                    MCP251XFD_NAPI_WEIGHT);
if (err)
    goto out_free_candev;
```
**(b) Replacement:** block deleted.
**(c) Why:** this registers the offload object with the CAN framework; the
object no longer exists in the 4.9 build.

#### A9. Removing the offload at unprobe — `mcp251xfd_remove()`

**(a) Original (5.10):**
```c
can_rx_offload_del(&priv->offload);
```
**(b) Replacement:** line deleted.
**(c) Why:** the mirror image of A8 — nothing to unregister.

### C. SPI struct-member fixes (found at first compile against the 4.9 headers)

Four more differences turned up when the module was first compiled against
the real 4.9 header set. None of them shows up in a symbol-level audit:
they are *members* of kernel structs (or flags) that 4.9's SPI subsystem
doesn't have yet. Each fix keeps the original behavior as faithfully as
4.9 allows.

#### A10. The chip-select delay — `mcp251xfd_tx_ring_init_tx_obj()`

**(a) Original (5.10):**
```c
xfer->cs_change = 1;
xfer->cs_change_delay.value = 0;
xfer->cs_change_delay.unit = SPI_DELAY_UNIT_NSECS;
```
**(b) Replacement:**
```c
xfer->cs_change = 1;
/* kernel 4.9's spi_transfer has no cs_change_delay member */
```
**(c) Why:** the `cs_change_delay` member (and the `SPI_DELAY_UNIT_NSECS`
constant) were added to the SPI API in v5.10. The driver was setting it to
**zero** anyway — an explicit "no delay" — so dropping the two lines changes
nothing; the load-bearing line, `cs_change = 1`, is untouched.

#### A11. Half-duplex controller detection — `mcp251xfd_register_quirks()`

**(a) Original (5.10):**
```c
const struct spi_controller *ctlr = spi->controller;

if (ctlr->flags & SPI_CONTROLLER_HALF_DUPLEX)
```
**(b) Replacement:**
```c
/* kernel 4.9: spi_device::master / SPI_MASTER_HALF_DUPLEX */
if (spi->master->flags & SPI_MASTER_HALF_DUPLEX)
```
**(c) Why:** in 4.9 the SPI device's link to its controller is the
`master` member (renamed to `controller` in v5.10), and the half-duplex
flag was `SPI_MASTER_HALF_DUPLEX` (renamed to `SPI_CONTROLLER_HALF_DUPLEX`
in v5.10). Same bit, same meaning — the driver still enables its
half-duplex quirk when the underlying SPI controller says it cannot do
simultaneous read+write.

#### A12. "What speed did the bus actually run at?" — `mcp251xfd_register_get_dev_id()`

**(a) Original (5.10):**
```c
*effective_speed_hz = xfer->effective_speed_hz;
```
**(b) Replacement:**
```c
/* kernel 4.9: no spi_transfer::effective_speed_hz, assume requested */
*effective_speed_hz = xfer->speed_hz;
```
**(c) Why:** 5.10 added `effective_speed_hz`, which the SPI core fills in
with the speed the controller *actually* negotiated (it may clamp a
requested rate down to the nearest achievable divider). 4.9 has no such
reporting — `xfer->speed_hz` (the requested rate) is the best information
available, and the driver only uses the value in its startup log line, so
worst case the log says the requested speed rather than the negotiated one.

#### A13. The real-time SPI flag — `mcp251xfd_probe()`

**(a) Original (5.10):**
```c
spi->bits_per_word = 8;
spi->rt = true;
err = spi_setup(spi);
```
**(b) Replacement:**
```c
spi->bits_per_word = 8;
err = spi_setup(spi);
```
**(c) Why:** the `rt` member (request real-time scheduling of this
device's SPI transfers) was added in v5.10 and doesn't exist in 4.9 at
all. Dropping it means the chip's transfers are scheduled with normal
priority — no observable difference unless another driver on the same SPI
bus competes in hard real time.

### 2.2 `mcp251xfd-regmap.c` — the SPI register-access layer

**No changes.** An earlier revision of this backport removed the two
`devm_kfree()` calls in this file (in
`mcp251xfd_regmap_destroy_nocrc()` / `mcp251xfd_regmap_destroy_crc()`,
which free the internal CRC translation buffers when the driver's CRC mode
changes) under the belief that the function was new in v5.10 — that was a
misdiagnosis. `devm_kfree()` — free memory allocated by `devm_kzalloc()`
while the device still exists — has existed since **v2.6.21**, the release
that introduced the device-managed-resource framework, and in 4.9 it is
declared in `include/linux/device.h` and `EXPORT_SYMBOL_GPL`'d from
`drivers/base/devres.c`. The file here is therefore byte-identical to the
5.10 original, and it compiles unchanged against the 4.9 headers —
verified by the full build.

### 2.3 `mcp251xfd.h` — shared definitions and types

#### H1. Removed include

**(a) Original (5.10):** `#include <linux/can/rx-offload.h>`
**(b) Replacement:** line deleted.
**(c) Why:** that header file does not exist in kernel 4.9 — it is new in
5.10.

#### H2. Removed struct member

**(a) Original (5.10)** (inside `struct mcp251xfd_priv`):
```c
struct can_rx_offload offload;
```
**(b) Replacement:** line deleted.
**(c) Why:** the `struct can_rx_offload` type comes from the missing header
(H1); with the framework gone, the driver's state struct no longer carries an
offload object.

#### H3. Removed constant

**(a) Original (5.10):** `#define MCP251XFD_NAPI_WEIGHT 32`
**(b) Replacement:** line deleted.
**(c) Why:** it told the offload framework how many frames to process per
interrupt; with no offload framework there is nothing to feed it to.

#### H4. Two compat macros added

**(a) Original (5.10):** nothing here — the driver relied on the kernel's
built-in helpers.
**(b) Replacement** (added after the include block):
```c
/* kernel < 4.16 compat (include/linux/bitfield.h, field_mask()). */
#define field_mask(field) \
    ((field) / (field & -(field)))

/* kernel < 4.16 compat (include/linux/stddef.h, sizeof_field()). */
#define sizeof_field(TYPE, MEMBER) \
    sizeof((((TYPE *)0)->MEMBER))
```
**(c) Why:** both of these tiny helpers only appeared in kernel **v4.16**, so
4.9 doesn't have them, and the driver's register definitions use them
dozens of times; defining them once in the header (with the exact upstream
formulas) lets all that code compile unchanged. They're defined *after* the
header's own `#include` lines, which also means they can't collide with the
real definitions on newer kernels — the module still builds on anything
≥ 4.16 if you ever need that.

### 2.4 `mcp251xfd-crc16.c`

No changes. It is pure C (a CRC-16 table implementation) with no kernel API
at all, so 5.10 and 4.9 see identical code.

### 2.5 `Makefile`

**(a) Original (5.10):**
```make
obj-$(CONFIG_CAN_MCP251XFD) += mcp251xfd.o

mcp251xfd-objs :=
mcp251xfd-objs += mcp251xfd-core.o
mcp251xfd-objs += mcp251xfd-crc16.o
mcp251xfd-objs += mcp251xfd-regmap.o
```
**(b) Replacement** (full new Makefile, abridged to the load-bearing lines):
```make
obj-m += mcp251xfd.o

mcp251xfd-objs += mcp251xfd-core.o
mcp251xfd-objs += mcp251xfd-crc16.o
mcp251xfd-objs += mcp251xfd-regmap.o

KDIR ?= /lib/modules/$(shell uname -r)/build
PWD  := $(shell pwd)

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean

install:
	$(MAKE) -C $(KDIR) M=$(PWD) modules_install
```
**(c) Why:** three separate reasons. First, the Nano's 4.9 kernel
configuration has never heard of `CONFIG_CAN_MCP251XFD` (the driver didn't
exist when that kernel was written), so `obj-$(CONFIG_CAN_MCP251XFD)` would
expand to `obj- +=` and build *nothing* — `obj-m` says "always build this as
a loadable module" instead. Second, the original Makefile only works when
invoked from *inside* the kernel source tree; the `KDIR`/`all`/`clean`/
`install` lines make a plain `make` work from your own folder, which is what
"building out-of-tree" actually means in practice. Third, during review a
typo was caught and fixed in the first revision of this file: the object
names were written `mcp251fd-*` (missing the "x"), which matches no source
file and would have failed the build immediately with "No rule to make
target" — the file you have here is the fixed version.

### 2.6 `Kconfig`

**(a) Original (5.10):**
```
config CAN_MCP251XFD
	tristate "Microchip MCP251xFD SPI CAN controllers"
	select REGMAP
	help
	  Driver for the Microchip MCP251XFD SPI FD-CAN controller
	  family.
```
**(b) Replacement:**
```
config CAN_MCP251XFD
	tristate "Microchip MCP251XFD SPI CAN controllers"
	depends on CAN && SPI
	select REGMAP
	help
	  Driver for the Microchip MCP251XFD SPI FD-CAN controller family
	  (MCP2515FD, MCP2516FD, MCP2517FD, MCP2518FD, ...).
```
**(c) Why:** cosmetic/consistency — the display title is corrected to the
actual chip family name, and the `depends on CAN && SPI` line states
explicitly that the driver needs the CAN and SPI subsystems; informational
for this build, because the out-of-tree Makefile builds unconditionally.

### 2.7 Feature dropped (explicit call-out): CAN RX offload

The only *functional* feature removed is 5.10's **CAN RX offload framework**
(`linux/can/rx-offload.h`). In 5.10, received CAN frames are parked in a
per-device queue and, on the next interrupt, re-sorted by *hardware
timestamp* before being delivered to userspace — a neat mechanism for
timestamp-accurate ordering. The framework is brand-new in 5.10 with no
4.9 counterpart, so all ten offload-framework function call sites were
removed or replaced with the older, simpler delivery path described in 2.1
(four `queue_sorted` deliveries, one `get_echo_skb`, one `enable`, two
`disable`, one `add_manual`, one `del`), along with the header include, the
`offload` struct member, and the `MCP251XFD_NAPI_WEIGHT` constant in
`mcp251xfd.h`.

**Honest functional impact:**

- Frames are delivered in **hardware FIFO order** instead of
  hardware-timestamp-sorted order. On a single CAN bus these are the same
  order in practice — nothing you will notice in normal operation.
- **Hardware timestamps are no longer attached** to received frames, and TX
  echo no longer carries one. If an application uses socket-level hardware
  timestamping (`SOF_TIMESTAMPING_RX_HARDWARE` / `SOF_TIMESTAMPING_TX_HARDWARE`),
  it will not get timestamps from this driver on 4.9.
- The driver's own `rx_fifo_errors` counter is no longer incremented (the
  network core accounts for drops on the receive path instead).
- The **real-time SPI flag** (`spi->rt`, A13) is not set, because 4.9 has
  no such flag — this chip's SPI transfers get normal scheduling priority
  (no difference unless something else on the bus needs real-time
  priority).
- The **chip-select delay** initialization (A10) is gone with its struct
  member; it was an explicit zero ("no delay"), so nothing is lost.
- **Everything else is fully intact:** all CAN-FD functionality (FD frames up
  to 64 bytes, FD bittiming, CRC-16), all four chip variants, SPI access,
  interrupt handling, and power management behave exactly as in 5.10.

---

## Section 3 — Compiling and loading the module on the Jetson Nano

Your target: **Jetson Nano 2 GB, JetPack 4.6, kernel `4.9.337-tegra`**.
Everything below runs *on the Nano itself* (you SSH into it or use its
terminal). No cross-compilation needed.

### Step 1 — Install the build prerequisites (one time)

```sh
sudo apt update
sudo apt install -y build-essential linux-headers-4.9.337-tegra can-utils
```

What each package is:

- `build-essential` — gcc, make and friends, the tools that do the
  compiling.
- `linux-headers-4.9.337-tegra` — the header files that describe your
  running kernel's API. **This is the package the driver compiles against**,
  and it must exactly match the kernel that is running.
- `can-utils` — the `candump` / `cansend` command-line tools used to test
  the CAN interface.

Then confirm the version matches (it should print exactly
`4.9.337-tegra`):

```sh
uname -r
```

> **If `uname -r` prints something else** (for example after a JetPack
> update), the headers package name changes to match it — install
> `linux-headers-<what-uname-printed>`, and use that path in Step 4.

A quick sanity check that the headers are a genuine 4.9 set (this file must
*not* exist — it is the 5.10-only header the backport removed):

```sh
ls /usr/src/linux-headers-4.9.337-tegra/include/linux/can/rx-offload.h
# expected: "No such file or directory"
```

### Step 2 — Copy the backport folder to the Nano

From the machine that currently holds the folder (this workstation), copy it
to the Nano over the network. Replace `<user>` and `<nano-ip>` with your
Nano's login name and IP address (e.g. `192.168.1.50`):

```sh
scp -r ~/mcp251xfd-backport <user>@<nano-ip>:~/
```

or, if you prefer rsync (nicer if you copy again later):

```sh
rsync -av ~/mcp251xfd-backport/ <user>@<nano-ip>:~/mcp251xfd-backport/
```

The folder contains the build inputs (`Makefile`, `Kconfig`, the four
`mcp251xfd-*` source files) plus reference material (`src-5.10/`,
`analysis.md`, `README.md`, this report) which the build simply ignores.

### Step 3 — Build the module

On the Nano:

```sh
cd ~/mcp251xfd-backport
make
```

That's the whole build. What happens behind the scenes: `make` runs the
kernel's own build system inside your folder, using
`KDIR=/lib/modules/4.9.337-tegra/build` (the default set in the Makefile),
compiles `mcp251xfd-core.c`, `mcp251xfd-crc16.c` and `mcp251xfd-regmap.c`,
links them, and produces the module file **`mcp251xfd.ko`** in the same
directory. You should end with a line like
`  LD      /home/<user>/mcp251xfd-backport/mcp251xfd.ko`.

If your running kernel is not `4.9.337-tegra`, point `KDIR` at the right one
explicitly:

```sh
make KDIR=/lib/modules/4.9.337-tegra/build
```

Useful companions: `make clean` (delete build products) and, later,
`make install` (Step 6).

### Step 4 — Load the module and check that it probed

```sh
sudo insmod mcp251xfd.ko
dmesg | tail
ip link show
```

- `dmesg | tail` shows the kernel log. On success you should see the driver's
  probe messages for the MCP251XFD chip. If probe failed, `dmesg` tells you
  why — the most common message is
  `No IRQ specified (maybe node "interrupts-extended" in DT missing)!`,
  which means the Nano's device tree entry for the chip lacks an interrupt
  (see Troubleshooting below).
- `ip link show` lists network interfaces. A new **`can0`** (or `can1`, …)
  interface means the driver created the CAN network device successfully.

### Step 5 — Bring the interface up and run a basic CAN test

```sh
sudo ip link set can0 up
```

Now, in **two separate terminals** on the Nano (or on two machines wired to
the same CAN bus):

```sh
# Terminal A — listen for frames:
sudo candump can0

# Terminal B — send a test frame (ID 0x123, payload 0xDEADBEEF):
sudo cansend can0 123#DEADBEEF
```

Terminal A should immediately print the frame Terminal B sent:
`(2026-10-18 ...) can0  123   Data:      DE AD BE EF`. If you can send and
receive a frame, the driver is working end to end. (For a real bus you'd use
your application's own IDs; for a quick self-test, loopback mode works too:
`sudo ip link set can0 down && sudo ip link set can0 type can loopback on &&
sudo ip link set can0 up`, then send/candump as above.)

### Step 6 — Make the module load at every boot

`insmod` only lasts until reboot. To load it permanently:

```sh
sudo make install        # copies mcp251xfd.ko to /lib/modules/4.9.337-tegra/extra/
sudo depmod -a           # updates the kernel module index so it can be found
echo mcp251xfd | sudo tee -a /etc/modules
```

`/etc/modules` is the classic list of modules loaded at boot by the
`modules` init script; adding `mcp251xfd` there means every future boot
automatically runs `modprobe mcp251xfd`. (Equivalent modern alternative:
create a systemd unit — `mcp251xfd-load.service` with
`ExecStart=/sbin/modprobe mcp251xfd` — but `/etc/modules` is the simplest on
a Nano.)

After the next reboot, confirm with:

```sh
lsmod | grep mcp251xfd      # the module is loaded
ip link show                # can0 is present
```

### Step 7 — Unloading and troubleshooting

**Unloading** (do this if you want to remove the module or rebuild it):

```sh
sudo ip link set can0 down     # the interface must be down first
sudo rmmod mcp251xfd           # unload the module
```

**Troubleshooting, in the order failures usually appear:**

1. **Build fails with `No rule to make target 'mcp251xfd-core.o'`** —
   the Makefile's object names don't match the source file names. Check
   `ls *.c` in the folder; the Makefile here already has the corrected names
   (`mcp251xfd-*`), so seeing this means an older, pre-fix copy is on the
   Nano — re-copy the folder.
2. **Build fails with `...: No such file or directory` for a kernel header**
   — you are compiling against the wrong kernel's headers. Check
   `uname -r`, then make sure the matching
   `linux-headers-$(uname -r)` package is installed and `KDIR` points to it.
3. **`insmod` fails with `Invalid module format`** — the `.ko` was built for
   a *different* kernel version than the one running. Rebuild on the Nano
   with the matching headers (Step 1–3); modules are not portable across
   kernel versions.
4. **`insmod` fails with `Key ... not found`** — module signature
   verification mismatch; uncommon on the Nano, but rebuilding from a clean
   state (`make clean && make`) fixes it.
5. **`insmod` succeeds but no `canX` appears** — read `dmesg | tail`.
   The usual culprit is the device tree: the driver needs an SPI node with a
   supported compatible string (`microchip,mcp2515fd`, `microchip,mcp2516fd`,
   `microchip,mcp2517fd`, `microchip,mcp2518fd`) **and** an `interrupts`
   property. Check what your device tree describes with
   `find /sys/firmware/devicetree/base -name "*mcp251x*"`. If the node is
   missing entirely, the chip isn't wired/described on this board revision —
   nothing a driver change can do about that.
6. **Interface exists, `ip link set can0 up` works, but no traffic** — this
   is now a hardware issue, not a driver one: check the SPI wiring is intact
   (chip selected correctly, clock running), the CAN transceiver and
   termination (120 Ω), and use `ip -s link show can0` plus `candump` to see
   whether frames are arriving at all.

### What to send back if something breaks

The single most useful diagnostic is always:

```sh
uname -r
make 2>&1 | tail -30      # if the build fails
dmesg | tail -30          # if load/probe fails
```

The build output names the exact file, line and missing symbol; `dmesg`
names the exact probe failure — with either of those, the problem is
identifiable without guessing.
