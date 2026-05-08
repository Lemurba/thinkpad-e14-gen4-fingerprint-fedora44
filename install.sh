#!/usr/bin/env bash
#
# ============================================================================
# WARNING — READ THIS BEFORE RUNNING
# ============================================================================
# Only run this script if you fully understand exactly what it does.
#
# This script REPLACES system files under /usr/lib64 (libfprint-2.so.2.0.0)
# with a third-party binary distributed by Lenovo, installs a proprietary
# closed-source library (libfpcbep.so), modifies SELinux contexts, edits PAM
# configuration via authselect, and locks a Fedora package version in dnf.
#
# Running it without understanding these actions can break authentication on
# your system, prevent you from logging in, or interfere with future updates.
#
# Read the entire script and the project README first. Verify the integrity
# of the Lenovo download yourself. Use at your own risk.
# ============================================================================
#
# install.sh — Enable the FPC 10a5:9800 fingerprint reader on Fedora.
#
# Usage:
#   sudo bash install.sh             # install
#   sudo bash install.sh uninstall   # revert
#   bash install.sh --help           # help
#
# https://github.com/Lemurba/thinkpad-e14-gen4-fingerprint-fedora44

set -euo pipefail

# ----- Re-execute as root if needed --------------------------------------
if [[ $EUID -ne 0 ]]; then
  exec sudo -E bash "$0" "$@"
fi

# ----- Constants ---------------------------------------------------------
LENOVO_URL="https://download.lenovo.com/pccbbs/mobiles/r1slm02w.zip"
LIBDIR="/usr/lib64"
LIBFPRINT_SO="${LIBDIR}/libfprint-2.so.2.0.0"
LIBFPRINT_BAK="${LIBFPRINT_SO}.bak"
LIBFPCBEP_SO="${LIBDIR}/libfpcbep.so"
SENSOR_USB_ID="10a5:9800"

# Default behavior
ACTION="install"
DO_PAM=1
DO_LOCK=1
KEEP_WORKDIR=0
WORKDIR=""

# ----- Pretty output -----------------------------------------------------
if [[ -t 1 ]]; then
  C_RED=$'\033[0;31m'; C_GREEN=$'\033[0;32m'; C_YELLOW=$'\033[1;33m'
  C_BLUE=$'\033[0;34m'; C_BOLD=$'\033[1m'; C_NC=$'\033[0m'
else
  C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_BOLD=""; C_NC=""
fi
log()   { printf '%s[INFO]%s %s\n'  "${C_BLUE}"   "${C_NC}" "$*"; }
warn()  { printf '%s[WARN]%s %s\n'  "${C_YELLOW}" "${C_NC}" "$*" >&2; }
err()   { printf '%s[ERR ]%s %s\n'  "${C_RED}"    "${C_NC}" "$*" >&2; }
ok()    { printf '%s[ OK ]%s %s\n'  "${C_GREEN}"  "${C_NC}" "$*"; }
title() { printf '\n%s== %s ==%s\n' "${C_BOLD}"   "$*"      "${C_NC}"; }

# ----- Helpers -----------------------------------------------------------
usage() {
  cat <<'EOF'
Usage: install.sh [action] [options]

Actions:
  install       (default) install the driver
  uninstall     revert the installation
  status        show current state

Options:
  --no-pam            do not enable pam_fprintd via authselect
  --no-lock           do not lock libfprint in dnf (versionlock)
  --keep-workdir      keep the work directory after install
  --workdir DIR       use DIR as the work directory
  -h, --help          show this help

Examples:
  sudo bash install.sh
  sudo bash install.sh --no-pam --no-lock
  sudo bash install.sh uninstall
  sudo bash install.sh status
EOF
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { err "Missing command: $1"; exit 1; }
}

check_distro() {
  if [[ ! -r /etc/fedora-release ]] || ! command -v dnf >/dev/null 2>&1; then
    err "Unsupported distribution (this script targets Fedora)."
    exit 1
  fi
  log "Detected: $(cat /etc/fedora-release)"
}

check_sensor() {
  if lsusb 2>/dev/null | grep -q "${SENSOR_USB_ID}"; then
    ok "FPC sensor ${SENSOR_USB_ID} detected."
  else
    warn "Sensor ${SENSOR_USB_ID} NOT detected via lsusb."
    warn "Please confirm your laptop actually ships this sensor."
    if [[ -t 0 ]]; then
      read -r -p "Continue anyway? [y/N] " resp
      case "${resp,,}" in y|yes) ;; *) exit 1 ;; esac
    else
      err "Aborting (non-interactive run)."
      exit 1
    fi
  fi
}

install_prereqs() {
  title "Installing prerequisites"
  dnf install -y --setopt=install_weak_deps=False \
      fprintd fprintd-pam unzip curl
}

prepare_workdir() {
  if [[ -z "$WORKDIR" ]]; then
    WORKDIR="$(mktemp -d -t fpc-driver.XXXXXX)"
  else
    mkdir -p "$WORKDIR"
  fi
  log "Work directory: $WORKDIR"
}

download_driver() {
  title "Downloading official Lenovo driver"
  cd "$WORKDIR"
  if [[ -s r1slm02w.zip ]]; then
    log "Zip already present at $WORKDIR/r1slm02w.zip; skipping download."
  else
    curl -fL --progress-bar -o r1slm02w.zip "$LENOVO_URL"
  fi
  log "Extracting..."
  unzip -oq r1slm02w.zip
  ok "Extraction complete."
}

locate_sources() {
  LIBFPRINT_SRC="$(find "$WORKDIR" -path '*/install_libfprint/*/libfprint-2.so.2.0.0' | head -n1)"
  LIBFPCBEP_SRC="$(find "$WORKDIR" -path '*/install_fpc/libfpcbep.so'                 | head -n1)"
  if [[ ! -f "$LIBFPRINT_SRC" ]] || [[ ! -f "$LIBFPCBEP_SRC" ]]; then
    err "Expected files were not found after extraction."
    err "  libfprint-2.so.2.0.0: ${LIBFPRINT_SRC:-<not found>}"
    err "  libfpcbep.so:        ${LIBFPCBEP_SRC:-<not found>}"
    exit 1
  fi
  log "libfprint source: $LIBFPRINT_SRC"
  log "libfpcbep source: $LIBFPCBEP_SRC"
}

backup_libfprint() {
  if [[ -f "$LIBFPRINT_SO" && ! -f "$LIBFPRINT_BAK" ]]; then
    log "Backing up current libfprint to $LIBFPRINT_BAK"
    cp -p "$LIBFPRINT_SO" "$LIBFPRINT_BAK"
  fi
}

install_libs() {
  title "Installing libraries"
  backup_libfprint
  install -m 0755 "$LIBFPRINT_SRC" "$LIBFPRINT_SO"
  install -m 0755 "$LIBFPCBEP_SRC" "$LIBFPCBEP_SO"
  log "Restoring SELinux contexts..."
  restorecon -Rv "$LIBFPRINT_SO" "$LIBFPCBEP_SO" 2>/dev/null || true
  ok "Libraries installed."
}

reload_runtime() {
  title "Reloading udev rules and fprintd"
  udevadm control --reload-rules
  udevadm trigger
  systemctl restart fprintd
  sleep 2
}

verify_install() {
  title "Verifying installation"
  if systemctl is-active --quiet fprintd; then
    ok "fprintd is active."
  else
    err "fprintd is not active. See: systemctl status fprintd"
    return 1
  fi

  local target_user="${SUDO_USER:-$USER}"
  local out
  if out=$(sudo -u "$target_user" fprintd-list "$target_user" 2>&1) && \
     printf '%s' "$out" | grep -q "found"; then
    ok "Sensor recognized by libfprint."
  else
    warn "Sensor not yet recognized by libfprint."
    warn "Try rebooting and then running: fprintd-list \$USER"
    printf '%s\n' "$out"
    return 1
  fi
}

setup_versionlock() {
  title "Locking libfprint in dnf"
  if ! rpm -q python3-dnf-plugin-versionlock >/dev/null 2>&1; then
    log "Installing python3-dnf-plugin-versionlock..."
    dnf install -y --setopt=install_weak_deps=False python3-dnf-plugin-versionlock
  fi
  if dnf versionlock list 2>/dev/null | grep -q '^libfprint'; then
    ok "libfprint is already version-locked."
  else
    dnf versionlock add libfprint
    ok "libfprint locked."
  fi
}

setup_pam() {
  title "Enabling fingerprint authentication (authselect)"
  if ! command -v authselect >/dev/null 2>&1; then
    warn "authselect not found; skipping PAM configuration."
    return 0
  fi
  if authselect current 2>/dev/null | grep -q with-fingerprint; then
    ok "with-fingerprint feature already enabled."
  else
    authselect enable-feature with-fingerprint
    authselect apply-changes
    ok "with-fingerprint enabled."
  fi
}

action_status() {
  title "Current status"
  command -v lsusb >/dev/null 2>&1 && \
    lsusb | grep -i "${SENSOR_USB_ID}" || warn "Sensor ${SENSOR_USB_ID} not detected via lsusb."

  if [[ -f "$LIBFPCBEP_SO" ]]; then
    ok "libfpcbep.so present at ${LIBFPCBEP_SO}"
  else
    warn "libfpcbep.so MISSING at ${LIBFPCBEP_SO}"
  fi

  if [[ -f "$LIBFPRINT_SO" ]]; then
    local size
    size=$(stat -c%s "$LIBFPRINT_SO")
    log "Current libfprint: ${LIBFPRINT_SO} (${size} bytes)"
    if [[ -f "$LIBFPRINT_BAK" ]]; then
      ok "Backup available: ${LIBFPRINT_BAK}"
    fi
  fi

  if systemctl is-active --quiet fprintd; then
    ok "fprintd active"
  else
    warn "fprintd not active"
  fi

  if command -v authselect >/dev/null 2>&1 && \
     authselect current 2>/dev/null | grep -q with-fingerprint; then
    ok "PAM with-fingerprint enabled"
  else
    warn "PAM with-fingerprint NOT enabled"
  fi

  if rpm -q python3-dnf-plugin-versionlock >/dev/null 2>&1 && \
     dnf versionlock list 2>/dev/null | grep -q '^libfprint'; then
    ok "versionlock active on libfprint"
  else
    warn "libfprint not version-locked"
  fi
}

action_install() {
  check_distro
  check_sensor
  install_prereqs
  prepare_workdir
  download_driver
  locate_sources
  install_libs
  reload_runtime
  verify_install || warn "Verification failed, but the installation was applied. Consider rebooting."
  [[ $DO_LOCK -eq 1 ]] && setup_versionlock
  [[ $DO_PAM  -eq 1 ]] && setup_pam

  cat <<EOF

${C_GREEN}${C_BOLD}Installation complete.${C_NC}

Next steps (run as your user, without sudo):
  ${C_BOLD}fprintd-enroll${C_NC}                 # enroll default finger
  ${C_BOLD}fprintd-enroll -f right-thumb${C_NC}  # enroll right thumb
  ${C_BOLD}fprintd-list \$USER${C_NC}            # list enrolled fingers

Test sudo via fingerprint:
  ${C_BOLD}sudo -k && sudo true${C_NC}

If anything breaks:
  ${C_BOLD}sudo bash $0 uninstall${C_NC}
EOF
}

action_uninstall() {
  check_distro
  title "Reverting installation"

  if [[ -f "$LIBFPRINT_BAK" ]]; then
    log "Restoring libfprint from backup..."
    cp -p "$LIBFPRINT_BAK" "$LIBFPRINT_SO"
    rm -f "$LIBFPRINT_BAK"
  else
    warn "No backup found; reinstalling libfprint from Fedora..."
    dnf reinstall -y libfprint
  fi
  rm -fv "$LIBFPCBEP_SO" || true
  restorecon -Rv "$LIBFPRINT_SO" 2>/dev/null || true

  if rpm -q python3-dnf-plugin-versionlock >/dev/null 2>&1; then
    log "Removing libfprint versionlock..."
    dnf versionlock delete libfprint 2>/dev/null || true
  fi

  if command -v authselect >/dev/null 2>&1 && \
     authselect current 2>/dev/null | grep -q with-fingerprint; then
    log "Disabling with-fingerprint in PAM..."
    authselect disable-feature with-fingerprint || true
    authselect apply-changes || true
  fi

  systemctl restart fprintd || true
  ok "Uninstall complete."
}

cleanup() {
  if [[ "$KEEP_WORKDIR" -eq 0 ]] && [[ -n "$WORKDIR" ]] && [[ -d "$WORKDIR" ]] && \
     [[ "$WORKDIR" == /tmp/* ]]; then
    rm -rf "$WORKDIR"
  fi
}
trap cleanup EXIT

# ----- Argument parsing --------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    install|uninstall|status) ACTION="$1" ;;
    --no-pam)        DO_PAM=0 ;;
    --no-lock)       DO_LOCK=0 ;;
    --keep-workdir)  KEEP_WORKDIR=1 ;;
    --workdir)       shift; WORKDIR="${1:?--workdir requires a path}" ;;
    -h|--help)       usage; exit 0 ;;
    *) err "Unknown argument: $1"; usage; exit 1 ;;
  esac
  shift
done

require_cmd lsusb
require_cmd dnf
require_cmd systemctl

case "$ACTION" in
  install)   action_install ;;
  uninstall) action_uninstall ;;
  status)    action_status ;;
  *)         usage; exit 1 ;;
esac
