# SPDX-License-Identifier: GPL-2.0-only
#
# mcp251xfd - Microchip MCP251XFD SPI CAN driver (kernel 4.9 backport)
#
# This Makefile is dual-purpose:
#   - run "make" here to build out-of-tree against a 4.9 kernel:
#       make                 # uses /lib/modules/$(uname -r)/build
#       make KDIR=<path>     # e.g. KDIR=/path/to/linux-headers-4.9.337-tegra
#       make clean
#       make install
#   - the obj-m / mcp251xfd-objs lines below are what the kernel Kbuild
#     reads when invoked with M=$(dir) (or for in-tree integration).
#
# Note: obj-m (not obj-$(CONFIG_CAN_MCP251XFD)) is required, because an
# out-of-tree 4.9 kernel config does not know CONFIG_CAN_MCP251XFD.

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

.PHONY: all clean install
