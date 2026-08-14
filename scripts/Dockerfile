# Host environment for Buildroot.
#
# No cross-compiler here.  Buildroot builds its own -- Debian's is rejected by
# design, see the toolchain section of br2-external/configs/dhb_ax_defconfig.
FROM debian:12

RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      bc \
      binutils \
      bison \
      build-essential \
      bzip2 \
      ca-certificates \
      cpio \
      file \
      findutils \
      flex \
      git \
      gzip \
      libncurses-dev \
      libssl-dev \
      locales \
      perl \
      python3 \
      python3-dev \
      python3-venv \
      rsync \
      sed \
      swig \
      tar \
      unzip \
      wget \
      which \
      xz-utils \
      yamllint \
 && rm -rf /var/lib/apt/lists/*

# Linux's dt_binding_check and dtbs_check targets use the dt-schema tools.
# Keep them in an isolated, version-pinned environment so the checks are
# reproducible and do not depend on Debian's system Python package set.
RUN python3 -m venv /opt/dtschema \
 && /opt/dtschema/bin/pip install --no-cache-dir dtschema==2026.6
ENV PATH="/opt/dtschema/bin:${PATH}"

# Buildroot's configure scripts misbehave under a non-UTF-8 locale.
RUN sed -i 's/^# en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

# Several host packages refuse to configure as root -- GNU tar is the first to
# hit it.  The container starts as root so it can take ownership of the mounted
# volumes, then drops to this user; see scripts/buildroot-in-container.sh.
RUN useradd --create-home --uid 1000 --shell /bin/sh br

WORKDIR /buildroot
