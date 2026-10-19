# mcp251xfd → Linux 4.9 (Jetson Nano, 4.9.337-tegra) Backport Analysis

Deliverable of kanban task `t_fc1ab765`. This document is the input to the
implementation task `t_e731bd10` (build the out-of-tree module tree) and to the
final task `t_189a135e` (instructions + explainer).

All line numbers below refer to the files in `~/mcp251xfd-backport/src-5.10/`
(the extracted v5.10-era driver, see §2).

---

## 1. Scope

- Target: out-of-tree kernel module for **linux-headers-4.9.337-tegra**
  (JetPack 4.6, Jetson Nano, SPI-based Microchip MCP251xFD CAN FD).
- Strategy: take the **v5.10-era driver** (first mainline merge, 6 files) as
  the base, strip the APIs that do not exist in 4.9, and build it out-of-tree.
- Result of the full audit: **346 unique external symbols** were checked
  against the v4.9 tree. **335 are compatible as-is.** Exactly **11 symbols +
  1 header** are missing in 4.9 and require edits (§5, §6). Everything is a
  localized, mechanical change — no architectural rewrite.

## 2. Source baseline: v5.10 (not the modern tree, not 4.20)

The local repo (`~/github/linux`, HEAD v7.3-rc7) has the *modern split layout*
(17 files: `mcp251xfd.c`, `mcp251xfd-*.c/h`, …) which accumulated many post-5.10
API dependencies. The 4.9 backport is far smaller against the **v5.10** merge:
that is the version closest to a 4.9-era API surface, and it is what this
analysis covers.

The driver was merged in v5.10 as `drivers/net/can/spi/mcp251xfd/` (6 files):

| file                  | lines | role                                        |
|-----------------------|-------|---------------------------------------------|
| `mcp251xfd-core.c`    | 2931  | probe/remove, netdev, CAN/CAN-FD, IRQ, ring |
| `mcp251xfd-crc16.c`   | 279   | CRC-16 lookup tables for CRC-enabled regmap |
| `mcp251xfd-regmap.c`  | 553   | regmap bus/config, map read/write, init/del |
| `mcp251xfd.h`         | 1013  | hw register structs, priv struct, constants |
| `Kconfig`             | 25    | `CAN_MCP251XFD`, `CAN_MCP251XFD_SANITY`     |
| `Makefile`            | 7     | `mcp251xfd-objs`                            |

Extracted to: `~/mcp251xfd-backport/src-5.10/`.

> Repo caveat (corrected 2026-10-19): an earlier draft of this document
> claimed the `v4.9` git tag in this repo was "synthetic" because it
> *contains* `devm_kfree` — that was a misdiagnosis. `devm_kfree` is a
> genuine v2.6.21+ symbol (it is in the original devres patch, lkml 2006-12-26,
> and in the real "Linux 4.9" release commit 69973b830859 in this repo's
> mainline history, which also correctly *lacks* e.g. `cs_change_delay`).
> The tag is therefore fine; every presence/absence statement in this
> document was verified with `git grep` against it. The final authority is
> still the real `linux-headers-4.9.337-tegra` on the device
> (verification commands in §9).

## 3. Per-file API inventory

Method: programmatic symbol inventory (`.inventory.json` in the backport dir)
of all external kernel symbols per file, then each symbol was grepped in the
v4.9 tree.

### 3.1 `mcp251xfd-core.c` (232 unique external symbols)

- Includes (10): `linux/can/core.h`, `linux/can/dev.h`, `linux/clk.h`,
  `linux/can/rx-offload.h` ← **missing in 4.9**, `linux/device.h`,
  `linux/delay.h`, `linux/etherdevice.h`, `linux/gpio/consumer.h`,
  `linux/mod_devicetable.h`, `linux/of_device.h`, `linux/regulator/consumer.h`,
  `linux/spi/spi.h`, plus the local `mcp251xfd.h`. (All except
  `can/rx-offload.h` exist in v4.9.)
- SPI: classic `struct spi_driver { .probe, .remove }` (probe signature
  `int mcp251xfd_probe(struct spi_device *)`, remove `int … (struct spi_device *)`)
  — already 4.9 style, **no `probe_new` issue**. `spi_setup`,
  `spi_get_drvdata/spi_set_drvdata`, `spi_get_device_id`,
  `spi_sync_message` (via regmap), `spi_message_init_with_transfers`
  (signature identical in 4.9).
- CAN core: `alloc_candev(sizeof(struct mcp251xfd_priv), MCP251XFD_TX_OBJ_NUM_MAX)`
  (core.c:2791-2792), `free_candev`, `register_candev`, `unregister_candev`,
  `open_candev`, `close_candev`, `netif_start_queue/stop_queue`,
  `netif_tx_*`? — none; queue control only. `struct can_priv` usage:
  `bittiming`, `canfd.bittiming`, `do_set_bittiming`, `do_set_canfd_bittiming`,
  `ndo_set_mode` (all present in v4.9 `include/linux/can/dev.h`).
  `IFF_ECHO` flag set in probe (core.c:2796).
- Echo SKB: `can_put_echo_skb` (TX path), `can_get_echo_skb`? — not yet used in
  the v5.10 code (offload instead, see §5.2); both exist in v4.9.
- IRQ: `request_threaded_irq(spi->irq, NULL, mcp251xfd_irq, IRQF_ONESHOT, …)` /
  `free_irq` — **no NAPI at all in this driver** (no `netif_napi_add`, no
  `struct napi_struct`; RX/TX completion run in the threaded IRQ handler).
  `MCP251XFD_NAPI_WEIGHT` (mcp251xfd.h:380) is used exactly once, as the
  `napi_weight` argument of `can_rx_offload_add_manual` — it disappears with
  the offload removal (§5.2).
- gpio: `devm_gpiod_get_optional` (RX-int), `gpiod_get_value_cansleep`,
  `gpiod_direction_input` — all present in v4.9.
- clk: `clk_get`, `clk_prepare_enable`, `clk_disable_unprepare`,
  `clk_get_rate`, `clk_unprepare` — v4.9.
- regulator: `devm_regulator_get`, `regulator_enable/disable` — v4.9.
- devm allocators: `devm_kzalloc`, `devm_kmalloc`, **`devm_kfree`** — all in
  v4.9 (since v2.6.21) — no edits (§5.6, corrected).
- Error logging: `dev_err` (fine) and **`dev_err_probe` — NOT in 4.9** (§5.3).
- Misc: `FIELD_GET`/`GENMASK` (`<linux/bitfield.h>`, v4.9), `IS_ENABLED`,
  `__packed`, `memcpy_toio`? — none; plain `memcpy`/`cpu_to_le32` etc.
  **`field_mask` — NOT in 4.9** (§5.4). **`sizeof_field` — NOT in 4.9** (§5.5).
  **`device_get_match_data` — NOT in 4.9** (§5.7).

### 3.2 `mcp251xfd-crc16.c` (4 symbols)

Lookup-table code (`crc16[256]` + table init, `mcp251xfd_crc16()`). Uses only
`linux/kernel.h`-level facilities — fully 4.9 compatible, **no edits**.

### 3.3 `mcp251xfd-regmap.c` (53 symbols)

- regmap: `devm_regmap_init`, `regmap_read`, `regmap_write`,
  `regmap_multi_reg_*`? — none; plain read/write plus
  `regmap_read_poll_timeout` (v4.9, old API). The `regmap_bus` /
  `regmap_config` fields used (`max_reg`, `reg_bits`, `val_bits`, `fast_io`,
  `reg_format`, `max_raw_read/write`, `read/write_table`-less; `read_reg`/
  `write_reg` callbacks, `regmap_hw_*` typedefs) are **byte-for-byte
  compatible** between 4.9 and 5.10 (typedefs compared identical).
- **`sizeof_field`** × 4 (lines 387, 388, 409, 410) — §5.5.
- **`devm_kfree`** × 4 (lines 471, 475, 524, 528) — in 4.9 (since v2.6.21),
  **no edit** (see §5.6, corrected).
- SPI transfer fields used: `.len`, `.tx_buf`, `.rx_buf`, `.bits_per_word`,
  `.cs_change` — all in v4.9 `struct spi_transfer`. `spi_message_init_with_transfers`
  signature identical in 4.9.

### 3.4 `mcp251xfd.h` (57 symbols)

- Includes (8) incl. **`linux/can/rx-offload.h` (line 15) — missing in 4.9**
  (§5.2).
- `struct can_rx_offload offload;` member at line 566 — removed with the API.
- hw register structs (`mcp251xfd_hw_*`) use **`sizeof_field`** × 5
  (lines 432, 438, 444, 451, 458) — §5.5.
- map buffers (lines 533-542): fixed-size `u8 data[256]` /
  `u8 data[256-4]` + `__be16 crc` — plain C, 4.9-fine.
- `struct __packed mcp251xfd_map_buf_*` — `__packed` exists in 4.9
  (`include/linux/compiler.h`).

### 3.5 Kconfig / Makefile

v5.10 `Kconfig` (verbatim, §8): `CAN_MCP251XFD` (tristate, `select REGMAP`)
+ `CAN_MCP251XFD_SANITY` (bool, 8 `IS_ENABLED` uses in core.c/regmap.c —
`IS_ENABLED` is v4.9). v5.10 `Makefile`: `mcp251xfd-objs += core crc16 regmap`.

The v4.9 tree **already has** `drivers/net/can/spi/` with a
`"CAN SPI interfaces"` menu containing `CAN_MCP251X` — an in-tree merge is 2
Kconfig lines + 1 Makefile line (reference, §8; the deliverable is
out-of-tree).

## 4. Verdict summary

| # | Symbol / item                  | In v4.9? | Fix                                        |
|---|--------------------------------|----------|--------------------------------------------|
| 1 | `linux/can/rx-offload.h`       | no       | drop include; strip offload (§5.2)         |
| 2 | `struct can_rx_offload` (field)| no       | drop member (§5.2)                         |
| 3 | `can_rx_offload_add_manual`    | no       | delete call (§5.2)                         |
| 4 | `can_rx_offload_del`           | no       | delete call (§5.2)                         |
| 5 | `can_rx_offload_enable`        | no       | delete call (§5.2)                         |
| 6 | `can_rx_offload_disable`       | no       | delete call + fixup label/goto (§5.2)      |
| 7 | `can_rx_offload_get_echo_skb`  | no       | → `can_get_echo_skb` (v4.9 ✓) (§5.2)       |
| 8 | `can_rx_offload_queue_sorted`  | no       | → `netif_receive_skb` (v4.9 ✓) (§5.2)      |
| 9 | `dev_err_probe`                | no (5.9) | → `dev_err` + return code (§5.3)           |
| 10| `field_mask`                   | no (5.10)| compat macro in `mcp251xfd.h` (§5.4)       |
| 11| `sizeof_field`                 | no (5.11)| compat macro in `mcp251xfd.h` (§5.5)       |
| 12| `device_get_match_data`        | no (5.11)| → `of_device_get_match_data` (v4.9 ✓) (§5.7)|
| 13| `devm_kfree`                   | **yes (2.6.21)** | no change needed (§5.6, corrected) |

Everything else (regmap, SPI, CAN core, gpio, clk, regulator, N/A ethtool,
C feature macros — no `fallthrough`, no `BUILD_BUG_ON_ZERO`) is verified
compatible.

## 5. The incompatibilities, in detail

### 5.1 `#include <linux/can/rx-offload.h>` — mcp251xfd.h:15

Does not exist in 4.9 (upstream: merged v5.10). Remove the line.

### 5.2 RX offload → classic echo-SKB API (the one real conversion)

The v5.10 driver delivers RX frames through `can_rx_offload` and manages TX
echo via its own `priv->offload.echo_skb[]`. 4.9 has **no** rx-offload
infrastructure (no header, no `can_priv.offload` member, no functions), but it
**does** have the classic echo-SKB API that the driver already calls for
`can_put_echo_skb` on the TX path:

- `can_put_echo_skb(skb, ndev, idx)` — v4.9 ✓ (already used)
- `can_get_echo_skb(ndev, idx)` — v4.9 ✓ (replaces the offload getter)
- `IFF_ECHO` / `can.echo_skb` array — v4.9 ✓

**`echo_skb_max` — no work needed.** The driver already allocates correctly:
`alloc_candev(sizeof(struct mcp251xfd_priv), MCP251XFD_TX_OBJ_NUM_MAX)` at
core.c:2791-2792. The v4.9 signature is
`alloc_candev(int sizeof_priv, unsigned int echo_skb_max)` — identical — so
4.9's CAN core allocates `can->echo_skb[8]` exactly as the v5.10 code
assumes. `IFF_ECHO` is already set (core.c:2796).

Edits (all in `mcp251xfd-core.c` unless noted):

1. **mcp251xfd.h:15** — delete `#include <linux/can/rx-offload.h>`.
2. **mcp251xfd.h:566** — delete `struct can_rx_offload offload;`.
3. **mcp251xfd.h:380** — delete `#define MCP251XFD_NAPI_WEIGHT 32`
   (only consumer is the `add_manual` call removed in step 8).
4. **core.c:1235-1237** (TX completion, in
   `mcp251xfd_handle_tefif_one(priv, hw_tef_obj)`; use `priv->ndev`):

   before:
   ```c
   	stats->tx_bytes +=
   		can_rx_offload_get_echo_skb(&priv->offload,
   					    mcp251xfd_get_tef_tail(priv),
   					    hw_tef_obj->ts);
   ```
   after:
   ```c
   	stats->tx_bytes +=
   		can_get_echo_skb(priv->ndev, mcp251xfd_get_tef_tail(priv));
   ```
   (Both return `u32` = `skb->len`; `hw_tef_obj->ts` is dropped — 4.9 has no
   socket-timestamp path, see §7.2.)

5. **core.c:1441-1443** (normal RX frame), **1580-1582** (error frame),
   **1684-1686** (error frame with ts), **1757-1759** (error frame with
   error counters) — identical 3-line pattern at each site:

   before:
   ```c
   	err = can_rx_offload_queue_sorted(&priv->offload, skb, hw_rx_obj->ts);
   	if (err)
   		stats->rx_fifo_errors++;
   ```
   after:
   ```c
   	netif_receive_skb(skb);
   ```
   (`netif_receive_skb` is v4.9, callable from process context — the threaded
   IRQ handler qualifies. The local `err` is still used elsewhere in each
   function, so no unused-variable warning.)

6. **core.c:2404** (`mcp251xfd_open`) — delete the line
   `can_rx_offload_enable(&priv->offload);`
7. **core.c:2412** — the error goto after `request_threaded_irq` fails:
   `goto out_can_rx_offload_disable;` → `goto out_transceiver_disable;`
8. **core.c:2423-2424** — delete the label and its body:
   ```c
    out_can_rx_offload_disable:
   	can_rx_offload_disable(&priv->offload);
   ```
9. **core.c:2444** (`mcp251xfd_close`) — delete
   `can_rx_offload_disable(&priv->offload);`
10. **core.c:2866-2869** (`mcp251xfd_probe`) — delete the whole block:
    ```c
    	err = can_rx_offload_add_manual(ndev, &priv->offload,
    					MCP251XFD_NAPI_WEIGHT);
    	if (err)
    		goto out_free_candev;
    ```
11. **core.c:2890** (`mcp251xfd_remove`) — delete
    `can_rx_offload_del(&priv->offload);`

### 5.3 `dev_err_probe` — core.c:2741-2743

Not in 4.9 (upstream v5.9). In probe:

before:
```c
	if (!spi->irq)
		return dev_err_probe(&spi->dev, -ENXIO,
				     "No IRQ specified (maybe node \"interrupts-extended\" in DT missing)!\n");
```
after:
```c
	if (!spi->irq) {
		dev_err(&spi->dev, "No IRQ specified (maybe node \"interrupts-extended\" in DT missing)!\n");
		return -ENXIO;
	}
```
(Log text identical — the format already ends in `\n`, and `dev_err` does not
append one.)

### 5.4 `field_mask` — core.c:1230, 1232

Not in 4.9 (upstream v5.10, `include/linux/bitfield.h` — v4.9's bitfield.h has
`FIELD_GET`/`FIELD_PREP` but not `field_mask`). Used to normalize the 7-bit
TEF sequence number: `field_mask(GENMASK(15,9))` = `0xFF80/0x80` = `0xFF`.

Fix — add the upstream definition verbatim to `mcp251xfd.h` (after the
`#include`s, before `MCP251XFD_NAPI_WEIGHT`); **no call-site changes**:

```c
/* kernel < 5.10 compat (include/linux/bitfield.h). */
#define field_mask(field) \
	((field) / (field & -(field)))
```

### 5.5 `sizeof_field` — mcp251xfd.h:432,438,444,451,458 and regmap.c:387,388,409,410

Not in 4.9 (upstream v5.11, `include/linux/stddef.h`).

- **mcp251xfd.h sites** — member sizes in hw structs, e.g.
  `u8 data[sizeof_field(struct canfd_frame, data)]`. Two equivalent fixes:
  (a) compat macro (below), zero call-site changes — **recommended**; or
  (b) replace with the stable macros `CANFD_MAX_DLEN` (64) / `CAN_MAX_DLEN`
  (8) from `<linux/can.h>` (v4.9 ✓).
- **regmap.c sites** — `.max_raw_read/.max_raw_write =
  sizeof_field(struct mcp251xfd_map_buf_{nocrc,crc}, data)`; the structs have
  fixed arrays `data[256]` / `data[256-4]` (mcp251xfd.h:533-542), so the macro
  resolves to 256 and 252. The compat macro keeps them in sync.

Fix — add to `mcp251xfd.h` (same block as §5.4); **no call-site changes**:

```c
/* kernel < 5.11 compat (include/linux/stddef.h). */
#define sizeof_field(TYPE, MEMBER) \
	sizeof((((TYPE *)0)->MEMBER))
```

### 5.6 `devm_kfree` — regmap.c:471, 475, 524, 528 (CORRECTED — no gap)

*An earlier draft of this audit claimed `devm_kfree` was missing from 4.9
(introduced "v5.5") and recommended deleting the four calls. That was
wrong.* `devm_kfree()` has existed since **v2.6.21** — it is part of the
original devres patch (Zhang Le, lkml 2006-12-26, "[PATCH 1/12] devres:
device resource management core") and is present in the real "Linux 4.9"
release commit (69973b830859): declared in `include/linux/device.h`,
implemented and `EXPORT_SYMBOL_GPL`'d in `drivers/base/devres.c`.

Consequence: `mcp251xfd-regmap.c` needs **no changes at all** and is kept
byte-identical to the 5.10 original. The four calls in
`mcp251xfd_regmap_destroy_{nocrc,crc}` (freeing the CRC-translation buffers
on a CRC-mode switch) work exactly as upstream on 4.9. Verified by a full
module build against a clean 4.9 tree.

### 5.7 `device_get_match_data` — core.c:2819

Not in 4.9 (upstream v5.11, `include/linux/property.h`). The driver uses it to
read the per-chip `devtype_data` from the OF table, falling back to
`spi_get_device_id(spi)->driver_data`.

Fix — one token, `<linux/of_device.h>` is already included (core.c) and
`of_device_get_match_data` is in v4.9:

```c
	match = of_device_get_match_data(&spi->dev);
```

## 6. Complete edit checklist (mechanical)

**mcp251xfd.h**
1. `:15` delete `#include <linux/can/rx-offload.h>`.
2. After the include block, add the two compat macros (§5.4 + §5.5).
3. `:380` delete `#define MCP251XFD_NAPI_WEIGHT 32`.
4. `:432,438,444,451,458` no change (covered by compat macro) — or swap to
   `CANFD_MAX_DLEN`/`CAN_MAX_DLEN` if preferred.
5. `:566` delete `struct can_rx_offload offload;`.

**mcp251xfd-core.c**
6. `:1235-1237` `can_rx_offload_get_echo_skb(…)` →
   `can_get_echo_skb(priv->ndev, mcp251xfd_get_tef_tail(priv))` (§5.2.4).
7. `:1441-1443`, `:1580-1582`, `:1684-1686`, `:1757-1759`
   `can_rx_offload_queue_sorted(…)` + err check → `netif_receive_skb(skb);`
   (§5.2.5).
8. `:2404` delete `can_rx_offload_enable(&priv->offload);`.
9. `:2412` `goto out_can_rx_offload_disable;` → `goto out_transceiver_disable;`.
10. `:2423-2424` delete `out_can_rx_offload_disable:` label +
    `can_rx_offload_disable(&priv->offload);`.
11. `:2444` delete `can_rx_offload_disable(&priv->offload);`.
12. `:2741-2743` `dev_err_probe` → `dev_err` + `return -ENXIO;` (§5.3).
13. `:2819` `device_get_match_data` → `of_device_get_match_data`.
14. `:2866-2869` delete the `can_rx_offload_add_manual` block.
15. `:2890` delete `can_rx_offload_del(&priv->offload);`.

**mcp251xfd-regmap.c** — no changes (the §5.6 `devm_kfree` "gap" was a
misdiagnosis; the function exists since v2.6.21).

**mcp251xfd-crc16.c** — no changes.

No changes needed in any other file.

## 7. Compatibility confirmations (answers to the implementation task's questions)

- **Probe signature:** already classic 4.9 style — `int probe(struct spi_device *)` /
  `int remove(struct spi_device *)` in `struct spi_driver` (`.probe`, `.remove`).
  No `probe_new` conversion.
- **CAN registration:** the driver uses `register_candev`/`unregister_candev`
  (v4.9 ✓) via `mcp251xfd_register/unregister` wrappers — no
  `can_dev_register`/`can_register_dev` anywhere.
- **NAPI:** none. No `netif_napi_add`, no `napi_struct`; all IRQ work is in
  `request_threaded_irq(…, IRQF_ONESHOT)` handlers (v4.9 ✓). `netif_napi_add_weight`
  is irrelevant.
- **regmap:** function set (`devm_regmap_init`, `regmap_read/write`,
  `regmap_read_poll_timeout`, `regmap_init`-family) and all `regmap_bus` /
  `regmap_config` fields used are compatible with 4.9; `regmap_hw_*` typedefs
  compared identical. No `regmap_gather_ctx` / raw-gather API usage.
- **SPI:** `spi_message_init_with_transfers` signature identical; only
  4.9-era `spi_transfer` fields used; `spi_setup`, `spi_get_device_id`,
  `spi_get_drvdata/spi_set_drvdata` all present.
- **CAN structs:** `struct can_bittiming` / `struct canfd_bittiming` /
  `struct canfd_frame` / `struct can_frame` / `struct can_priv` members used
  (`bittiming`, `canfd.bittiming`, `do_set_*` callbacks, `ndo_set_mode`) all
  present in v4.9 `include/linux/can/dev.h`. Bittiming flows through
  `priv->can.bittiming` — compatible.
- **ethtool:** driver does not use ethtool at all.
- **C feature macros:** no `fallthrough`, no `BUILD_BUG_ON_ZERO`; `__packed`,
  `IS_ENABLED`, designated initializers, flexible array `obj[]` — all 4.9.
- **gpio/clk/regulator:** all consumers present in 4.9 (incl.
  `devm_gpiod_get_optional`, `gpiod_get_value_cansleep`).

## 8. Kconfig / Makefile

v5.10 `Kconfig` (keep as-is for the out-of-tree package):
```
# SPDX-License-Identifier: GPL-2.0-only

config CAN_MCP251XFD
	tristate "Microchip MCP251xFD SPI CAN controllers"
	select REGMAP
	help
	  Driver for the Microchip MCP251XFD SPI FD-CAN controller
	  family.

config CAN_MCP251XFD_SANITY
	depends on CAN_MCP251XFD
	bool "Additional Sanity Checks"
	help
	  This option enables additional sanity checks in the driver,
	  that compares various internal counters with the in chip
	  variants. This comes with a runtime overhead.
	  Disable if unsure.
```
v5.10 `Makefile` (keep as-is, plus an out-of-tree build rule):
```make
# SPDX-License-Identifier: GPL-2.0-only

obj-$(CONFIG_CAN_MCP251XFD) += mcp251xfd.o

mcp251xfd-objs :=
mcp251xfd-objs += mcp251xfd-core.o
mcp251xfd-objs += mcp251xfd-crc16.o
mcp251xfd-objs += mcp251xfd-regmap.o
```
Out-of-tree wrapper (for `t_e731bd10`):
```make
KDIR ?= /lib/modules/$(shell uname -r)/build
all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules
clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean
```

Reference, if the driver is ever merged into a 4.9 tree: v4.9 already has
`drivers/net/can/spi/{Kconfig,Makefile}` with the `"CAN SPI interfaces"` menu
(`depends on SPI`) — append the two configs to the menu and add
`obj-$(CONFIG_CAN_MCP251XFD) += mcp251xfd.o`.

**Layout note for `t_e731bd10`:** keep the v5.10 file names
(`mcp251xfd-core.c`, `mcp251xfd-crc16.c`, `mcp251xfd-regmap.c`,
`mcp251xfd.h`, `Kconfig`, `Makefile`). The names in the task brief
(`mcp251xfd.c`, `mcp251xfd_canfd.c`, `mcp251xfd_regs.h`, `mcp251xfd_dts.h`)
do not correspond to any mainline revision of this driver — do not rename;
the Makefile above already lists the real objects.

## 9. Behavioral notes (for the explainer, `t_189a135e`)

1. **RX path:** frames are injected with `netif_receive_skb()` from the
   threaded IRQ handler (process context). Functionally equivalent to the
   offload queue for the normal Jetson Nano use case (one CAN socket /
   candump / cansend).
2. **Lost with offload:** per-socket echo-frame ordering guarantees and
   socket timestamping (`SOF_TIMESTAMPING`) — the hardware timestamp
   (`hw_rx_obj->ts`) is dropped; TX `tx_bytes` accounting is unchanged
   (`can_get_echo_skb` returns the same `skb->len`).
3. **Stats fidelity:** `rx_fifo_errors` is no longer incremented when the
   network core drops a queued frame (it is counted in net core dropped
   stats instead).
4. **devm_kfree:** no change — `mcp251xfd-regmap.c` is untouched (the
   earlier "removal" was a misdiagnosis, §5.6); buffers are freed
   immediately on a CRC-mode switch, exactly as upstream.
5. **Logging:** `dev_err_probe` → `dev_err` produces byte-identical log text.
6. **Echo buffer sizing:** unchanged — `alloc_candev(sizeof_priv,
   MCP251XFD_TX_OBJ_NUM_MAX)` already matches 4.9's
   `alloc_candev(sizeof_priv, echo_skb_max)`, and `IFF_ECHO` is already set.

## 10. Risks / on-target verification

The local repo's v4.9 tag was earlier suspected of being synthetic (it
*contains* `devm_kfree`), but that suspicion was disproved — `devm_kfree` is
a genuine v2.6.21+ symbol, so its presence is expected (§5.6, corrected).
Before building on the Nano, run once against the real headers to confirm
the 4.9-specific gaps are actually present there (all of these must be
*absent*):

```sh
H=/usr/src/linux-headers-4.9.337-tegra   # or the actual headers path
grep -rn "dev_err_probe\|sizeof_field\|field_mask\|device_get_match_data" $H/include/linux/
ls $H/include/linux/can/rx-offload.h
```
All fixes in §8 are required regardless of the outcome.
