# mcp251xfd — out-of-tree kernel 4.9 backport

Microchip MCP251XFD SPI CAN-FD driver, backported from kernel 5.10
(source snapshot in `src-5.10/`) to a stock NVIDIA Tegra
`4.9.337-tegra` kernel, built out-of-tree.

## Files

| File | Purpose |
|---|---|
| `Makefile` | Dual-purpose: out-of-tree wrapper (`make [KDIR=...]`) and Kbuild `obj-m`/`mcp251xfd-objs` lines |
| `Kconfig` | Standalone `CAN_MCP251XFD` + `CAN_MCP251XFD_SANITY` options (depends on CAN && SPI, selects REGMAP) |
| `mcp251xfd-core.c` | Main driver (SPI, IRQ, TX/RX, CAN core glue) |
| `mcp251xfd-crc16.c` | CRC-16 tables for FD frames (unchanged from 5.10) |
| `mcp251xfd-regmap.c` | regmap register access layer |
| `mcp251xfd.h` | Shared definitions + kernel-compat macros |
| `analysis.md` | 5.10 -> 4.9 API gap analysis and edit plan |
| `src-5.10/` | Untouched 5.10 source snapshot (reference) |

## Building

```sh
# against the running kernel's headers
make

# against a specific 4.9 Tegra kernel tree
make KDIR=/path/to/linux-headers-4.9.337-tegra

sudo make install
```

Produces `mcp251xfd.ko` (single module, three objects: core, crc16, regmap).

## What was backported

The 5.10 driver uses 13 API symbols that do not exist in 4.9
(see `analysis.md` for the full inventory). The fixes, in order of
severity:

1. **CAN RX offload removed.** 4.9 has no `can_rx_offload*` API, so the
   offload is dropped: RX (normal and error frames) goes directly to
   `netif_receive_skb()`, and TX completion uses the classic
   `can_get_echo_skb(ndev, idx)` / `can_put_echo_skb()` pair. The
   `struct can_rx_offload offload` member, `can_rx_offload_add_manual()`
   in probe, `can_rx_offload_del()` in remove, and the
   enable/disable calls in open/close are all removed. `rx_fifo_errors`
   is no longer incremented by the driver (drops are counted by the
   net core instead).
2. **`devm_kfree()`** (only in 5.10's regmap destroy helpers) replaced by
   pointer NULL-out; the buffers are devres-managed and released at
   device removal.
3. **`dev_err_probe()`** replaced with `dev_err()` + `return -ENXIO`.
4. **`device_get_match_data()`** replaced with 4.9's
   `of_device_get_match_data()` (DT-only probing).
5. **`MCP251XFD_NAPI_WEIGHT`** deleted together with the offload;
   `napi.weight` keeps its static value 64.
6. **Compat macros** for `field_mask`/`sizeof_field` added to
   `mcp251xfd.h` (identical to the 5.10 definitions, so the module also
   builds on newer kernels where they come from `bitfield.h`/`stddef.h`).

## Known behavioral differences vs 5.10

- No `CAN_NETLINK_XSTAT` timestamped echo delivery (no offload).
- RX frames are not sorted by hardware timestamp before delivery.
- `rx_fifo_errors` is not incremented for dropped frames.

Everything else (NAPI weight 64, TX echo bookkeeping, CAN state machine,
error counters, CRC16 handling) is identical to 5.10.
