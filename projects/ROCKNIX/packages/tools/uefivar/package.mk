# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026-present ROCKNIX (https://github.com/ROCKNIX)

PKG_NAME="uefivar"
PKG_VERSION="1"
PKG_LICENSE="GPL"
PKG_SITE="https://github.com/ROCKNIX"
PKG_URL=""
PKG_DEPENDS_TARGET="toolchain Python3"
PKG_LONGDESC="Direct block-device access to Qualcomm UEFI variables (PTBL/DStr/VAR2), including RTC time source-of-truth sync (Android compatible)"
PKG_TOOLCHAIN="manual"

post_install() {
  mkdir -p ${INSTALL}/usr/bin
    cp ${PKG_DIR}/sources/uefivar ${INSTALL}/usr/bin/uefivar
    chmod +x ${INSTALL}/usr/bin/uefivar

  enable_service uefivar-rtc-load.service
  enable_service uefivar-rtc-save.service
}
