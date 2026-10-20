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

Im Container gibt es kein systemd. Die Pakete erwarten es aber: das Backend ruft über sudo
`cm-postfix-ctl.sh`, `cm-postfix-map.sh`, `cm-system.sh` (die wiederum `systemctl` aufrufen)
und `journalctl` für den Log-Viewer auf. Darum:

- **supervisord** startet Postfix, beide Backends, Apache und `cm-bootstrap`
  (`rootfs/etc/supervisor/supervisord.conf`).
- **`cm-run-unit`** liest beim Start die systemd-Unit aus dem Paket
  (`/usr/lib/systemd/system/ciphermail-*.service`): `User`, `ExecStartPre`, `ExecStart`
  (mehrzeilig), `EnvironmentFile`, `RuntimeDirectory`, `LogsDirectory`. Neue Paketversionen
  laufen so ohne Anpassung. Fehler in `ExecStartPre` werden nur gemeldet (z.B. `setfacl` auf
  `/run/systemd/ask-password`, das es ohne systemd nicht gibt).
- **`/usr/bin/systemctl`** ist `cm-systemctl`: `start|stop|restart|status|is-active` gehen an
  supervisorctl, `reload postfix` an `postfix reload`, der Rest endet mit 0.
- **`/usr/bin/journalctl`** ist `cm-journalctl`. `cm-journal` schreibt jede Logzeile auf stdout
  (`docker logs`) und zusätzlich als JSON nach `/var/log/ciphermail/journal/<dienst>.jsonl`
  (max. 2 × 20 MB pro Dienst, `CM_JOURNAL_MAX_MB`). Daraus liest der Log-Viewer im Admin-UI.
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
`cm-postfix-ctl.sh restart|stop|start` und `postfix reload` über sudo wie aus dem Backend,
Log-Viewer für MTA, Backend und Portal, Healthcheck.

## Offene Punkte

- **Upgrades:** ob eine neue CipherMail-Version das DB-Schema selbst anpasst, ist nicht geklärt.
  Vor einem Upgrade DB sichern und die Release Notes lesen.
- `X-Forwarded-For` wird von Apache verworfen (Vorgabe von CipherMail). Hinter einem
  Reverse-Proxy `conf-available/ciphermail.conf` anpassen.
