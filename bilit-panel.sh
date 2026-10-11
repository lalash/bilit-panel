#!/usr/bin/env bash
# bilit-panel — the one command for this server (installed as /usr/local/bin/bilit-panel).
#   On a fresh server: a setup menu (prerequisites, install the site online or from a bundle file, the web installer).
#   On an installed server: the management menu (panel address and login, SSL, services, backups, updates, ...).
# Run as root:  bilit-panel        or directly:  bilit-panel show | restart | status | log | backup | setup-url
# First install on a fresh server (this script lives in the public repo lalash/bilit-panel; the site's code does not):
#   bash <(curl -Ls https://raw.githubusercontent.com/lalash/bilit-panel/main/install.sh)
# All text is English on purpose: terminals mix up right-to-left text.
set -uo pipefail

STACK=/opt/bilit
C=bilit-ops
REPO=lalash/bilit-talaei
SELF_URL=https://raw.githubusercontent.com/lalash/bilit-panel/main/bilit-panel.sh
TOKEN_FILE=/root/.bilit-github-token
red='\033[0;31m'; green='\033[0;32m'; yellow='\033[0;33m'; blue='\033[0;36m'; plain='\033[0m'

[ "$(id -u)" -eq 0 ] || { echo -e "${red}Run as root (sudo bilit-panel).${plain}"; exit 1; }

installed()  { [ -f "$STACK/.env" ] && [ -f "$STACK/docker-compose.yml" ]; }
configured() { grep -q '^SITE_DOMAIN=.' "$STACK/.env" 2>/dev/null; }   # the domain was chosen (web installer or CLI install)
running()    { [ "$(docker inspect -f '{{.State.Running}}' $C 2>/dev/null)" = "true" ]; }
cli()        { docker exec -i $C node /app/cli.mjs "$@"; }
reload()     { docker kill -s HUP $C >/dev/null 2>&1 && docker exec bilit-caddy caddy reload --config /etc/caddy/Caddyfile >/dev/null 2>&1; }
need_running() { running || { echo -e "${yellow}The panel is stopped. Starting it...${plain}"; start; sleep 3; }; }
pause()      { echo; read -rp "Press Enter to return to the menu..." _; }
ok()         { echo -e "${green}$*${plain}"; }
warn()       { echo -e "${yellow}$*${plain}"; }
err()        { echo -e "${red}$*${plain}"; }

start()   { (cd "$STACK" && docker compose up -d ops) && ok "Panel started."; }
stop()    { (cd "$STACK" && docker compose stop ops) && ok "Panel stopped. (the website keeps running)"; }
restart() { (cd "$STACK" && docker compose restart ops) && ok "Panel restarted."; }

# ---------------------------------------------------------------- prerequisites
apt_wait() { local n=0; while pgrep -x 'apt|apt-get|dpkg|unattended-upgr' >/dev/null 2>&1; do [ $n = 0 ] && echo "   waiting for the system's automatic updates to finish..."; n=$((n+1)); [ $n -ge 200 ] && break; sleep 3; done; }
prerequisites() {
  . /etc/os-release 2>/dev/null || true
  [ "${ID:-}" = ubuntu ] || [ "${ID:-}" = debian ] || { err "Unsupported system '${PRETTY_NAME:-?}'. Use Ubuntu 22.04 or newer."; return 1; }
  export DEBIAN_FRONTEND=noninteractive
  echo -e "${blue}== System packages${plain}"
  apt_wait
  if timeout 300 apt-get update -q >/dev/null 2>&1; then
    apt-get -y -q -o DPkg::Lock::Timeout=300 install ca-certificates curl openssl tar gzip ufw fail2ban unattended-upgrades >/dev/null && ok "   curl, openssl, ufw, fail2ban, unattended-upgrades"
  else warn "   apt cannot reach a package mirror; continuing with what is installed"; fi
  echo -e "${blue}== Time zone and automatic security updates${plain}"
  timedatectl set-timezone UTC 2>/dev/null || true
  [ -d /etc/apt/apt.conf.d ] && printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\n' > /etc/apt/apt.conf.d/20auto-upgrades
  ok "   UTC clock, security updates install themselves"
  echo -e "${blue}== Swap${plain}"
  local mem; mem=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
  if [ "$(swapon --show --noheadings | wc -l)" -gt 0 ]; then ok "   already has swap"
  elif [ "$mem" -ge 8000 ]; then ok "   8 GB+ RAM: no swap needed"
  else
    fallocate -l 2G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
    chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile
    grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    ok "   2 GB swap file"
  fi
  echo -e "${blue}== Firewall${plain}"
  if command -v ufw >/dev/null; then
    local ports; ports=$(sshd -T 2>/dev/null | awk '$1=="port"{print $2}' | sort -u || true); [ -n "$ports" ] || ports=22
    for p in $ports; do ufw allow "$p/tcp" >/dev/null; done
    ufw allow 80/tcp >/dev/null; ufw allow 443/tcp >/dev/null; ufw allow 443/udp >/dev/null
    ufw default deny incoming >/dev/null; ufw default allow outgoing >/dev/null; ufw --force enable >/dev/null
    ok "   open: SSH ($(echo $ports | tr ' ' ',')), 80, 443"
  else warn "   ufw is not installed"; fi
  echo -e "${blue}== Fail2ban${plain}"
  if command -v fail2ban-client >/dev/null; then
    if [ ! -f /etc/fail2ban/jail.local ] || grep -q bilit /etc/fail2ban/jail.local; then
      printf '# bilit: 4 wrong passwords in 10 minutes -> banned 24 hours; 3 bans in a day -> 7 days\n[DEFAULT]\nbackend = systemd\nbanaction = ufw\nfindtime = 10m\n\n[sshd]\nenabled = true\nmaxretry = 4\nbantime = 24h\n\n[recidive]\nenabled = true\nlogpath = /var/log/fail2ban.log\nbackend = auto\nbantime = 7d\nfindtime = 1d\nmaxretry = 3\n' > /etc/fail2ban/jail.local
    fi
    systemctl enable fail2ban >/dev/null 2>&1; systemctl restart fail2ban && ok "   on"
  else warn "   fail2ban is not installed"; fi
  echo -e "${blue}== Docker${plain}"
  if docker compose version >/dev/null 2>&1; then ok "   already installed: $(docker --version | sed 's/,.*//')"
    # BuildKit (buildx): faster builds, and its cache stays in check (without it old build layers fill the disk)
    docker buildx version >/dev/null 2>&1 || { apt-get -y -q install docker-buildx >/dev/null 2>&1 || apt-get -y -q install docker-buildx-plugin >/dev/null 2>&1; } || true
  else
    apt_wait
    if timeout 900 sh -c 'curl -fsSL --max-time 30 https://get.docker.com -o /tmp/get-docker.sh && sh /tmp/get-docker.sh' >/dev/null 2>&1; then ok "   installed from download.docker.com"
    else
      warn "   download.docker.com is not reachable: using Ubuntu's own packages"
      apt-get -y -q install docker.io >/dev/null && { apt-get -y -q install docker-compose-v2 >/dev/null 2>&1 || apt-get -y -q install docker-compose-plugin >/dev/null 2>&1; }
      apt-get -y -q install docker-buildx >/dev/null 2>&1 || true
    fi
    rm -f /tmp/get-docker.sh
    systemctl enable --now docker >/dev/null 2>&1 || true
    docker compose version >/dev/null 2>&1 && ok "   Docker is ready" || { err "   Docker could not be installed. Use an offline bundle (option 3)."; return 1; }
  fi
  touch /etc/bilit-prerequisites
  echo; ok "Prerequisites done."
}

# ---------------------------------------------------------------- getting the site
run_install() {   # $1 = the folder that holds bilit/install.sh
  local args=()
  configured || args+=(--web)   # a new server: domains and the rest are chosen in the web installer
  bash "$1/bilit/install.sh" --yes "${args[@]}"
}

from_github() {
  command -v curl >/dev/null && command -v tar >/dev/null || { err "curl and tar are needed: run option 1 first."; return 1; }
  local tok=""
  [ -s "$TOKEN_FILE" ] && tok=$(cat "$TOKEN_FILE")
  if [ -z "$tok" ]; then
    echo "The site's code is in a private GitHub repository. A read-only token is needed:"
    echo "  GitHub -> Settings -> Developer settings -> Fine-grained tokens -> Generate new token"
    echo "  Repository access: Only select repositories -> $REPO"
    echo "  Permissions: Contents -> Read-only. Copy the token (github_pat_...)."
    read -rsp "Token (hidden): " tok; echo
    [ -n "$tok" ] || { err "No token given."; return 1; }
  fi
  echo -e "${blue}== Downloading the latest version${plain}"
  rm -rf /root/bilit-src /root/bilit-build /root/bilit-install; mkdir -p /root/bilit-src
  if ! curl -fsSL -H "Authorization: Bearer $tok" -H "Accept: application/vnd.github+json" "https://api.github.com/repos/$REPO/tarball/main" -o /root/bilit-src.tgz; then
    err "Download failed. Check the token (and that GitHub is reachable from this server; otherwise use an offline bundle)."
    rm -f /root/bilit-src.tgz; return 1
  fi
  if [ ! -s "$TOKEN_FILE" ]; then
    read -rp "Keep the token on this server for later updates? (root only) [Y/n] " k
    [ "${k:-y}" = n ] || { (umask 077; echo "$tok" > "$TOKEN_FILE"); ok "Token saved in $TOKEN_FILE"; }
  fi
  tar -C /root/bilit-src --strip-components=1 -xzf /root/bilit-src.tgz && rm -f /root/bilit-src.tgz
  bash /root/bilit-src/infra/make-bundle.sh --out /root/bilit-build >/dev/null || { err "Making the bundle failed."; return 1; }
  mkdir -p /root/bilit-install && tar -C /root/bilit-install -xzf "$(ls -t /root/bilit-build/bilit-*.tar.gz | head -1)"
  run_install /root/bilit-install
  rm -rf /root/bilit-src /root/bilit-build
}

from_file() {
  local files=() f
  for f in /root/bilit-*.tar.gz /root/*/bilit-*.tar.gz "$PWD"/bilit-*.tar.gz; do [ -f "$f" ] && files+=("$f"); done
  if [ ${#files[@]} -gt 0 ]; then echo "Bundle files found:"; for f in "${files[@]}"; do echo "  $f ($(du -h "$f" | cut -f1))"; done; fi
  read -rp "Path of the bundle file [${files[0]:-}]: " f
  f=${f:-${files[0]:-}}
  [ -f "$f" ] || { err "No such file: $f"; return 1; }
  [ -f "$f.sha256" ] && { (cd "$(dirname "$f")" && sha256sum -c "$(basename "$f").sha256" >/dev/null) && ok "Checksum OK" || { err "The file is damaged (checksum does not match)."; return 1; }; }
  rm -rf /root/bilit-install; mkdir -p /root/bilit-install
  tar -C /root/bilit-install -xzf "$f" || { err "Could not unpack $f"; return 1; }
  run_install /root/bilit-install
}

setup_url() {
  running || { err "The panel is not running yet. Install the site first (option 2 or 3)."; return 1; }
  cli setup-url
}

update_self() {
  local t; t=$(mktemp)
  if curl -fsSL "$SELF_URL" -o "$t" && head -1 "$t" | grep -q bash; then install -m 755 "$t" /usr/local/bin/bilit-panel; ok "bilit-panel updated. Run it again."; rm -f "$t"; exit 0
  else err "Could not download the menu (GitHub not reachable?)."; rm -f "$t"; fi
}

# ---------------------------------------------------------------- menus
setup_menu() {
  clear
  local state="fresh server"
  installed && state="installed, waiting for the web installer"
  echo -e "╔──────────────────────────────────────────────────╗
│   ${green}Bilit Talaei — Server Setup${plain}                    │
│   ${green}0.${plain} Exit                                        │
│──────────────────────────────────────────────────│
│   ${green}1.${plain} Install prerequisites                       │
│      (Docker, firewall, Fail2ban, swap)          │
│   ${green}2.${plain} Install the site - online (GitHub)          │
│   ${green}3.${plain} Install the site - offline (bundle file)    │
│   ${green}4.${plain} Show the web installer address              │
│──────────────────────────────────────────────────│
│   ${green}5.${plain} Update this menu (bilit-panel)              │
╚──────────────────────────────────────────────────╝"
  echo -e "  State: ${blue}${state}${plain}$([ -f /etc/bilit-prerequisites ] && echo -e "   Prerequisites: ${green}done${plain}")"
  echo
  read -rp "Please enter your selection [0-5]: " n
  case "$n" in
    0) exit 0 ;;
    1) prerequisites; pause ;;
    2) from_github; pause ;;
    3) from_file; pause ;;
    4) setup_url; pause ;;
    5) update_self; pause ;;
    *) err "Please enter a number between 0 and 5."; sleep 1 ;;
  esac
}

show_status() {
  local p s
  if running; then p="${green}running${plain}"; else p="${red}stopped${plain}"; fi
  if [ "$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' $C 2>/dev/null)" = "unless-stopped" ]; then s="${green}yes${plain}"; else s="${red}no${plain}"; fi
  echo -e "  Panel: $p   Autostart: $s"
  echo -n "  Site containers: "
  for n in bilit-web bilit-web-test bilit-db bilit-caddy; do
    st=$(docker inspect -f '{{.State.Status}}' $n 2>/dev/null || echo missing)
    [ "$st" = running ] && echo -ne "${green}${n#bilit-}${plain} " || echo -ne "${red}${n#bilit-}(${st})${plain} "
  done
  echo
}

restore_file() {
  local files=() f
  for f in $(ls -t /var/backups/bilit/bilit-*.tar.gz 2>/dev/null) /root/bilit-2*.tar.gz; do [ -f "$f" ] && files+=("$f"); done
  echo "Full server backups (made by option 15):"; for f in "${files[@]}"; do echo "  $f ($(du -h "$f" | cut -f1))"; done
  read -rp "Backup file to restore [${files[0]:-}]: " f
  f=${f:-${files[0]:-}}
  [ -f "$f" ] || { err "No such file: $f"; return 1; }
  warn "ALL data of both sites (users, orders, photos) is replaced by this backup. A backup of the current state is made first."
  read -rp "Type RESTORE to continue: " w
  [ "$w" = RESTORE ] || { echo "Cancelled."; return 0; }
  "$STACK/backup.sh" && "$STACK/restore.sh" "$f"
}

free_disk() {
  echo "Before: $(df -h / | awk 'NR==2{print $3" used, "$4" free"}')"
  docker image prune -f >/dev/null
  docker builder prune -af >/dev/null 2>&1 || true
  # unused images, except those the site needs to run and to back up (they cannot always be downloaded again)
  docker images --format '{{.Repository}}:{{.Tag}}' | grep -vE '^(alpine:3|postgres:18-alpine|caddy:2|bilit-web:prod|bilit-web:test|bilit-ops:latest)$' | grep -v '<none>' | xargs -r docker image rm >/dev/null 2>&1 || true
  journalctl --vacuum-time=14d >/dev/null 2>&1; apt-get -y -q clean
  echo "After:  $(df -h / | awk 'NR==2{print $3" used, "$4" free"}')"
}

make_bundle() {
  local cn
  read -rp "Ubuntu release of the TARGET server (jammy = 22.04, noble = 24.04) [noble]: " cn
  "$STACK/make-bundle.sh" --installed --offline --ubuntu "${cn:-noble}"
}

show_menu() {
  clear
  echo -e "╔──────────────────────────────────────────────────╗
│   ${green}Bilit Talaei — Server Panel Management${plain}         │
│   ${green}0.${plain} Exit                                        │
│──────────────────────────────────────────────────│
│   ${green}1.${plain} View panel address & login                  │
│   ${green}2.${plain} Reset username & password                   │
│   ${green}3.${plain} Reset panel path (secret address)           │
│   ${green}4.${plain} SSL / panel domain                          │
│──────────────────────────────────────────────────│
│   ${green}5.${plain} Start panel                                 │
│   ${green}6.${plain} Stop panel                                  │
│   ${green}7.${plain} Restart panel                               │
│   ${green}8.${plain} Check status                                │
│   ${green}9.${plain} Panel logs                                  │
│  ${green}10.${plain} Enable autostart                            │
│  ${green}11.${plain} Disable autostart                           │
│──────────────────────────────────────────────────│
│  ${green}12.${plain} Website status (all containers)             │
│  ${green}13.${plain} Restart the website                         │
│  ${green}14.${plain} Maintenance page on / off                   │
│  ${green}15.${plain} Full server backup now                      │
│  ${green}16.${plain} Telegram bot & alerts                       │
│──────────────────────────────────────────────────│
│  ${green}17.${plain} Enable BBR (faster network)                 │
│  ${green}18.${plain} Update the operating system                 │
│  ${green}19.${plain} Free disk space                             │
│  ${green}20.${plain} Uninstall panel (the website stays)         │
│──────────────────────────────────────────────────│
│  ${green}21.${plain} Update the site - online (GitHub)           │
│  ${green}22.${plain} Update the site - offline (bundle file)     │
│  ${green}23.${plain} Make an offline bundle (move server)        │
│  ${green}24.${plain} Restore from a full server backup           │
│  ${green}25.${plain} Update this menu (bilit-panel)              │
╚──────────────────────────────────────────────────╝"
  show_status
  echo
  read -rp "Please enter your selection [0-25]: " n
  cd "$STACK" || exit 1
  case "$n" in
    0) exit 0 ;;
    1) need_running; cli show; pause ;;
    2) need_running
       read -rp "New username (Enter = keep current): " u
       read -rsp "New password (Enter = random, min 10 chars): " pw; echo
       cli reset-cred "$u" "$pw" && reload; pause ;;
    3) need_running
       read -rp "New path (Enter = random): " pth
       cli reset-path "$pth" && reload; pause ;;
    4) need_running; ssl_menu ;;
    5) start; pause ;;
    6) stop; pause ;;
    7) restart; pause ;;
    8) show_status; docker ps --filter name=$C --format 'table {{.Names}}\t{{.Status}}'; pause ;;
    9) docker logs --tail 100 -f $C ;;
    10) docker update --restart unless-stopped $C >/dev/null && ok "Autostart enabled."; pause ;;
    11) docker update --restart no $C >/dev/null && warn "Autostart disabled."; pause ;;
    12) docker ps -a --filter name=bilit- --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'; echo; docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}' ; pause ;;
    13) read -rp "Restart the website now? It is down for a few seconds. [y/N] " y
        [ "$y" = y ] && docker compose restart web web-test && ok "Done."; pause ;;
    14) need_running
        read -rp "Maintenance page: on or off? [on/off] " m
        [ "$m" = on ] || [ "$m" = off ] && cli maintenance "$m" && reload; pause ;;
    15) "$STACK/backup.sh"; pause ;;
    16) need_running
        read -rp "Telegram bot token: " tok
        read -rp "Chat id for alerts (optional, Enter to skip; the group is set in the panel): " chat
        cli telegram "$tok" "$chat" && reload; pause ;;
    17) printf 'net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n' > /etc/sysctl.d/99-bbr.conf && sysctl --system >/dev/null && ok "BBR: $(sysctl -n net.ipv4.tcp_congestion_control)"; pause ;;
    18) apt-get update -q && DEBIAN_FRONTEND=noninteractive apt-get -y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold upgrade
        [ -f /var/run/reboot-required ] && warn "A restart of the server is needed: run  reboot  at a quiet hour."; pause ;;
    19) free_disk; pause ;;
    20) read -rp "Remove the server panel? The website is not touched. [y/N] " y
        if [ "$y" = y ]; then docker compose rm -sf ops; rm -f "$STACK/caddy/inner/10-ops.caddy" "$STACK/caddy/sites/10-ops.caddy" "$STACK/caddy/inner/20-maintenance.caddy"; docker exec bilit-caddy caddy reload --config /etc/caddy/Caddyfile >/dev/null 2>&1; ok "Panel removed. Its settings stay in $STACK/ops (delete by hand if wanted)."; fi; pause ;;
    21) read -rp "Update both sites to the latest version from GitHub? A full backup is made first. [y/N] " y; [ "$y" = y ] && from_github; pause ;;
    22) from_file; pause ;;
    23) make_bundle; pause ;;
    24) restore_file; pause ;;
    25) update_self; pause ;;
    *) err "Please enter a number between 0 and 25."; sleep 1 ;;
  esac
}

ssl_menu() {
  echo -e "
  ${green}1.${plain} Show certificates of all domains
  ${green}2.${plain} Give the panel its own domain (SSL automatic)
  ${green}3.${plain} Remove the panel domain (secret path on the main site only)
  ${green}0.${plain} Back"
  read -rp "Selection: " s
  case "$s" in
    1) cli certs ;;
    2) read -rp "Domain for the panel (its A record must point to this server): " d; cli set-domain "$d" && reload ;;
    3) cli set-domain none && reload ;;
  esac
  pause
}

menu() { if installed && configured; then show_menu; else setup_menu; fi; }

case "${1:-}" in
  show) cli show ;;
  start) start ;;
  stop) stop ;;
  restart) restart ;;
  status) show_status ;;
  log) docker logs --tail 100 -f $C ;;
  backup) "$STACK/backup.sh" ;;
  setup-url) setup_url ;;
  "") while true; do menu; done ;;
  *) echo "usage: bilit-panel [show|start|stop|restart|status|log|backup|setup-url]" ;;
esac
