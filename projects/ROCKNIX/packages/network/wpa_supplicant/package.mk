# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2026-present ROCKNIX (https://github.com/ROCKNIX)

PKG_NAME="wpa_supplicant"
PKG_VERSION="2.12"
PKG_SHA256="08e23937e16d0155e55cab2b51f51fbe10d80a1aa91c4e15442645059b737ef6"
PKG_LICENSE="BSD"
PKG_SITE="https://w1.fi/wpa_supplicant/"
PKG_URL="https://w1.fi/releases/${PKG_NAME}-${PKG_VERSION}.tar.gz"
PKG_DEPENDS_TARGET="toolchain dbus libnl openssl"
PKG_LONGDESC="Wi-Fi supplicant, used by NetworkManager as its Wi-Fi backend"
PKG_TOOLCHAIN="make"

PKG_MAKE_OPTS_TARGET="-C wpa_supplicant V=1 BINDIR=/usr/sbin"
PKG_MAKEINSTALL_OPTS_TARGET="-C wpa_supplicant V=1 BINDIR=/usr/sbin"

configure_target() {
  cp ${PKG_DIR}/config/makefile.config wpa_supplicant/.config
}

post_makeinstall_target() {
  rm -f ${INSTALL}/usr/sbin/wpa_passphrase

  mkdir -p ${INSTALL}/etc/dbus-1/system.d
    cp wpa_supplicant/dbus/dbus-wpa_supplicant.conf ${INSTALL}/etc/dbus-1/system.d
  mkdir -p ${INSTALL}/usr/share/dbus-1/system-services
    cp wpa_supplicant/dbus/fi.w1.wpa_supplicant1.service ${INSTALL}/usr/share/dbus-1/system-services
  mkdir -p ${INSTALL}/usr/lib/systemd/system
    cp wpa_supplicant/systemd/wpa_supplicant.service ${INSTALL}/usr/lib/systemd/system
}
