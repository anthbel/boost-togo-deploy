#!/usr/bin/env bash
# Prepares a stock Ubuntu server (22.04 or later, x86_64) for the BOOST Togo
# package. Run once as root, before ./install.sh:
#
#   sudo ./prerequisites.sh [--user boost] [--no-firewall] [--ssh-keys-only]
#                           [--no-swap] [--no-nginx]
#
# Installs Docker Engine with the compose plugin (Docker's apt repository),
# make, curl, openssl, Nginx, fail2ban and unattended security upgrades;
# creates the service account and its directories; and applies the host
# settings below. Safe to run again: each step leaves what is already in place.
#
#   Docker      daemon.json: container log rotation, live-restore,
#               no-new-privileges (keys already set are kept)
#   Firewall    ufw: incoming SSH, 80 and 443 only
#   SSH         drop-in: no root password login, 4 attempts, 30 s to log in,
#               no X11; --ssh-keys-only also disables password login
#   Kernel      sysctl: low swappiness, no ICMP redirects or source routing
#   Memory      2 GB swap file when the server has none and 8 GB RAM or less
#   Logs        journald capped at 500 MB, /var/log/boost-togo rotated weekly
#
# Needs outbound HTTPS to the Ubuntu mirrors and download.docker.com.
set -euo pipefail

BOOST_USER=boost
FIREWALL=1
SSH_KEYS_ONLY=0
SWAP=1
NGINX=1

usage() { sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
while [ $# -gt 0 ]; do
  case "$1" in
    --user) BOOST_USER="${2:?--user needs a name}"; shift 2 ;;
    --no-firewall) FIREWALL=0; shift ;;
    --ssh-keys-only) SSH_KEYS_ONLY=1; shift ;;
    --no-swap) SWAP=0; shift ;;
    --no-nginx) NGINX=0; shift ;;
    -h|--help) usage 0 ;;
    *) echo "option inconnue : $1" >&2; usage 2 ;;
  esac
done

die() { echo "ERREUR : $*" >&2; exit 1; }
warn() { echo "ATTENTION : $*" >&2; }
step() { echo; echo "== $*"; }

# Writes $2 to file $1 when the content differs; returns 0 if it changed.
write_if_changed() {
  local path="$1" content="$2"
  if [ -f "$path" ] && [ "$(cat "$path")" = "$content" ]; then
    return 1
  fi
  printf '%s\n' "$content" > "$path"
  return 0
}

step "Vérification du système"
[ "$(id -u)" -eq 0 ] || die "à lancer en root : sudo $0"
[ -r /etc/os-release ] || die "/etc/os-release introuvable"
# shellcheck source=/dev/null
. /etc/os-release
[ "${ID:-}" = ubuntu ] || die "système ${PRETTY_NAME:-inconnu} : ce script ne prend en charge qu'Ubuntu"
case "$VERSION_ID" in
  22.04|24.04|26.04) ;;
  *) warn "Ubuntu $VERSION_ID n'est pas une version LTS testée (22.04, 24.04, 26.04)" ;;
esac
case "$(uname -m)" in
  x86_64) ;;
  aarch64) warn "serveur ARM (aarch64) : le paquet BOOST est construit pour x86_64" ;;
  *) die "architecture $(uname -m) non prise en charge" ;;
esac
echo "$PRETTY_NAME, $(uname -m), $(nproc) CPU, $(awk '/MemTotal/ {printf "%.1f", $2/1048576}' /proc/meminfo) Go de mémoire"

export DEBIAN_FRONTEND=noninteractive

step "Paquets de base"
apt-get update -q
packages=(ca-certificates curl gnupg make openssl tar coreutils logrotate
          ufw fail2ban python3-systemd unattended-upgrades)
[ "$NGINX" = 1 ] && packages+=(nginx)
apt-get install -y -q --no-install-recommends "${packages[@]}"
echo "make $(make --version | head -1 | awk '{print $3}')"

step "Docker Engine"
if command -v docker >/dev/null && docker compose version >/dev/null 2>&1; then
  echo "déjà installé : $(docker --version), $(docker compose version)"
else
  for pkg in docker.io docker-compose docker-compose-v2 docker-doc podman-docker; do
    if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed'; then
      die "le paquet Ubuntu $pkg est installé ; le désinstaller d'abord (voir https://docs.docker.com/engine/install/ubuntu/)"
    fi
  done
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${UBUNTU_CODENAME:-$VERSION_CODENAME}
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF
  apt-get update -q
  apt-get install -y -q docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  echo "$(docker --version), $(docker compose version)"
fi

step "Configuration de Docker (/etc/docker/daemon.json)"
install -m 0755 -d /etc/docker
daemon_changed=$(python3 - /etc/docker/daemon.json <<'PY'
import json, os, sys
path = sys.argv[1]
config = {}
if os.path.exists(path) and os.path.getsize(path) > 0:
    with open(path) as f:
        config = json.load(f)
wanted = {
    "log-driver": "json-file",
    "log-opts": {"max-size": "10m", "max-file": "5"},
    "live-restore": True,
    "no-new-privileges": True,
}
added = [k for k in wanted if k not in config]
for key in added:
    config[key] = wanted[key]
for key in wanted:
    if key not in added and config[key] != wanted[key]:
        print(f"conservé : {key} = {json.dumps(config[key])}", file=sys.stderr)
if added:
    if os.path.exists(path):
        os.replace(path, path + ".bak")
    with open(path, "w") as f:
        json.dump(config, f, indent=2)
        f.write("\n")
print("yes" if added else "no")
PY
)
systemctl enable --now docker >/dev/null 2>&1 || true
if [ "$daemon_changed" = yes ]; then
  systemctl restart docker
  echo "daemon.json mis à jour, Docker redémarré"
else
  echo "daemon.json déjà conforme"
fi
docker info --format 'Docker {{.ServerVersion}}, journaux {{.LoggingDriver}}, live-restore {{.LiveRestoreEnabled}}' \
  || die "le démon Docker ne répond pas"

step "Compte de service « $BOOST_USER » et répertoires"
if id "$BOOST_USER" >/dev/null 2>&1; then
  echo "compte $BOOST_USER existant"
else
  useradd --create-home --shell /bin/bash --comment "BOOST Togo" "$BOOST_USER"
  echo "compte $BOOST_USER créé (sans mot de passe : sudo -iu $BOOST_USER)"
fi
usermod -aG docker "$BOOST_USER"
install -d -o "$BOOST_USER" -g "$BOOST_USER" -m 0750 /opt/boost-togo /var/backups/boost-togo /var/log/boost-togo
echo "/opt/boost-togo (paquets), /var/backups/boost-togo (sauvegardes), /var/log/boost-togo (journaux)"
write_if_changed /etc/logrotate.d/boost-togo "/var/log/boost-togo/*.log {
    weekly
    rotate 8
    compress
    delaycompress
    missingok
    notifempty
    su $BOOST_USER $BOOST_USER
}" && echo "rotation de /var/log/boost-togo configurée" || true

step "Pare-feu (ufw)"
if [ "$FIREWALL" = 1 ]; then
  ssh_ports=$(sshd -T 2>/dev/null | awk '$1 == "port" {print $2}' | sort -u || true)
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  for port in ${ssh_ports:-22}; do ufw allow "$port/tcp" comment 'SSH' >/dev/null; done
  ufw allow 80/tcp comment 'HTTP' >/dev/null
  ufw allow 443/tcp comment 'HTTPS' >/dev/null
  ufw --force enable >/dev/null
  ufw status verbose | sed -n '1,/^$/p'
  ufw status | tail -n +4
else
  echo "ignoré (--no-firewall)"
fi

step "SSH"
if [ -d /etc/ssh/sshd_config.d ] && command -v sshd >/dev/null; then
  ssh_conf="PermitRootLogin prohibit-password
MaxAuthTries 4
LoginGraceTime 30
X11Forwarding no
PermitEmptyPasswords no"
  if [ "$SSH_KEYS_ONLY" = 1 ]; then
    admin="${SUDO_USER:-root}"
    keys="$(getent passwd "$admin" | cut -d: -f6)/.ssh/authorized_keys"
    if [ -s "$keys" ]; then
      ssh_conf="$ssh_conf
PasswordAuthentication no
KbdInteractiveAuthentication no"
    else
      warn "--ssh-keys-only ignoré : $admin n'a pas de clé dans $keys (risque de perdre l'accès)"
    fi
  fi
  # Read before 50-cloud-init.conf: sshd keeps the first value it reads.
  drop_in=/etc/ssh/sshd_config.d/10-boost-togo.conf
  if write_if_changed "$drop_in" "$ssh_conf"; then
    if sshd -t; then
      systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
      echo "réglages appliqués ($drop_in)"
    else
      rm -f "$drop_in"
      warn "configuration SSH refusée par sshd -t : réglages non appliqués"
    fi
  else
    echo "réglages déjà en place ($drop_in)"
  fi
  write_if_changed /etc/fail2ban/jail.d/boost-togo.local "[sshd]
enabled = true
backend = systemd" || true
  systemctl enable fail2ban >/dev/null 2>&1 || true
  systemctl restart fail2ban || warn "fail2ban n'a pas démarré (journalctl -u fail2ban)"
  sleep 1
  fail2ban-client status sshd 2>/dev/null | sed -n '1p' || warn "prison fail2ban sshd inactive"
else
  echo "serveur SSH absent : ignoré"
fi

step "Mises à jour de sécurité automatiques"
write_if_changed /etc/apt/apt.conf.d/20auto-upgrades 'APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";' || true
systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true
echo "paquets de sécurité Ubuntu installés chaque jour (Docker n'est pas mis à jour automatiquement)"

step "Noyau (sysctl)"
if write_if_changed /etc/sysctl.d/90-boost-togo.conf "vm.swappiness = 10
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.tcp_syncookies = 1
kernel.dmesg_restrict = 1"; then
  sysctl -q -p /etc/sysctl.d/90-boost-togo.conf || warn "certains réglages sysctl n'ont pas été appliqués"
fi
echo "vm.swappiness = $(sysctl -n vm.swappiness)"

step "Mémoire d'échange (swap)"
if [ "$SWAP" = 0 ]; then
  echo "ignoré (--no-swap)"
elif [ -n "$(swapon --show --noheadings)" ]; then
  echo "déjà présente : $(swapon --show --noheadings | awk '{print $1, $3}' | paste -sd ' ' -)"
else
  mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
  free_kb=$(df --output=avail -k / | tail -1)
  if [ "$mem_kb" -gt $((8 * 1024 * 1024)) ]; then
    echo "non créée : plus de 8 Go de mémoire"
  elif [ "$free_kb" -lt $((6 * 1024 * 1024)) ]; then
    warn "swap non créée : moins de 6 Go libres sur /"
  elif fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap -q /swapfile && swapon /swapfile; then
    grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    echo "fichier /swapfile de 2 Go actif"
  else
    swapoff /swapfile 2>/dev/null || true
    rm -f /swapfile
    warn "swap non créée (le système l'a refusée)"
  fi
fi

step "Journal système et heure"
install -m 0755 -d /etc/systemd/journald.conf.d
if write_if_changed /etc/systemd/journald.conf.d/boost-togo.conf "[Journal]
SystemMaxUse=500M"; then
  systemctl restart systemd-journald || true
fi
echo "journal système limité à 500 Mo"
timedatectl set-ntp true 2>/dev/null || warn "synchronisation de l'heure non activée (timedatectl)"
timedatectl show --property=NTPSynchronized --property=Timezone 2>/dev/null | paste -sd ' ' - || true

if [ "$NGINX" = 1 ]; then
  step "Nginx"
  write_if_changed /etc/nginx/conf.d/00-boost-togo-security.conf "server_tokens off;" || true
  nginx -t 2>&1 | tail -1
  systemctl enable --now nginx >/dev/null 2>&1 || true
  systemctl reload nginx 2>/dev/null || true
  echo "installé ; le site HTTPS se configure après l'installation (docs/02-installation.md §2.8)"
fi

step "Terminé"
cat <<EOF
Docker  : $(docker --version)
Compose : $(docker compose version --short)
make    : $(make --version | head -1)

Suite :
  sudo -iu $BOOST_USER
  cd /opt/boost-togo
  (copier le paquet ici, vérifier sa somme de contrôle et l'extraire, docs/02-installation.md §2.3)
  cd boost-togo-<version> && make install

Le tableau de bord n'écoute que sur 127.0.0.1:8080 (DASHBOARD_BIND). Docker publie ses ports
sans passer par ufw : ne pas remplacer cette adresse par 0.0.0.0.
Les membres du groupe docker ont des droits équivalents à root sur ce serveur.
EOF
