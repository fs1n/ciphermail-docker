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

Gebaut werden nur die fünf `.deb`-Pakete (`build/build-debs.xml`), nicht wie mit
`ant build-packages` zusätzlich die RPMs. Der Paket-Build (Maven, Yarn, GraalVM native-image
für die CLI) braucht beim ersten Mal 20 Minuten und mehr; danach liegt er im Docker-Cache
und läuft erst wieder bei einem anderen `CM_REF`. Docker sollte dafür 12–16 GB RAM haben,
sonst swappt GraalVM und es dauert ein Vielfaches.

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
| `KEYSTORE_PASSWORD` | ja | Verschlüsselt die privaten S/MIME-Schlüssel in der DB (siehe unten). Mind. 16 Zeichen, nie ändern |
| `DB_PORT`, `DB_NAME`, `DB_USER` | nein | Standard `5432`, `ciphermail`, `ciphermail` |
| `DB_JDBC_PARAMS` | nein | an die JDBC-URL angehängt, z.B. `sslmode=require` (für psql zusätzlich `PGSSLMODE`) |
| `ADMIN_PASSWORD` | erster Start | Admin `admin` (`ADMIN_NAME`). Mind. 12 Zeichen, keine 5 gleichen Zeichen oder Tastaturfolgen, nicht der Kontoname |
| `MYHOSTNAME` | nein | `ciphermail_myhostname` in `main.cf`, nur beim ersten Start; danach im Admin-UI |
| `POSTFIX_TLS_FILE` | empfohlen | PEM mit Zertifikat und Schlüssel, wird bei jedem Start nach `/etc/postfix/tls.cer` kopiert. Ohne: selbstsigniert |
| `UI_TLS_CERT_FILE`, `UI_TLS_KEY_FILE` | empfohlen | Zertifikat für 443/8443. Ohne: selbstsigniert, bei jedem Start neu |
| `TRUSTED_PROXIES` | hinter Proxy | IPs/Netze des Reverse-Proxys, durch Komma oder Leerzeichen getrennt (siehe unten) |
| `ADMIN_PUBLIC_PORT`, `PORTAL_PUBLIC_PORT` | hinter Proxy | Öffentliche Ports von Admin-UI und Portal, Standard `8443` und `443` |
| `MEMORY_LIMIT` | nein | nur Compose: Speicherlimit des Containers, Standard `2g` |
| `CLI_PASSWORD`, `PORTAL_PASSWORD` | nein | Maschinenkonten, mind. 32 Zeichen. Ohne: zufällig bei jedem Start |
| `TZ`, `JAVA_TOOL_OPTIONS` | nein | werden an die Java-Dienste weitergegeben |

Alle Passwörter gehen auch als Datei: `DB_PASSWORD_FILE`, `KEYSTORE_PASSWORD_FILE`,
`ADMIN_PASSWORD_FILE`, `CLI_PASSWORD_FILE`, `PORTAL_PASSWORD_FILE` (z.B. `/run/secrets/db_password`).

### Keystore-Passwort

CipherMail speichert die privaten S/MIME-Schlüssel verschlüsselt in der Datenbank
(`cm_key_store`). Das Passwort dafür ist in CipherMail standardmässig leer, d.h. wer die DB
oder ein DB-Backup hat, hat die Schlüssel. Der Container verlangt darum `KEYSTORE_PASSWORD`.

- Beim ersten Start legt er einen Prüfwert (PBKDF2) im eigenen Schema `ciphermail_docker` ab.
- Bei jedem weiteren Start vergleicht er: ein anderes Passwort bricht den Start ab, statt die
  Schlüssel unlesbar zu machen.
- Enthält eine bestehende DB schon Schlüssel, aber keinen Prüfwert (mit leerem Passwort
  gespeichert), bricht der Start ebenfalls ab.
- Das Passwort gehört zu jedem DB-Backup. Ohne es ist ein Backup für die Schlüssel wertlos.

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
| `TRUSTED_PROXIES`, `ADMIN_PUBLIC_PORT`, `PORTAL_PUBLIC_PORT`, `MEMORY_LIMIT` | übernommen |
| `KEYSTORE_PASSWORD` | **nie ändern.** Ein anderer Wert bricht den Start ab. |
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

Mit `read_only` (siehe Härtung) braucht es zusätzlich tmpfs für `/run`, `/tmp` und
`/var/lib/postfix`. Alles, was der Entrypoint bei jedem Start erzeugt (DB-Zugang,
Apache-Einstellungen, Passwortdateien), liegt in `/run/ciphermail-docker`.

Aufrufe der CLI im Container: `docker compose exec ciphermail ciphermail-cli system ping`.

## Härtung

Die Compose-Datei setzt:

- `read_only: true` mit tmpfs für `/run`, `/tmp`, `/var/lib/postfix`
- `cap_drop: ALL`, zurück nur `CHOWN`, `DAC_OVERRIDE`, `FOWNER`, `SETUID`, `SETGID`, `KILL`,
  `NET_BIND_SERVICE` (Begründung je Recht in `docker-compose.yml`)
- `mem_limit` (`MEMORY_LIMIT`, Standard 2 GB): Backend 40 %, Portal 20 % davon. Ohne Limit
  rechnet Java mit dem RAM des ganzen Hosts. Im Leerlauf belegt der Container ca. 800 MB.

Nicht möglich: `no-new-privileges`, weil das Backend Postfix über sudo steuert (setuid).
Die Java-Dienste laufen als `ciphermail-backend`, Postfix und Apache geben root nach dem Start ab.

## Reverse-Proxy

Ein Hostname pro Oberfläche (beide UIs liegen unter `/`, ein Unterpfad geht nicht), Proxy
spricht HTTPS zum Container (8443 Admin-UI, 443 Portal), Timeout mind. 300 s, Uploads bis 100 MB.

Damit CipherMail die echte Client-Adresse sieht (Sperre nach Fehlversuchen, erlaubte IPs pro
Admin, Logs), `TRUSTED_PROXIES` auf die Adresse des Proxys setzen. Apache übernimmt die Adresse
aus `X-Forwarded-For` dann nur von dort (`mod_remoteip`); von allen anderen wird der Header wie
bisher verworfen. Läuft das Admin-UI öffentlich auf 443, `ADMIN_PUBLIC_PORT=443` setzen (für
Weiterleitungen, z.B. beim OIDC-Login).

## Kubernetes (Hinweise)

- StatefulSet mit einer Replika: Postfix-Queue und JMS-Daten sind Zustand.
- PVCs für die Pfade oben.
- `securityContext`: `readOnlyRootFilesystem: true`, Capabilities wie in der Compose-Datei,
  `emptyDir` (medium: Memory) für `/run`, `/tmp`, `/var/lib/postfix`, Memory-Limit setzen.
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

Mit Härtung (read-only, Capabilities wie oben, 2 GB): alles oben nochmals; S/MIME-Schlüssel
anlegen und exportieren (mit falschem Keystore-Passwort verweigert das Backend den Export);
Start mit falschem Keystore-Passwort, ohne Prüfwert bei vorhandenen Schlüsseln und ohne
Passwort bricht ab. Hinter Caddy: echte Client-Adresse kommt an, gefälschtes `X-Forwarded-For`
wird über den Proxy, direkt und aus anderen Containern ignoriert, Allowlist für das Admin-UI.

## Offene Punkte

- **Upgrades:** ob eine neue CipherMail-Version das DB-Schema selbst anpasst, ist nicht geklärt.
  Vor einem Upgrade DB sichern und die Release Notes lesen.
- Postfix steht auf `compatibility_level = 3.6` (gilt für neue Volumes). Dabei `smtputf8_enable = no`
  ausdrücklich, weil das Backend kein SMTPUTF8 anbietet. TLS-Fingerabdrücke in der TLS-Policy
  sind damit SHA-256 statt MD5.
