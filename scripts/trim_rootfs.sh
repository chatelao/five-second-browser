#!/usr/bin/env bash
set -euo pipefail

# Helper functions to minimize Debian 12 rootfs size for 5s-browser
# (HP Pavilion 17-g111nz: Pentium 3825U Broadwell-U, Intel Gen8 i915, Intel AC-3165).

configure_dpkg_filters() {
  local rootfs="$1"
  mkdir -p "$rootfs/etc/dpkg/dpkg.cfg.d"

  cat > "$rootfs/etc/dpkg/dpkg.cfg.d/01_nodoc" <<'EOF'
path-exclude /usr/share/doc/*
path-include /usr/share/doc/*/copyright
path-exclude /usr/share/man/*
path-exclude /usr/share/groff/*
path-exclude /usr/share/info/*
path-exclude /usr/share/lintian/*
path-exclude /usr/share/linda/*
EOF

  cat > "$rootfs/etc/dpkg/dpkg.cfg.d/01_nolocales" <<'EOF'
path-exclude /usr/share/locale/*
path-include /usr/share/locale/en*
path-include /usr/share/locale/de*
path-include /usr/share/locale/locale.alias
EOF
}

trim_rootfs() {
  local rootfs="$1"

  echo "   [trim] Cleaning apt caches, docs, manpages, and unused locales..."
  rm -rf \
    "$rootfs/var/lib/apt/lists/"* \
    "$rootfs/var/cache/apt/archives/"*.deb \
    "$rootfs/var/cache/apt/archives/partial/"* \
    "$rootfs/tmp/"* \
    "$rootfs/var/tmp/"* \
    "$rootfs/usr/share/man/"* \
    "$rootfs/usr/share/info/"* \
    "$rootfs/usr/share/groff/"* \
    "$rootfs/usr/share/lintian/"* \
    "$rootfs/usr/share/linda/"*

  if [[ -d "$rootfs/usr/share/doc" ]]; then
    find "$rootfs/usr/share/doc" -mindepth 1 -type f ! -name 'copyright' -delete 2>/dev/null || true
    find "$rootfs/usr/share/doc" -mindepth 1 -type d -empty -delete 2>/dev/null || true
  fi

  if [[ -d "$rootfs/usr/share/locale" ]]; then
    find "$rootfs/usr/share/locale" -mindepth 1 -maxdepth 1 \
      ! -name 'en*' ! -name 'de*' ! -name 'locale.alias' \
      -exec rm -rf {} + 2>/dev/null || true
  fi

  if [[ -d "$rootfs/usr/lib/chromium" ]]; then
    echo "   [trim] Pruning Chromium locales, 200% HiDPI assets, SwiftShader Vulkan, and Qt shims..."
    if [[ -d "$rootfs/usr/lib/chromium/locales" ]]; then
      find "$rootfs/usr/lib/chromium/locales" -mindepth 1 -maxdepth 1 \
        -name '*.pak' ! -name 'en-US.pak' ! -name 'de.pak' \
        -delete 2>/dev/null || true
    fi
    rm -f \
      "$rootfs/usr/lib/chromium/chrome_200_percent.pak" \
      "$rootfs/usr/lib/chromium/libvk_swiftshader.so" \
      "$rootfs/usr/lib/chromium/vk_swiftshader_icd.json" \
      "$rootfs/usr/lib/chromium/libqt5_shim.so" \
      "$rootfs/usr/lib/chromium/libqt6_shim.so" 2>/dev/null || true
  fi

  echo "   [trim] Pruning firmware to Intel AC-3165 (iwlwifi-7265*)..."
  if [[ -d "$rootfs/lib/firmware" ]]; then
    find "$rootfs/lib/firmware" -maxdepth 1 -name 'iwlwifi-*' ! -name 'iwlwifi-7265*' -delete 2>/dev/null || true
    rm -rf \
      "$rootfs/lib/firmware/brcm" \
      "$rootfs/lib/firmware/amdgpu" \
      "$rootfs/lib/firmware/radeon" \
      "$rootfs/lib/firmware/nvidia" \
      "$rootfs/lib/firmware/ath10k" \
      "$rootfs/lib/firmware/ath11k" \
      "$rootfs/lib/firmware/ath6k" \
      "$rootfs/lib/firmware/ath9k_htc" \
      "$rootfs/lib/firmware/mediatek" \
      "$rootfs/lib/firmware/rtlwifi" \
      "$rootfs/lib/firmware/rtw88" \
      "$rootfs/lib/firmware/rtw89" \
      "$rootfs/lib/firmware/mrvl" \
      "$rootfs/lib/firmware/qca" \
      "$rootfs/lib/firmware/ti-connectivity" \
      "$rootfs/lib/firmware/cypress" \
      "$rootfs/lib/firmware/intel/ibt"* 2>/dev/null || true
  fi

  echo "   [trim] Pruning unused kernel modules (keeping Broadwell-U, AC-3165, USB3/SD/SATA, QEMU)..."
  local kver=""
  if [[ -d "$rootfs/lib/modules" ]]; then
    kver="$(find "$rootfs/lib/modules" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort | tail -n 1 || true)"
  fi

  if [[ -n "$kver" && -d "$rootfs/lib/modules/$kver/kernel" ]]; then
    local kmod="$rootfs/lib/modules/$kver/kernel"
    rm -rf \
      "$kmod/drivers/gpu/drm/amd" \
      "$kmod/drivers/gpu/drm/nouveau" \
      "$kmod/drivers/gpu/drm/radeon" \
      "$kmod/drivers/gpu/drm/ast" \
      "$kmod/drivers/gpu/drm/mgag200" \
      "$kmod/drivers/gpu/drm/vmwgfx" \
      "$kmod/drivers/gpu/drm/gma500" \
      "$kmod/drivers/gpu/drm/vboxvideo" \
      "$kmod/drivers/gpu/drm/udl" \
      "$kmod/drivers/gpu/drm/qxl" \
      "$kmod/drivers/net/wireless/ath" \
      "$kmod/drivers/net/wireless/broadcom" \
      "$kmod/drivers/net/wireless/cisco" \
      "$kmod/drivers/net/wireless/intersil" \
      "$kmod/drivers/net/wireless/marvell" \
      "$kmod/drivers/net/wireless/mediatek" \
      "$kmod/drivers/net/wireless/ralink" \
      "$kmod/drivers/net/wireless/realtek" \
      "$kmod/drivers/net/wireless/st" \
      "$kmod/drivers/net/wireless/ti" \
      "$kmod/drivers/net/wireless/zydas" \
      "$kmod/drivers/net/ethernet" \
      "$kmod/drivers/net/wan" \
      "$kmod/drivers/net/can" \
      "$kmod/drivers/infiniband" \
      "$kmod/drivers/staging" \
      "$kmod/drivers/bluetooth" \
      "$kmod/net/bluetooth" \
      "$kmod/drivers/hwmon" \
      "$kmod/drivers/iio" \
      "$kmod/drivers/scsi/megaraid" \
      "$kmod/drivers/scsi/mpt3sas" \
      "$kmod/drivers/scsi/qla2xxx" \
      "$kmod/drivers/scsi/qla4xxx" \
      "$kmod/drivers/scsi/lpfc" \
      "$kmod/drivers/scsi/bnx2i" \
      "$kmod/drivers/scsi/be2iscsi" \
      "$kmod/drivers/scsi/csiostor" \
      "$kmod/drivers/scsi/fcoe" \
      "$kmod/drivers/scsi/libfc" \
      "$kmod/drivers/scsi/smartpqi" \
      "$kmod/drivers/scsi/aacraid" 2>/dev/null || true

    # Prune drivers/media except cec.ko and rc-core.ko (required by drm_display_helper -> i915)
    if [[ -d "$kmod/drivers/media" ]]; then
      find "$kmod/drivers/media" -mindepth 1 -maxdepth 1 ! -name 'cec' ! -name 'rc' -exec rm -rf {} + 2>/dev/null || true
    fi

    chroot "$rootfs" depmod -a "$kver"
  fi
}
