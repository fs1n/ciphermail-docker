# syntax=docker/dockerfile:1
#
# CipherMail Community Gateway in einem Container:
# Postfix (After-Queue-Content-Filter), ciphermail-backend, ciphermail-portal-backend
# und Apache für Admin-UI (8443) und Portal (443). PostgreSQL läuft extern.
#
# Nur linux/amd64: Node.js und GraalVM werden als x64-Tarball geladen.

# Basis-Images (z.B. für einen eigenen Registry-Mirror überschreibbar)
ARG BUILD_IMAGE=debian:trixie
ARG RUNTIME_IMAGE=debian:trixie-slim

# ---------- Stage 1: .deb-Pakete aus dem Quellcode bauen ----------
FROM ${BUILD_IMAGE} AS build

# Release-Tag von https://gitlab.com/ciphermail/ciphermail-community-gateway
ARG CM_REF=6.5.0
ARG NODE_VERSION=22.2.0
ARG NODE_SHA256=3544eee9cb1414d6e9003efd56bc807ffb0f4445d2fc383e1df04c3e5e72c91b
ARG GRAALVM_VERSION=22.0.2
ARG GRAALVM_SHA256=ebac1dd96a5e0fbcd1dd9804fa58815f146390a40aae966f02a8c26d1974364f

ENV DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8

# Build-Abhängigkeiten wie im README bzw. Vagrantfile (Trixie hat kein openjdk-17 mehr)
RUN apt-get update && apt-get install -y --no-install-recommends \
      ant ant-contrib build-essential ca-certificates createrepo-c curl debhelper \
      dpkg-dev fakeroot gcc git make maven openjdk-21-jdk rpm xz-utils zlib1g-dev \
 && rm -rf /var/lib/apt/lists/*

RUN curl -fsSLo /tmp/node.tar.xz "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz" \
 && echo "${NODE_SHA256}  /tmp/node.tar.xz" | sha256sum -c - \
 && mkdir -p /opt/node && tar -xf /tmp/node.tar.xz -C /opt/node --strip-components=1 \
 && ln -s /opt/node/bin/node /opt/node/bin/npm /opt/node/bin/npx /opt/node/bin/corepack /usr/local/bin/ \
 && corepack enable \
 && rm /tmp/node.tar.xz

# Für die native Version von ciphermail-shell (ciphermail-cli), build.xml erwartet /opt/graalvm
RUN curl -fsSLo /tmp/graalvm.tar.gz "https://github.com/graalvm/graalvm-ce-builds/releases/download/jdk-${GRAALVM_VERSION}/graalvm-community-jdk-${GRAALVM_VERSION}_linux-x64_bin.tar.gz" \
 && echo "${GRAALVM_SHA256}  /tmp/graalvm.tar.gz" | sha256sum -c - \
 && mkdir -p /opt/graalvm && tar -xzf /tmp/graalvm.tar.gz -C /opt/graalvm --strip-components=1 \
 && rm /tmp/graalvm.tar.gz

WORKDIR /src
# Volle Historie: build.xml ruft "git describe" auf (und würde ein flaches Repo sowieso nachladen)
RUN git clone --recurse-submodules --branch "${CM_REF}" \
      https://gitlab.com/ciphermail/ciphermail-community-gateway.git .

# GraalVM braucht viel Speicher (Vagrant-Build-VM: 16 GB)
RUN --mount=type=cache,target=/root/.m2 \
    --mount=type=cache,target=/root/.npm \
    --mount=type=cache,target=/root/.cache \
    --mount=type=cache,target=/root/.yarn \
    ant build-packages \
 && ls -l build/packages/*.deb

# ---------- Stage 2: Runtime ----------
FROM ${RUNTIME_IMAGE}

ENV DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8

# Kein systemd im Container: Dienste beim Paketinstall nicht starten, systemctl und
# journalctl durch eigene Skripte ersetzen (auch für die postinst-Skripte der Pakete).
COPY rootfs/usr/local/sbin/ /usr/local/sbin/
RUN printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d && chmod 0755 /usr/sbin/policy-rc.d \
 && chmod 0755 /usr/local/sbin/* \
 && for b in systemctl journalctl; do \
      dpkg-divert --local --rename --add /usr/bin/$b; \
      ln -s /usr/local/sbin/cm-$b /usr/bin/$b; \
    done \
 && echo "postfix postfix/main_mailer_type select No configuration" | debconf-set-selections

COPY --from=build /src/build/packages/ /tmp/debs/
# systemd-standalone-sysusers erfüllt die sysusers-Abhängigkeit, ohne systemd zu installieren
RUN apt-get update && apt-get install -y --no-install-recommends \
      apache2 ca-certificates openssl postfix postgresql-client procps ssl-cert sudo \
      supervisor systemd-standalone-sysusers util-linux \
      /tmp/debs/ciphermail-gateway-backend_*_all.deb \
      /tmp/debs/ciphermail-gateway-portal-backend_*_all.deb \
      /tmp/debs/ciphermail-cli_*_all.deb \
      /tmp/debs/ciphermail-admin-ui_*_all.deb \
      /tmp/debs/ciphermail-portal-ui_*_all.deb \
 && rm -rf /var/lib/apt/lists/* /tmp/debs \
 && id ciphermail-backend \
 && test -x /usr/bin/ciphermail-shell

# Erst nach dem Paket installieren, sonst fragt dpkg wegen der geänderten Konfigurationsdatei
COPY rootfs/etc/supervisor/supervisord.conf /etc/supervisor/supervisord.conf

# Postfix wie im README vorbereiten. /etc/postfix ist ein Volume: das Backend schreibt
# main.cf und maps.d. Die Vorlage in /opt/ciphermail-docker/postfix-seed füllt ein leeres Volume.
RUN cp /opt/ciphermail/conf/postfix/main.cf /opt/ciphermail/conf/postfix/master.cf /etc/postfix/ \
 && sed -ri 's!^smtp_tls_CApath =.*!smtp_tls_CApath = /etc/ssl/certs!; s/^smtp_tls_CAfile =.*/#smtp_tls_CAfile =/' /etc/postfix/main.cf \
 && postconf -e 'maillog_file = /dev/stdout' \
 && mkdir -p /etc/postfix/maps.d \
 && for m in check-recipient-access smtp-sasl-password_maps tls-policy transport-maps virtual-alias-maps; do \
      touch /etc/postfix/maps.d/hash-$m.map; postmap hash:/etc/postfix/maps.d/hash-$m.map; \
    done \
 && for m in system-check-recipient-access system-transport-maps; do \
      touch /etc/postfix/$m; postmap hash:/etc/postfix/$m; \
    done \
 && mkdir -p /opt/ciphermail-docker \
 && cp -a /etc/postfix /opt/ciphermail-docker/postfix-seed

# sudoers aus dem README (systemctl/journalctl dahinter sind die Ersatzskripte)
RUN printf '%s\n' \
      'ciphermail-backend ALL=NOPASSWD: /usr/sbin/cm-postfix-configure-main.sh, \' \
      '    /usr/sbin/cm-postfix-ctl.sh, /usr/sbin/cm-postfix-map.sh, /usr/sbin/cm-system.sh, \' \
      '    /usr/sbin/postcat, /usr/sbin/postconf, /usr/sbin/postsuper, /usr/sbin/postqueue, \' \
      '    /usr/bin/journalctl' > /etc/sudoers.d/ciphermail-backend \
 && chmod 0440 /etc/sudoers.d/ciphermail-backend \
 && visudo -cf /etc/sudoers.d/ciphermail-backend

# Apache: Konfiguration aus dem Quell-Repo (nicht in den .deb enthalten). Sie bringt
# "Listen 8443" mit, Port 443 (Portal) kommt aus ports.conf. Logs nach stdout/stderr.
COPY --from=build /src/conf/apache/apache.debian.conf /etc/apache2/conf-available/ciphermail.conf
RUN a2enmod headers proxy proxy_http rewrite ssl socache_shmcb \
 && a2enconf ciphermail \
 && a2dissite 000-default \
 && echo 'Listen 443' > /etc/apache2/ports.conf \
 && ln -sf /dev/stdout /var/log/apache2/access.log \
 && ln -sf /dev/stdout /var/log/apache2/other_vhosts_access.log \
 && ln -sf /dev/stderr /var/log/apache2/error.log \
 && rm -f /etc/ssl/certs/ssl-cert-snakeoil.pem /etc/ssl/private/ssl-cert-snakeoil.key

VOLUME ["/etc/postfix", "/var/spool/postfix", "/var/opt/ciphermail", "/etc/ciphermail/pki/tls/private"]
EXPOSE 25 443 8443

HEALTHCHECK --interval=30s --timeout=10s --start-period=180s --retries=3 \
  CMD ["/usr/local/sbin/cm-healthcheck"]

ENTRYPOINT ["/usr/local/sbin/cm-entrypoint"]
CMD ["supervisord", "-n", "-c", "/etc/supervisor/supervisord.conf"]
