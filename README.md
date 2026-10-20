# CipherMail Community Gateway als Container

Baut die [CipherMail Community Edition](https://gitlab.com/ciphermail/ciphermail-community-gateway)
aus dem Quellcode und packt sie mit Postfix und Apache in ein Image. PostgreSQL läuft extern.

| Port | Dienst |
|------|--------|
| 25   | Postfix (SMTP, After-Queue-Content-Filter zum Backend) |
| 443  | Portal (Apache → `ciphermail-portal-backend` auf 8082) |
| 8443 | Admin-UI (Apache → `ciphermail-backend` auf 8081). **Nie offen ins Internet.** |

## Schnellstart (Docker Compose)

```bash
cp .env.example .env        # DB_PASSWORD, ADMIN_PASSWORD, MYHOSTNAME setzen
docker compose build        # dauert lange, GraalVM braucht viel RAM (8–16 GB)
docker compose up -d
docker compose logs -f ciphermail
```

Admin-UI: <https://localhost:8443>, Login mit `admin` und `ADMIN_PASSWORD`.

Der Build lädt Node.js und GraalVM als x64-Tarball und läuft darum nur für `linux/amd64`.
Version per Build-Argument `CM_REF` (Release-Tag, Standard `6.5.0`).

## Aufbau

Im Container gibt es kein systemd und kein journald. CipherMail ist für eine VM damit gebaut:
die systemd-Units starten die Java-Dienste, und das Backend ruft über sudo Skripte auf, die
`systemctl` und `journalctl` verwenden. Wo CipherMail es per Konfiguration erlaubt, wird das
umgestellt statt nachgebaut:

| Aufgabe | Auf der VM | Im Container |
|---------|-----------|--------------|
| Dienste starten | systemd-Units | supervisord + `cm-start-backend`, `cm-start-portal-backend` |
| Postfix start/stop/restart aus dem Admin-UI | `cm-postfix-ctl.sh` → systemctl | `cm-postfix-control` (`ciphermail.postfix.control-command`) |
| Log-Viewer im Admin-UI | `journalctl` | `cm-journalctl` (`ciphermail.journalctl.command`) |
| Map-Änderung → `systemctl reload postfix` | systemd | minimales `/usr/bin/systemctl` |
| `cm-system.sh` → `systemctl status` | systemd | minimales `/usr/bin/systemctl` |

Die Umstellung steht in `rootfs/etc/ciphermail/spring.config.d/container/application.yml`.
`cm-postfix-map.sh` und `cm-system.sh` rufen `systemctl` fest auf; dafür bleibt ein kleines
`systemctl` (`cm-systemctl`), das nur `status`, `is-active` und `reload postfix` kann.

- **Startbefehle:** `cm-start-backend` und `cm-start-portal-backend` enthalten dieselben
  Befehle wie die systemd-Units der Pakete. Die Units liegen als Vorlage in `upstream/systemd/`.
  Ändert eine neue CipherMail-Version eine Unit, bricht der Build mit einem Diff ab. Dann die
  Startskripte anpassen und die Vorlage aktualisieren.
- **Postfix:** `cm-postfix` statt `postfix start-fg`, weil der Master ohne PID 1 in einer eigenen
  Session läuft und supervisord ihn sonst nicht stoppen kann.
- **Logs:** `cm-journal` schreibt jede Logzeile auf stdout (`docker logs`) und zusätzlich als
  JSON nach `/var/log/ciphermail/journal/<dienst>.jsonl` (max. 2 × 20 MB pro Dienst,
  `CM_JOURNAL_MAX_MB`). Daraus liest `cm-journalctl` für den Log-Viewer.
- **`cm-entrypoint`** bei jedem Start: Postfix-Volume befüllen, TLS-Zertifikate, DB-Konfiguration,
  DB-Schema (nur bei leerer DB), `cli`-Konto (Passwort bei jedem Start neu), Portal-Konfiguration.
- **`cm-bootstrap`** sobald das Backend antwortet: Rolle und Konto `portal`, beim ersten Start
  das Admin-Konto. Ein bestehender Admin wird nie geändert.

## Umgebungsvariablen

| Variable | Pflicht | Bedeutung |
|----------|---------|-----------|
| `DB_HOST`, `DB_PASSWORD` | ja | PostgreSQL |
| `DB_PORT`, `DB_NAME`, `DB_USER` | nein | Standard `5432`, `ciphermail`, `ciphermail` |
| `DB_JDBC_PARAMS` | nein | an die JDBC-URL angehängt, z.B. `sslmode=require` (für psql zusätzlich `PGSSLMODE`) |
| `ADMIN_PASSWORD` | erster Start | Admin `admin` (`ADMIN_NAME`). Mind. 12 Zeichen, keine 5 gleichen Zeichen oder Tastaturfolgen, nicht der Kontoname |
| `MYHOSTNAME` | nein | `ciphermail_myhostname` in `main.cf`, nur beim ersten Start; danach im Admin-UI |
| `POSTFIX_TLS_FILE` | empfohlen | PEM mit Zertifikat und Schlüssel, wird bei jedem Start nach `/etc/postfix/tls.cer` kopiert. Ohne: selbstsigniert |
| `UI_TLS_CERT_FILE`, `UI_TLS_KEY_FILE` | empfohlen | Zertifikat für 443/8443. Ohne: selbstsigniert (pro Container) |
| `CLI_PASSWORD`, `PORTAL_PASSWORD` | nein | Maschinenkonten, mind. 32 Zeichen. Ohne: zufällig bei jedem Start |
| `TZ`, `JAVA_TOOL_OPTIONS` | nein | werden an die Java-Dienste weitergegeben |

Alle Passwörter gehen auch als Datei: `DB_PASSWORD_FILE`, `ADMIN_PASSWORD_FILE`,
`CLI_PASSWORD_FILE`, `PORTAL_PASSWORD_FILE` (z.B. `/run/secrets/db_password`).

## Konfiguration ändern

Neue Werte in `.env` gelten erst, wenn der Container neu erstellt wird
(`docker compose up -d`; ein `restart` behält die alte Umgebung). Gemountete Dateien
(Zertifikate, `*_FILE`) liest jeder Start neu.

| Änderung | Wirkung beim nächsten Start |
|----------|-----------------------------|
| `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_JDBC_PARAMS` | übernommen |
| `DB_PASSWORD` | übernommen, aber nur auf CipherMail-Seite: das Passwort in PostgreSQL selbst zuerst ändern (`ALTER ROLE ciphermail PASSWORD '…'`). Das `POSTGRES_PASSWORD` im Compose wirkt nur beim allerersten Start der DB. |
| `POSTFIX_TLS_FILE`, `UI_TLS_CERT_FILE`, `UI_TLS_KEY_FILE` | übernommen (Datei wird jedes Mal kopiert bzw. eingetragen). Variable entfernen lässt das zuletzt kopierte Postfix-Zertifikat stehen. |
| `CLI_PASSWORD`, `PORTAL_PASSWORD` | übernommen (werden ohnehin bei jedem Start gesetzt) |
| `TZ`, `JAVA_TOOL_OPTIONS` | übernommen |
| `ADMIN_PASSWORD` | **ignoriert**, sobald der Admin existiert. Passwort im Admin-UI oder mit `ciphermail-cli auth admin password` ändern. |
| `MYHOSTNAME` | **ignoriert** nach dem ersten Start. Im Admin-UI (MTA-Einstellungen) ändern, dort gehört es CipherMail. |

Absicht dahinter: Was CipherMail im Admin-UI verwaltet (Admins, Postfix-Einstellungen), wird
vom Container nie überschrieben. Was nur der Container kennt (DB-Zugang, Zertifikate,
Maschinenkonten), schreibt er bei jedem Start neu.

## Persistente Daten

| Pfad | Inhalt |
|------|--------|
| `/etc/postfix` | Postfix-Konfiguration. Das Backend schreibt `main.cf` und `maps.d`. Ein leeres Volume wird beim Start befüllt. |
| `/var/spool/postfix` | Mail-Queue |
| `/var/opt/ciphermail` | Arbeitsdaten des Backends: JMS-Queue mit Mails in Verarbeitung, Fehler-Repository (`james/`) |
| `/etc/ciphermail/pki/tls/private` | TLS-Schlüssel und CSRs aus dem Admin-UI |
| `/var/log/ciphermail` | optional: Logs für den Log-Viewer, Statistik |
| PostgreSQL | alles andere (Einstellungen, Schlüssel, Zertifikate, Quarantäne) |

Aufrufe der CLI im Container: `docker compose exec ciphermail ciphermail-cli system ping`.

## Kubernetes (Hinweise)

- StatefulSet mit einer Replika: Postfix-Queue und JMS-Daten sind Zustand.
- PVCs für die Pfade oben.
- Passwörter aus einem Secret, Zertifikate als Secret mounten und `POSTFIX_TLS_FILE`,
  `UI_TLS_CERT_FILE`, `UI_TLS_KEY_FILE` darauf zeigen lassen.
- Admin-UI (8443) nur über VPN oder IP-Allowlist erreichbar machen.
- Früh prüfen, ob der Anbieter Port 25 ausgehend sperrt.
- PostgreSQL extern, z.B. CloudNativePG.

## Getestet

Mit 6.5.0 (Build und Betrieb mit Compose): leere DB und zweiter Start, Login im Admin-UI,
Portal, Mail über Port 25 durch den Content-Filter und zurück (10025 → 10026),
Postfix start/stop/restart, Map anlegen und ändern (mit Reload), Postfix-Hauptkonfiguration
über die CipherMail-CLI (gleiche REST-API wie das Admin-UI), `cm-system.sh`, Log-Viewer für
MTA, Backend und Portal, Healthcheck, Abbruch des Builds bei geänderter Unit.

## Offene Punkte

- **Upgrades:** ob eine neue CipherMail-Version das DB-Schema selbst anpasst, ist nicht geklärt.
  Vor einem Upgrade DB sichern und die Release Notes lesen.
- `X-Forwarded-For` wird von Apache verworfen (Vorgabe von CipherMail). Hinter einem
  Reverse-Proxy `conf-available/ciphermail.conf` anpassen.
