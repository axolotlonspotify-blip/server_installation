
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# AXO Server Installer
# Quelle: verschluesseltes Server-Backup auf Dropbox
# Ziel: Ubuntu 24.04, root

BACKUP_URL="https://www.dropbox.com/scl/fi/g1jwf5c2hlkaw0y5zfxya/projects-full.tar.gz.gpg?rlkey=9dm9k4vzfwx440kp4svil9rmo&dl=1"
DOMAIN="axo.sytes.net"

WORKDIR="$(mktemp -d /root/axo-restore.XXXXXX)"
cleanup() {
    rm -rf "$WORKDIR"
}
trap cleanup EXIT

log() {
    printf '\n\033[1;36m[AXO]\033[0m %s\n' "$*"
}

fail() {
    printf '\n\033[1;31mFEHLER:\033[0m %s\n' "$*" >&2
    exit 1
}

[[ "${EUID}" -eq 0 ]] || fail "Bitte als root ausfuehren."
[[ -r /etc/os-release ]] || fail "Ubuntu konnte nicht erkannt werden."
. /etc/os-release
[[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" == "24.04" ]] \
    || fail "Dieses Skript ist fuer Ubuntu 24.04 vorgesehen."

# Bestehende Installationen nicht versehentlich ueberschreiben.
if [[ -d /root/whatsapp-bot ||
      -d /root/bancheck-api ||
      -d /root/bancheck-test ||
      -f /etc/axo-bot-control/users.json ]]; then
    fail "Es wurden vorhandene AXO-Dateien gefunden. Abbruch zum Schutz vorhandener Daten. Nur auf einem frischen Server ausfuehren."
fi

log "Vorbereitung: benoetigte Systempakete installieren"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y \
    ca-certificates curl gnupg pinentry-curses tar gzip \
    nginx certbot python3-certbot-nginx git

log "Node.js 22 installieren"
curl -fsSL https://deb.nodesource.com/setup_22.x -o "$WORKDIR/nodesource.sh"
bash "$WORKDIR/nodesource.sh"
apt-get install -y nodejs

node --version
npm --version

log "PM2 installieren"
npm install --global pm2

log "Verschluesseltes Backup herunterladen"
curl --fail --location --show-error \
    --retry 3 --retry-delay 2 \
    "$BACKUP_URL" \
    --output "$WORKDIR/backup.tar.gz.gpg"

[[ -s "$WORKDIR/backup.tar.gz.gpg" ]] \
    || fail "Backup-Download ist leer."

log "GPG-Passphrase wird jetzt sicher abgefragt"
export GPG_TTY="$(tty 2>/dev/null || true)"
gpg --version >/dev/null

# GPG fragt die Passphrase ueber die konfigurierte Pinentry ab.
# Die Passphrase steht weder im Skript noch in der Kommandozeile.
gpg --output "$WORKDIR/backup.tar.gz" \
    --decrypt "$WORKDIR/backup.tar.gz.gpg"

log "Backup-Archiv auf Lesbarkeit pruefen"
tar -tzf "$WORKDIR/backup.tar.gz" > "$WORKDIR/archive-list.txt"

for required in \
    root/whatsapp-bot/index.js \
    root/bancheck-api/index.js \
    root/bancheck-test \
    var/www/html/api/status.js \
    etc/nginx \
    etc/letsencrypt \
    etc/axo-bot-control; do
    grep -Fq "$required" "$WORKDIR/archive-list.txt" \
        || fail "Im Backup fehlt der erwartete Pfad: $required"
done

log "Sicherung wiederherstellen"
# Erst nach erfolgreichem Download, Entschluesseln und Pruefen extrahieren.
tar --extract --gzip \
    --file "$WORKDIR/backup.tar.gz" \
    --directory / \
    --preserve-permissions \
    --same-owner

log "Dateirechte und Besitzer korrigieren"
chown -R root:root \
    /root/whatsapp-bot \
    /root/bancheck-api \
    /root/bancheck-test \
    /var/www/html

chmod 700 /etc/axo-bot-control 2>/dev/null || true
chmod 600 /etc/axo-bot-control/users.json 2>/dev/null || true
chmod 600 /root/bancheck-api/.env 2>/dev/null || true

log "npm-Abhaengigkeiten installieren"
for project in \
    /root/whatsapp-bot \
    /root/bancheck-api \
    /root/bancheck-test; do

    [[ -f "$project/package.json" ]] \
        || fail "package.json fehlt: $project"

    cd "$project"

    if [[ -f package-lock.json ]]; then
        npm ci --omit=dev
    else
        npm install --omit=dev
    fi
done

log "PM2-Konfiguration vorbereiten"
systemctl daemon-reload

# Der gesicherte PM2-Dump enthaelt die drei laufenden Anwendungen.
[[ -f /root/.pm2/dump.pm2 ]] \
    || fail "PM2-Dump fehlt im Backup."

log "Nginx-Konfiguration testen"
nginx -t

log "Dienste aktivieren"
systemctl enable nginx
systemctl restart nginx

if systemctl list-unit-files | grep -q '^pm2-root\.service'; then
    systemctl enable pm2-root
fi

log "Gespeicherte PM2-Prozesse starten"
export PM2_HOME=/root/.pm2
pm2 resurrect

# Sicherstellen, dass der gespeicherte Prozessstand erhalten bleibt.
pm2 save --force

log "Grundlegende Dienste pruefen"
systemctl --no-pager --full status nginx || true
pm2 list

log "Lokale API-Endpunkte testen"
if curl --fail --silent --show-error \
    --max-time 10 http://127.0.0.1:3001/api/status \
    -o "$WORKDIR/status-response.json"; then
    echo "Website-Status-API: erreichbar"
else
    echo "WARNUNG: Website-Status-API antwortet noch nicht."
fi

if curl --fail --silent --show-error \
    --max-time 10 http://127.0.0.1:3080/ \
    -o /dev/null; then
    echo "Bancheck-API auf Port 3080: erreichbar"
else
    echo "Hinweis: Bancheck-API hat auf / nicht geantwortet; das kann bei einem anderen API-Pfad normal sein."
fi

log "Installation abgeschlossen"
echo
echo "Domain: https://${DOMAIN}"
echo "Website-Dateien: /var/www/html"
echo "WhatsApp-Bot: /root/whatsapp-bot"
echo "Bancheck-API: /root/bancheck-api"
echo "Bancheck-Test: /root/bancheck-test (nicht automatisch gestartet)"
echo
echo "PM2-Status:"
pm2 list
echo
echo "WICHTIG: DNS bei No-IP auf die neue Server-IP setzen."
echo "Danach HTTPS und die Website von aussen pruefen."
