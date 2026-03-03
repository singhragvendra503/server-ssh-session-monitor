#!/usr/bin/env bash
set -euo pipefail

WEBHOOK_URL=""
ENABLE_EIC_AUTO=true
SSH_LOG_GROUP="ssh-users"

usage() {
  cat <<'EOF'
Usage:
  sudo bash scripts/setup_ssh_monitoring.sh [--webhook <google_chat_webhook_url>] [--disable-eic] [--ssh-log-group <group_name>]

Options:
  --webhook <url>   Google Chat webhook URL used in /usr/local/bin/ssh-login-alert.sh
  --disable-eic     Do not configure AuthorizedKeysCommand for EC2 Instance Connect
  --ssh-log-group   Group with shared access to /var/log/ssh-sessions (default: ssh-users)
  -h, --help        Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --webhook)
      WEBHOOK_URL="${2:-}"
      shift 2
      ;;
    --disable-eic)
      ENABLE_EIC_AUTO=false
      shift
      ;;
    --ssh-log-group)
      SSH_LOG_GROUP="${2:-}"
      if [[ -z "$SSH_LOG_GROUP" ]]; then
        echo "--ssh-log-group requires a value"
        exit 1
      fi
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
done

if [[ ${EUID} -ne 0 ]]; then
  echo "Run as root (or with sudo)."
  exit 1
fi

if [[ ! -f /etc/os-release ]]; then
  echo "Cannot detect OS: /etc/os-release not found."
  exit 1
fi

source /etc/os-release

SSH_SERVICE="sshd"
if systemctl list-unit-files | grep -q '^ssh\.service'; then
  SSH_SERVICE="ssh"
fi

install_packages() {
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y auditd curl util-linux acl
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y audit util-linux acl
    if ! command -v curl >/dev/null 2>&1; then
      dnf install -y curl
    fi
  elif command -v yum >/dev/null 2>&1; then
    yum install -y audit util-linux acl
    if ! command -v curl >/dev/null 2>&1; then
      yum install -y curl
    fi
  else
    echo "No supported package manager found (apt-get/dnf/yum)."
    exit 1
  fi
}

ensure_line() {
  local file="$1"
  local line="$2"
  if ! grep -Fxq "$line" "$file" 2>/dev/null; then
    echo "$line" >> "$file"
  fi
}

write_banner() {
  cat <<'EOF' > /etc/issue.net
###########################################################################
#                                                                         #
#                         🚨  SECURITY WARNING  🚨                        #
#                                                                         #
#  This is a private system owned by XYZ Organization.                    #
#  Access is restricted to authorized users only.                         #
#                                                                         #
#  All SSH sessions are logged and monitored in real time.                #
#  Commands, keystrokes, and IP addresses are recorded.                   #
#                                                                         #
#  Unauthorized access will be prosecuted under applicable laws.          #
#                                                                         #
###########################################################################
EOF
}

write_session_recording() {
  mkdir -p /var/log/ssh-sessions

  cat <<'EOF' > /etc/profile.d/session-record.sh
# Run only once per SSH login and only for interactive shells
if [ -n "$SSH_CONNECTION" ] && [ -z "$SESSION_RECORDING" ] && [ -t 1 ]; then
    export SESSION_RECORDING=1
    LOG_FILE="/var/log/ssh-sessions/${USER}_$(date +%F_%T).log"
    exec script -q -f "$LOG_FILE"
fi
EOF
  chmod +x /etc/profile.d/session-record.sh
}

configure_shared_log_access() {
  local -A discovered_users=()
  local username home shell owner dir

  groupadd -f "$SSH_LOG_GROUP"

  while IFS=: read -r username _ _ _ _ home shell; do
    [[ "$home" == /home/* ]] || continue
    [[ "$shell" =~ (false|nologin)$ ]] && continue
    discovered_users["$username"]=1
  done < /etc/passwd

  if [[ -d /home ]]; then
    while IFS= read -r dir; do
      owner="$(stat -c '%U' "$dir" 2>/dev/null || true)"
      [[ -n "$owner" ]] || continue
      [[ "$owner" == "UNKNOWN" ]] && continue
      if id "$owner" >/dev/null 2>&1; then
        discovered_users["$owner"]=1
      fi
    done < <(find /home -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
  fi

  for username in "${!discovered_users[@]}"; do
    usermod -aG "$SSH_LOG_GROUP" "$username"
  done

  chown root:"$SSH_LOG_GROUP" /var/log/ssh-sessions
  chmod 2770 /var/log/ssh-sessions

  if command -v setfacl >/dev/null 2>&1; then
    setfacl -m g:"$SSH_LOG_GROUP":rwx /var/log/ssh-sessions
    setfacl -d -m g:"$SSH_LOG_GROUP":rwX /var/log/ssh-sessions
  else
    echo "setfacl not found; skipping ACL setup."
  fi

  if [[ ${#discovered_users[@]} -eq 0 ]]; then
    echo "No eligible users found under /home or /etc/passwd with /home paths."
  else
    echo "Added users to group '$SSH_LOG_GROUP': ${!discovered_users[*]}"
  fi
}

configure_sshd() {
  local sshd_conf="/etc/ssh/sshd_config"

  if [[ ! -f "$sshd_conf" ]]; then
    echo "Missing $sshd_conf"
    exit 1
  fi

  ensure_line "$sshd_conf" "Banner /etc/issue.net"

  if [[ "$ENABLE_EIC_AUTO" == "true" ]]; then
    local eic_cmd=""
    if [[ -x /opt/aws/bin/eic_run_authorized_keys ]]; then
      eic_cmd="/opt/aws/bin/eic_run_authorized_keys"
    elif [[ -x /usr/share/ec2-instance-connect/eic_run_authorized_keys ]]; then
      eic_cmd="/usr/share/ec2-instance-connect/eic_run_authorized_keys"
    fi

    if [[ -n "$eic_cmd" ]]; then
      ensure_line "$sshd_conf" "AuthorizedKeysCommand ${eic_cmd} %u %f"
      ensure_line "$sshd_conf" "AuthorizedKeysCommandUser ec2-instance-connect"
    else
      echo "EC2 Instance Connect binary not found; skipping AuthorizedKeysCommand setup."
    fi
  fi
}

write_login_alert_script() {
  local webhook="${WEBHOOK_URL}"
  if [[ -z "$webhook" ]]; then
    webhook="https://chat.googleapis.com/v1/spaces/REPLACE/messages?key=REPLACE&token=REPLACE"
    echo "No --webhook provided. Placeholder webhook written to /usr/local/bin/ssh-login-alert.sh"
  fi

  cat <<EOF > /usr/local/bin/ssh-login-alert.sh
#!/bin/bash

GOOGLE_CHAT_WEBHOOK="${webhook}"

USER="\$PAM_USER"
IP="\$PAM_RHOST"
HOST=\$(hostname)
TIME=\$(date)

text="🚨 *SSH Login Alert*

👤 User: \$USER
🌍 IP: \$IP
🖥 Host: \$HOST
⏰ Time: \$TIME"

curl -s -X POST "\$GOOGLE_CHAT_WEBHOOK" \\
  -H "Content-Type: application/json" \\
  -d "{\"text\": \"\$text\"}" \\
  --connect-timeout 10 > /dev/null 2>&1
EOF

  chmod +x /usr/local/bin/ssh-login-alert.sh
}

configure_pam() {
  local pam_file="/etc/pam.d/sshd"
  local pam_line="session optional pam_exec.so seteuid /usr/local/bin/ssh-login-alert.sh"

  if [[ ! -f "$pam_file" ]]; then
    echo "Missing $pam_file"
    exit 1
  fi

  ensure_line "$pam_file" "$pam_line"
}

write_audit_rules() {
  cat <<'EOF' > /etc/audit/rules.d/ssh.rules
-a always,exit -F arch=b64 -S execve -k ssh-monitor
-a always,exit -F arch=b32 -S execve -k ssh-monitor
-w /etc/ssh/sshd_config -p wa -k ssh_config_change
-w /etc/passwd -p wa -k user_change
-w /etc/sudoers -p wa -k sudo_change
EOF
}

reload_services() {
  if command -v augenrules >/dev/null 2>&1; then
    augenrules --load || true
  fi

  systemctl enable auditd
  augenrules --load || true
  systemctl restart "$SSH_SERVICE"
}

main() {
  echo "Detected OS: ${ID:-unknown}"
  echo "Using SSH service: $SSH_SERVICE"

  install_packages
  write_banner
  write_session_recording
  configure_shared_log_access
  configure_sshd
  write_login_alert_script
  configure_pam
  write_audit_rules
  reload_services

  echo "Setup complete."
  echo "Verify:"
  echo "  auditctl -l"
  echo "  ausearch -k ssh-monitor | tail"
  echo "  ls -lh /var/log/ssh-sessions/"
}

main
