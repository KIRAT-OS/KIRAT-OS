# Makefile for kimi-ai kernel module (hardened build)
# Targets: all, clean, install, uninstall

# Module name
obj-m += kimi-ai.o

# Source file (the fixed, hardened version)
kimi-ai-objs := kimi-ai-fixed.o

# Hardened compiler flags
EXTRA_CFLAGS += -fstack-protector-strong
EXTRA_CFLAGS += -D_FORTIFY_SOURCE=2
EXTRA_CFLAGS += -Werror
EXTRA_CFLAGS += -Wall -Wextra -Wstrict-prototypes
EXTRA_CFLAGS += -Wno-unused-parameter
EXTRA_CFLAGS += -fno-strict-overflow
EXTRA_CFLAGS += -fwrapv

# Kernel build directory (override with KDIR=...)
KDIR ?= /lib/modules/$(shell uname -r)/build

# Default target: build the module
all:
	$(MAKE) -C $(KDIR) M=$(PWD) EXTRA_CFLAGS="$(EXTRA_CFLAGS)" modules

# Clean build artifacts
clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean
	@rm -f *.o *.ko *.mod.c *.mod *.order *.symvers .*.cmd

# Install module into running kernel
install:
	$(MAKE) -C $(KDIR) M=$(PWD) modules_install
	depmod -a

# Remove module from system
uninstall:
	rm -f /lib/modules/$(shell uname -r)/extra/kimi-ai.ko
	depmod -a

# Load module (for testing)
load:
	insmod kimi-ai.ko || true

# Unload module
unload:
	rmmod kimi-ai || true

.PHONY: all clean install uninstall load unload
