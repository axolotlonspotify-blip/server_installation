
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# AXO Server Installer
# Ziel: frischer Ubuntu-24.04-Server
# Quelle: verschluesseltes Backup auf Dropbox

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

[[ "$EUID" -eq 0 ]] || fail "Bitte als root ausfuehren."
[[ -r /etc/os-release ]] || fail "OS-Version nicht ermittelbar."

. /etc/os-release
[[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" == "24.04" ]] \
    || fail "Dieser Installer ist fuer Ubuntu 24.04 vorgesehen."

# Schutz vor versehentlichem Ueberschreiben vorhandener AXO-Daten.
for path in \
    /root/whatsapp-bot \
    /root/bancheck-api \
    /root/bancheck-test \
    /etc/axo-bot-control/users.json; do
    [[ ! -e "$path" ]] || fail \
        "Vorhandene AXO-Dateien gefunden: $path. Abbruch zum Datenschutz."
done

log "Systempakete installieren"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y \
    ca-certificates curl gnupg pinentry-curses \
    tar gzip nginx certbot python3-certbot-nginx git

log "Node.js 22 installieren"
curl -fsSL https://deb.nodesource.com/setup_22.x \
    -o "$WORKDIR/nodesource.sh"
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

log "Backup sicher entschluesseln"
export GPG_TTY="$(tty 2>/dev/null || true)"
gpg --version >/dev/null

# Die Passphrase wird von GPG abgefragt und nicht im Skript gespeichert.
gpg --output "$WORKDIR/backup.tar.gz" \
    --decrypt "$WORKDIR/backup.tar.gz.gpg"

[[ -s "$WORKDIR/backup.tar.gz" ]] \
    || fail "Entschluesseltes Backup ist leer."

log "Archiv pruefen"
tar -tzf "$WORKDIR/backup.tar.gz" > "$WORKDIR/archive-list.txt"

# Unsichere Archivpfade vor dem Extrahieren ablehnen.
if grep -Eq '(^/|(^|/)\.\.(/|$))' "$WORKDIR/archive-list.txt"; then
    fail "Das Archiv enthaelt ungueltige Dateipfade."
fi

for required in \
    root/whatsapp-bot/index.js \
    root/whatsapp-bot/package-lock.json \
    root/bancheck-api/index.js \
    root/bancheck-api/package-lock.json \
    root/bancheck-test/package.json \
    var/www/html/api/status.js \
    etc/axo-bot-control/users.json \
    etc/nginx/sites-available/default \
    etc/letsencrypt/live/axo.sytes.net/fullchain.pem \
    etc/letsencrypt/live/axo.sytes.net/privkey.pem \
    etc/systemd/system/pm2-root.service \
    root/.pm2/dump.pm2; do
    grep -Fxq "$required" "$WORKDIR/archive-list.txt" \
        || fail "Im Backup fehlt: $required"
done

log "Sicherung wiederherstellen"
tar --extract --gzip \
    --file "$WORKDIR/backup.tar.gz" \
    --directory / \
    --preserve-permissions \
    --same-owner

log "Dateirechte setzen"
chown -R root:root \
    /root/whatsapp-bot \
    /root/bancheck-api \
    /root/bancheck-test \
    /var/www/html

chmod 700 /etc/axo-bot-control
chmod 600 /etc/axo-bot-control/users.json

if [[ -f /root/bancheck-api/.env ]]; then
    chmod 600 /root/bancheck-api/.env
fi

log "Node-Abhaengigkeiten installieren"
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
[[ -f /root/.pm2/dump.pm2 ]] || fail "PM2-Dump fehlt."

log "Nginx-Konfiguration pruefen"
nginx -t || fail "Nginx-Konfiguration ist ungueltig."

log "Nginx aktivieren und starten"
systemctl enable nginx
systemctl restart nginx
systemctl is-active --quiet nginx \
    || fail "Nginx konnte nicht gestartet werden."

log "PM2 fuer den Systemstart aktivieren"
systemctl enable pm2-root \
    || fail "PM2-Systemdienst konnte nicht aktiviert werden."

log "Gespeicherte Anwendungen starten"
export PM2_HOME=/root/.pm2
pm2 resurrect

# Bis zu 60 Sekunden auf die drei erwarteten Anwendungen warten.
log "Auf die drei Anwendungen warten"
ALL_ONLINE=0

for attempt in $(seq 1 30); do
    if pm2 jlist > "$WORKDIR/pm2.json" 2>/dev/null &&
       node - "$WORKDIR/pm2.json" <<'NODE'
const fs = require("fs");
const apps = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const expected = ["whatsapp-bot", "website-api", "bancheck-api"];
const ok = expected.every(name =>
    apps.some(app =>
        app.name === name &&
        app.pm2_env &&
        app.pm2_env.status === "online"
    )
);
process.exit(ok ? 0 : 1);
NODE
    then
        ALL_ONLINE=1
        break
    fi
    sleep 2
done

if [[ "$ALL_ONLINE" -ne 1 ]]; then
    echo
    echo "PM2-Status bei Fehler:"
    pm2 list || true
    fail "Nicht alle drei Anwendungen sind online. Siehe: pm2 logs"
fi

log "Website-Status-API pruefen"
API_OK=0

for attempt in $(seq 1 15); do
    if curl --fail --silent --show-error \
        --max-time 5 \
        http://127.0.0.1:3001/api/status \
        -o "$WORKDIR/status-response.json"; then
        API_OK=1
        break
    fi
    sleep 2
done

[[ "$API_OK" -eq 1 ]] \
    || fail "Die Website-Status-API antwortet nicht. Pruefe: pm2 logs website-api"

log "Bancheck-API-Port pruefen"
if ! node - <<'NODE'
const net = require("net");
const socket = net.createConnection({
    host: "127.0.0.1",
    port: 3080
});
socket.setTimeout(5000);
socket.on("connect", () => {
    socket.end();
    process.exit(0);
});
socket.on("error", () => process.exit(1));
socket.on("timeout", () => {
    socket.destroy();
    process.exit(1);
});
NODE
then
    fail "Bancheck-API ist online laut PM2, aber Port 3080 ist nicht erreichbar."
fi

log "PM2-Prozessstand speichern"
pm2 save --force

echo
echo "=========================================="
echo " AXO-WIEDERHERSTELLUNG ERFOLGREICH"
echo "=========================================="
echo
echo "Domain: https://${DOMAIN}"
echo "Website: /var/www/html"
echo "WhatsApp-Bot: /root/whatsapp-bot"
echo "Bancheck-API: /root/bancheck-api"
echo "Bancheck-Test: /root/bancheck-test (nicht gestartet)"
echo
echo "PM2-Status:"
pm2 list
echo
echo "Nginx: $(systemctl is-active nginx)"
echo "Website-Status-API: erreichbar"
echo "Bancheck-API-Port 3080: erreichbar"
echo
echo "WICHTIG:"
echo "1. DNS bei No-IP auf die neue Server-IP setzen."
echo "2. Ports 80 und 443 in der Firewall freigeben."
echo "3. HTTPS und die Website von aussen pruefen."
echo "4. Bei Problemen: pm2 logs"
