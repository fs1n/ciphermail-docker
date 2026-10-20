# Gemeinsame Funktionen für cm-start-backend und cm-start-portal-backend (mit "." einbinden).
# Ersetzt, was systemd für die Units der Pakete tut: Logging, saubere Umgebung, Benutzerwechsel.

# Umgebungsvariablen für den Dienst (zusätzlich zur Grundumgebung)
SERVICE_ENV=()

# stdout/stderr des Dienstes über cm-journal: in die Container-Logs und in den Log-Viewer
service_log() {
    exec > >(exec /usr/local/sbin/cm-journal "$1") 2>&1
}

# EnvironmentFile= lesen (KEY=VALUE, Kommentare, optionale Anführungszeichen)
service_env_file() {
    local f=$1 line k v
    [[ -r $f ]] || { echo "Umgebungsdatei $f fehlt" >&2; exit 1; }
    while IFS= read -r line || [[ -n $line ]]; do
        [[ $line =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*(.*)$ ]] || continue
        k=${BASH_REMATCH[1]} v=${BASH_REMATCH[2]}
        if [[ $v =~ ^\"(.*)\"$ || $v =~ ^\'(.*)\'$ ]]; then v=${BASH_REMATCH[1]}; fi
        SERVICE_ENV+=("$k=$v")
    done < "$f"
}

# Startet den Dienst als <user> mit sauberer Umgebung wie bei systemd: keine
# Container-Variablen (Passwörter!), nur Grundumgebung, TZ, JAVA_TOOL_OPTIONS und SERVICE_ENV.
# Aufruf: service_exec <user> <befehl> [argumente...]
service_exec() {
    local user=$1 home
    shift
    home=$(getent passwd "$user" | cut -d: -f6)
    local env=(
        "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        "LANG=${LANG:-C.UTF-8}"
        "HOME=${home:-/}" "USER=$user" "LOGNAME=$user"
    )
    [[ -n ${TZ:-} ]] && env+=("TZ=$TZ")
    [[ -n ${JAVA_TOOL_OPTIONS:-} ]] && env+=("JAVA_TOOL_OPTIONS=$JAVA_TOOL_OPTIONS")
    echo "starte $* als $user" | cut -c1-120
    exec env -i "${env[@]}" "${SERVICE_ENV[@]}" \
        setpriv --reuid="$user" --regid="$user" --init-groups -- "$@"
}
