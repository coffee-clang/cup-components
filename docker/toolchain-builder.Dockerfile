FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential \
        binutils \
        ca-certificates \
        curl \
        wget \
        file \
        flex \
        gawk \
        gettext \
        bison \
        libtool \
        make \
        patch \
        patchelf \
        perl \
        python3 \
        python3-dev \
        tar \
        texinfo \
        unzip \
        xz-utils \
        bzip2 \
        zip \
        pkg-config \
        libgmp-dev \
        libmpfr-dev \
        libreadline-dev \
        libexpat1-dev \
        zlib1g-dev \
        libncurses-dev \
        liblzma-dev \
        libzstd-dev \
        libdebuginfod-dev \
        libsource-highlight-dev \
        libxxhash-dev \
        libbabeltrace-dev \
        libc6-dbg \
    && if [ "$(dpkg --print-architecture)" = "amd64" ]; then \
        apt-get install -y --no-install-recommends libipt-dev; \
    fi \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace
