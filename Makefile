CC ?= gcc
CFLAGS := -O2 -march=bonnell -mtune=bonnell -mno-sse4.1 -mno-sse4.2 -mno-avx -Wall -Wextra -Werror -pthread
BUILD_DIR := build
BIN_DIR := $(BUILD_DIR)/bin
DIST_DIR := dist

.PHONY: all build test package clean check-isa

all: build

$(BIN_DIR):
	mkdir -p $(BIN_DIR)

$(BIN_DIR)/5s-fb-splash: src/init/5s_fb_splash.c | $(BIN_DIR)
	$(CC) $(CFLAGS) $< -o $@

$(BIN_DIR)/5s-init: src/init/5s_init.c | $(BIN_DIR)
	$(CC) $(CFLAGS) $< -o $@

build: $(BIN_DIR)/5s-fb-splash $(BIN_DIR)/5s-init
	mkdir -p $(BUILD_DIR)/config
	cp src/proxy/cache_proxy.py $(BIN_DIR)/cache_proxy.py
	cp src/proxy/injected_ui.js $(BIN_DIR)/injected_ui.js
	cp src/net/5s-net-fast.sh $(BIN_DIR)/5s-net-fast.sh
	cp src/checkpoint/5s-checkpoint.sh $(BIN_DIR)/5s-checkpoint.sh
	cp src/checkpoint/5s-browser-launch.sh $(BIN_DIR)/5s-browser-launch.sh
	cp src/config/zram-setup.sh $(BIN_DIR)/zram-setup.sh
	cp src/config/grub-5s.cfg $(BUILD_DIR)/config/grub-5s.cfg
	chmod +x $(BIN_DIR)/5s-fb-splash $(BIN_DIR)/5s-init \
		$(BIN_DIR)/cache_proxy.py $(BIN_DIR)/5s-net-fast.sh \
		$(BIN_DIR)/5s-checkpoint.sh $(BIN_DIR)/5s-browser-launch.sh \
		$(BIN_DIR)/zram-setup.sh

check-isa: $(BIN_DIR)/5s-fb-splash $(BIN_DIR)/5s-init
	@for bin in $(BIN_DIR)/5s-fb-splash $(BIN_DIR)/5s-init; do \
		if objdump -d "$$bin" | grep -qE '\b(pinsrd|pmuldq|pcmpgtq|crc32|vmov)'; then \
			echo "ERROR: Forbidden SSE4.1+/AVX instruction found in $$bin"; \
			exit 1; \
		fi; \
	done
	@echo "[PASS] Bonnell ISA check passed (no SSE4.1+/AVX instructions)"

test: build check-isa
	bash tests/run_all.sh

package: build check-isa
	bash scripts/build_release.sh

clean:
	rm -rf $(BUILD_DIR) $(DIST_DIR)
