FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        curl \
        wget \
        file \
        flex \
        bison \
        make \
        patch \
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
        libipt-dev \
        openmpi-bin \
        libopenmpi-dev \
        libc6-dbg \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace
