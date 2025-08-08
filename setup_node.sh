#!/usr/bin/env bash
set -euo pipefail

### === CONFIGURABLE ===
PBS_QUEUE_NAME="hpcc"
SSH_USER_ON_SERVER="root"
PBS_POSTINSTALL_ON_SERVER=false
### ====================

# --- helpers ---
log() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }
err() { echo "[ERROR] $*" >&2; }
fatal() { err "$*"; exit 1; }

backup_file() {
  local file="$1"
  if [ -f "$file" ] && [ ! -f "${file}.bak" ]; then
    cp "$file" "${file}.bak"
    log "Backed up $file to ${file}.bak"
  fi
}

usage() {
  cat <<EOF
Usage: $0 <new-hostname> <head-node-ip>

Example:
  sudo $0 node01 192.168.56.100

EOF
  exit 1
}

# --- ARGUMENTS ---
if [ $# -ne 2 ]; then
  usage
fi

NEW_HOSTNAME="$1"
HEAD_IP="$2"
read -sp "Enter password for ${SSH_USER_ON_SERVER}@${HEAD_IP}: " SERVER_PASSWORD
echo

if [ "$(id -u)" -ne 0 ]; then
  fatal "Script must be run as root."
fi

# 3. Set the hostname to a unique name (e.g., node02, node03). 
echo "-----------------------------------------------------------------------------------------"
log "1. Hostname setup"
hostnamectl set-hostname "$NEW_HOSTNAME"
log "Hostname set to '$NEW_HOSTNAME'"

echo "-----------------------------------------------------------------------------------------"
log "2. Network interface autoconnect setup"
IFACE=$(nmcli device status | awk '/ethernet/ {print $1; exit}')
if [ -z "$IFACE" ]; then
  fatal "No Ethernet interface found."
fi

CON_NAME=$(nmcli -t -f NAME,DEVICE con show --active | grep "^.*:${IFACE}$" | cut -d: -f1)
if [ -z "$CON_NAME" ]; then
  CON_NAME=$(nmcli -t -f NAME,DEVICE con show | grep ":${IFACE}$" | cut -d: -f1 | head -n1)
fi
if [ -z "$CON_NAME" ]; then
  fatal "No connection found for interface $IFACE"
fi

nmcli connection modify "$CON_NAME" connection.autoconnect yes
nmcli connection up "$CON_NAME" || warn "Failed to bring up connection $CON_NAME (it may already be up)"
log "Auto-connect enabled and brought up: $CON_NAME on $IFACE"



# 6. Install NFS utilities and mount the shared directory (e.g., /ddn) from the head node. 
# Ensure the mount is persistent by updating /etc/fstab. 
# 6A: modify the repo files and mount cdrom
echo "-----------------------------------------------------------------------------------------"
log "3. Repository setup (disable base/updates/extras, enable c7-media)"
BASE_REPO="/etc/yum.repos.d/CentOS-Base.repo"
MEDIA_REPO="/etc/yum.repos.d/CentOS-Media.repo"

if [ -f "$BASE_REPO" ]; then
  backup_file "$BASE_REPO"
  sed -i '/^\[base\]/,/^gpgkey=/s/^gpgcheck=1/&\nenabled=0/' "$BASE_REPO" || true
  sed -i '/^\[updates\]/,/^gpgkey=/s/^gpgcheck=1/&\nenabled=0/' "$BASE_REPO" || true
  sed -i '/^\[extras\]/,/^gpgkey=/s/^gpgcheck=1/&\nenabled=0/' "$BASE_REPO" || true
  log "Modified $BASE_REPO to disable base/updates/extras"
else
  warn "$BASE_REPO not found."
fi

if [ -f "$MEDIA_REPO" ]; then
  backup_file "$MEDIA_REPO"
  sed -i '/^\[c7-media\]/,/^gpgkey=/s/^enabled=0/enabled=1/' "$MEDIA_REPO" || true
  log "Enabled c7-media repo."
else
  fatal "$MEDIA_REPO not found."
fi

log "Creating and attempting to mount /media/cdrom"
mkdir -p /media/cdrom
if mountpoint -q /media/cdrom; then
  log "/media/cdrom already mounted"
else
  if mount /dev/sr0 /media/cdrom 2>/dev/null; then
    log "Mounted /dev/sr0 at /media/cdrom"
  else
    warn "Failed to mount /dev/sr0; continuing (maybe no media present)"
  fi
fi


# 6B: Install the NFS utilities and mount the shared folder
echo "-----------------------------------------------------------------------------------------"
log "4. Shared folder (NFS) setup"
yum install -y libnfsidmap.x86_64 nfs-utils.x86_64 nfs4-acl-tools.x86_64

FSTAB_LINE="${HEAD_IP}:/home /home nfs defaults 0 0"
grep -Fq "$FSTAB_LINE" /etc/fstab || echo "$FSTAB_LINE" >> /etc/fstab
log "Appended NFS share to /etc/fstab if not present"

systemctl restart nfs || warn "Failed to restart NFS service"
mount -a || warn "mount -a encountered issues"
log "Shared folder /home mounted (if reachable)"


# Syncing users from the head to the node.
echo "-----------------------------------------------------------------------------------------"
log "5. Sync user/group/shadow from shared path"
shared_path="/home/sync"
user_file="$shared_path/users.new"
group_file="$shared_path/groups.new"
shadow_file="$shared_path/shadow.new"

if [ -r "$user_file" ]; then
  while IFS= read -r line; do
    uname=$(echo "$line" | cut -d: -f1)
    sed -i "/^${uname}:/d" /etc/passwd
    echo "$line" >> /etc/passwd
  done < "$user_file"
  log "Synced /etc/passwd from $user_file"
else
  warn "$user_file not readable or missing; skipping passwd sync"
fi

if [ -r "$group_file" ]; then
  while IFS= read -r line; do
    gname=$(echo "$line" | cut -d: -f1)
    sed -i "/^${gname}:/d" /etc/group
    echo "$line" >> /etc/group
  done < "$group_file"
  log "Synced /etc/group from $group_file"
else
  warn "$group_file not readable or missing; skipping group sync"
fi

if [ -r "$shadow_file" ]; then
  while IFS= read -r line; do
    uname=$(echo "$line" | cut -d: -f1)
    sed -i "/^${uname}:/d" /etc/shadow
    echo "$line" >> /etc/shadow
  done < "$shadow_file"
  log "Synced /etc/shadow from $shadow_file"
else
  warn "$shadow_file not readable or missing; skipping shadow sync"
fi


# 4. Update the /etc/hosts file to include the head node and both compute nodes' IP addresses.
echo "-----------------------------------------------------------------------------------------"
log "6. Copy /etc/hosts from HEAD_IP using expect"
yum install -y expect

REMOTE_HOSTS="/etc/hosts"
LOCAL_HOSTS="/etc/hosts"
HOSTIP=$(hostname -I)

expect <<EOF
set timeout 20
spawn ssh -o StrictHostKeyChecking=no root@${HEAD_IP}
expect {
  "*?assword:" {
    send "${SERVER_PASSWORD}\r"
  }
}
expect "#"
send "echo ${HOSTIP} ${NEW_HOSTNAME} >> /etc/hosts \r"
expect "#"
send "exit\r"
EOF

copy_hosts_expect() {
  expect <<EOF
set timeout 30
spawn scp -o StrictHostKeyChecking=no ${SSH_USER_ON_SERVER}@${HEAD_IP}:${REMOTE_HOSTS} ${LOCAL_HOSTS}
expect {
  -re "(P|p)assword:" {
    send "${SERVER_PASSWORD}\r"
    exp_continue
  }
  eof
}
EOF
}

backup_file /etc/hosts
copy_hosts_expect && log "Copied /etc/hosts from ${HEAD_IP}" || warn "Failed to copy /etc/hosts; continuing"


# 5. Generate or copy an SSH public key from the head node and place it in
# the compute node’s ~/.ssh/authorized_keys file for passwordless login. 
echo "-----------------------------------------------------------------------------------------"
log "7. SSH key exchange"
NODE_SSH_DIR="$HOME/.ssh"
mkdir -p "$NODE_SSH_DIR"
chmod 700 "$NODE_SSH_DIR"
KNOWN_HOSTS="$NODE_SSH_DIR/known_hosts"
AUTHORIZED_KEYS="$NODE_SSH_DIR/authorized_keys"
touch "$AUTHORIZED_KEYS"
chmod 600 "$AUTHORIZED_KEYS"

ssh-keyscan -H "$HEAD_IP" >> "$KNOWN_HOSTS" 2>/dev/null || true
chmod 600 "$KNOWN_HOSTS"

TMP_KEY_FILE="$(mktemp /tmp/server_pubkey.XXXXXX)"
cleanup() { rm -f "$TMP_KEY_FILE"; }
trap cleanup EXIT

log "Attempting to fetch server public key (~/.ssh/id_rsa.pub) via expect"
expect <<EOF
set timeout 30
spawn scp -o StrictHostKeyChecking=no ${SSH_USER_ON_SERVER}@${HEAD_IP}:~/.ssh/id_rsa.pub ${TMP_KEY_FILE}
expect {
  -re "(P|p)assword:" {
    send "${SERVER_PASSWORD}\r"
    exp_continue
  }
  eof
}
EOF

if [[ -s "$TMP_KEY_FILE" ]]; then
  PUBKEY_LINE=$(head -n1 "$TMP_KEY_FILE" | tr -d '\r\n')
  if [[ "$PUBKEY_LINE" =~ ^ssh-(rsa|ed25519|ed448|ecdsa) ]]; then
    if grep -Fxq "$PUBKEY_LINE" "$AUTHORIZED_KEYS"; then
      log "Server public key already in authorized_keys"
    else
      echo "$PUBKEY_LINE" >> "$AUTHORIZED_KEYS"
      log "Appended server public key to authorized_keys"
    fi
  else
    warn "Invalid SSH key: $PUBKEY_LINE"
  fi
else
  warn "Failed to fetch server public key"
fi


# 7. Install the PBS MOM package (e.g., pbspro-execution) using your package manager (e.g., yum). 
echo "-----------------------------------------------------------------------------------------"
log "8. PBS node setup"
sed -i 's/^SELINUX=.*/SELINUX=disabled/' /etc/selinux/config || true
if command -v getenforce >/dev/null; then
  [ "$(getenforce)" != "Permissive" ] && setenforce 0 || true
fi

systemctl stop firewalld || true
systemctl disable firewalld || true

yum install -y /home/pbs/pbspro-execution-19.1.3-0.x86_64.rpm /home/pbs/environment-modules || warn "PBS packages may not exist"

# 8. Configure PBS by adding the head node’s hostname into the MOM configuration file: 
# /var/spool/pbs/mom_priv/config. 
if grep -q '^PBS_SERVER=' /etc/pbs.conf 2>/dev/null; then
  sed -i "s/^PBS_SERVER=.*/PBS_SERVER=${HEAD_IP}/" /etc/pbs.conf
else
  echo "PBS_SERVER=${HEAD_IP}" >> /etc/pbs.conf
fi

MOM_CONFIG="/var/spool/pbs/mom_priv/config"
if [ -f "$MOM_CONFIG" ]; then
  sed -i "s/^\$clienthost.*/\$clienthost ${HEAD_IP}/" "$MOM_CONFIG" || echo "\$clienthost ${HEAD_IP}" >> "$MOM_CONFIG"
else
  mkdir -p "$(dirname "$MOM_CONFIG")"
  echo "\$clienthost ${HEAD_IP}" > "$MOM_CONFIG"
fi

# 9. Enable and start the PBS service using systemctl: systemctl enable pbs && systemctl start pbs.
[ -x /etc/init.d/pbs ] && /etc/init.d/pbs start || warn "PBS init script not found"
service pbs restart || warn "PBS restart failed"

echo "-----------------------------------------------------------------------------------------"
echo "=== Adding node to PBS queue on head node ==="

expect <<EOF
set timeout 20
spawn ssh -o StrictHostKeyChecking=no root@${HEAD_IP}
expect {
  "*?assword:" {
    send "${SERVER_PASSWORD}\r"
  }
}
expect "#"
send "qmgr -c \"create node ${NEW_HOSTNAME}\"\r"
expect "#"
send "qmgr -c \"set node ${NEW_HOSTNAME} queue=${PBS_QUEUE_NAME}\"\r"
expect "#"
send "exit\r"
EOF

echo "=== Done! Node ${NEW_HOSTNAME} added to queue ${PBS_QUEUE_NAME} ==="

exit 0
