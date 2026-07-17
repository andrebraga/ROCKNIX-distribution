# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026-present ROCKNIX (https://github.com/ROCKNIX)

PKG_NAME="uefivar"
PKG_VERSION="1"
PKG_LICENSE="GPL"
PKG_SITE="https://github.com/ROCKNIX"
PKG_URL=""
PKG_DEPENDS_TARGET="toolchain Python3"
PKG_LONGDESC="Diagnostic dumper for Qualcomm UEFI variables (PTBL/DStr/VAR2). RTC SSOT is owned by the kernel driver qcom-uefirtc; this tool is read-only inspection."
PKG_TOOLCHAIN="manual"

post_install() {
  mkdir -p ${INSTALL}/usr/bin
  cp ${PKG_DIR}/sources/uefivar ${INSTALL}/usr/bin/uefivar
  chmod +x ${INSTALL}/usr/bin/uefivar
}
