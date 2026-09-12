FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install --yes --no-install-recommends \
        ca-certificates \
        cpio \
        debian-archive-keyring \
        gpg \
        kmod \
        mmdebstrap \
        systemd \
        xz-utils \
    && rm -rf /var/lib/apt/lists/*

COPY build-in-container.sh /usr/local/sbin/dhb-ax-mmdebstrap

ENTRYPOINT ["/bin/sh", "/usr/local/sbin/dhb-ax-mmdebstrap"]
