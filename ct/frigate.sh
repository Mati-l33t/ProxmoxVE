#!/usr/bin/env bash
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)

# Copyright (c) 2021-2025 community-scripts ORG
# Author: Mati-l33t
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://frigate.video/

APP="Frigate"
var_tags="nvr;camera"
var_cpu="2"
var_ram="4096"
var_disk="8"
var_os="debian"
var_version="12"
var_unprivileged="0"

header_info "$APP"
color

function detect_openvino_default() {
  if grep -qm1 'avx' /proc/cpuinfo; then
    INSTALL_OPENVINO="yes"
  else
    INSTALL_OPENVINO="no"
  fi
}

function default_settings() {
  CTID="$NEXTID"
  PW=""
  HN="$NSAPP"
  DISK_SIZE="$var_disk"
  CORE_COUNT="$var_cpu"
  RAM_SIZE="$var_ram"
  BRG="vmbr0"
  NET="dhcp"
  GATE=""
  APT_CACHER=""
  APT_CACHER_IP=""
  IPV6="dhcp"
  MTU=""
  SD=""
  NS=""
  MAC=""
  VLAN=""
  SSH="no"
  VERB="no"
  detect_openvino_default
  echo_defaults
}

function advanced_settings() {
  while true; do
    CTID=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Set Container ID" 8 58 "$NEXTID" --title "CONTAINER ID" 3>&1 1>&2 2>&3) || exit
    if [ -z "$CTID" ]; then
      CTID="$NEXTID"
    fi
    [ -z "$(pct list | grep "^$CTID ")" ] && break
    echo -e "Container ID $CTID already exists. Please choose another."
  done
  PW=$(whiptail --backtitle "Proxmox VE Helper Scripts" --passwordbox "Set Root Password (leave blank for no password)" 9 58 --title "PASSWORD" 3>&1 1>&2 2>&3) || exit
  HN=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Set Hostname" 8 58 "$NSAPP" --title "HOSTNAME" 3>&1 1>&2 2>&3) || exit
  DISK_SIZE=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Set Disk Size in GB" 8 58 "$var_disk" --title "DISK SIZE" 3>&1 1>&2 2>&3) || exit
  CORE_COUNT=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Allocate CPU Cores" 8 58 "$var_cpu" --title "CORE COUNT" 3>&1 1>&2 2>&3) || exit
  RAM_SIZE=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Allocate RAM in MiB" 8 58 "$var_ram" --title "RAM" 3>&1 1>&2 2>&3) || exit
  BRG=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Set a Bridge" 8 58 "vmbr0" --title "BRIDGE" 3>&1 1>&2 2>&3) || exit
  NET=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Set a Static IPv4 CIDR Address (/24)" 8 58 "dhcp" --title "IP ADDRESS" 3>&1 1>&2 2>&3) || exit
  GATE=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Set a Gateway IP (mandatory if static IP was assigned)" 8 58 --title "GATEWAY IP" 3>&1 1>&2 2>&3) || exit
  SSH=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "SSH ACCESS" --radiolist "Allow Root SSH Access?" 10 58 2 \
    "yes" "Yes" OFF \
    "no" "No" ON \
    3>&1 1>&2 2>&3) || exit
  VERB=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "VERBOSE MODE" --radiolist "Enable Verbose Mode?" 10 58 2 \
    "yes" "Yes" OFF \
    "no" "No" ON \
    3>&1 1>&2 2>&3) || exit

  # OpenVino detector question
  detect_openvino_default
  if [ "$INSTALL_OPENVINO" = "yes" ]; then
    OV_DEFAULT="--defaultyes"
    OV_HINT="[Default: Yes — AVX detected]"
  else
    OV_DEFAULT="--defaultno"
    OV_HINT="[Default: No — AVX not detected on this CPU]"
  fi

  if whiptail --backtitle "Proxmox VE Helper Scripts" \
    --title "Frigate — Object Detector" \
    $OV_DEFAULT \
    --yesno "Install OpenVino Intel Object Detector?\n\nOpenVino enables hardware-accelerated detection using Intel AVX/AVX2 instructions or an Intel iGPU.\n\n⚠  Requires AVX support (Intel Sandy Bridge 2011 or newer).\n   CPUs WITHOUT AVX (e.g. Xeon X5650) will CRASH if OpenVino is selected.\n\n✅ AVX detected on this host: $(if grep -qm1 avx /proc/cpuinfo; then echo YES; else echo 'NO — select No'; fi)\n\nIf skipped, Frigate uses a CPU/TFLite detector which works on all hardware.\n\n$OV_HINT" 20 72; then
    INSTALL_OPENVINO="yes"
  else
    INSTALL_OPENVINO="no"
  fi

  echo_defaults
}

function update_script() {
  header_info
  check_container_storage
  check_container_resources
  if [[ ! -d /opt/frigate ]]; then
    msg_error "No ${APP} Installation Found!"
    exit
  fi
  RELEASE=$(curl -fsSL https://api.github.com/repos/blakeblackshear/frigate/releases/latest | grep '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/')
  msg_info "Stopping ${APP}"
  systemctl stop frigate go2rtc
  msg_ok "Stopped ${APP}"
  msg_info "Updating ${APP} to ${RELEASE}"
  cd /opt/frigate
  git fetch --depth 1 --tags
  git checkout "${RELEASE}"
  source /opt/frigate/venv/bin/activate
  pip install --upgrade pip -q
  pip install -r /opt/frigate/docker/main/requirements-wheels.txt -q
  msg_ok "Updated ${APP} to ${RELEASE}"
  msg_info "Starting ${APP}"
  systemctl start go2rtc frigate
  msg_ok "Started ${APP}"
}

start
build_container
# Write OpenVino choice into the container before install script runs
pct exec $CTID -- bash -c "echo 'INSTALL_OPENVINO=${INSTALL_OPENVINO}' > /tmp/frigate.conf"
description
