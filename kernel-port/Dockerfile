FROM debian:12

RUN dpkg --add-architecture armhf \
 && apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      bc \
      bison \
      build-essential \
      ca-certificates \
      cpio \
      device-tree-compiler \
      file \
      flex \
      gcc-arm-linux-gnueabihf \
      kmod \
      libelf-dev \
      libssl-dev \
      patch \
      u-boot-tools \
      xz-utils \
 && mkdir -p /opt/armhf-busybox \
 && cd /tmp \
 && apt-get download busybox-static:armhf \
 && dpkg-deb -x busybox-static_*_armhf.deb /opt/armhf-busybox \
 && rm -f busybox-static_*_armhf.deb \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /src
