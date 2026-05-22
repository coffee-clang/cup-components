FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        cmake \
        curl \
        file \
        ninja-build \
        patch \
        pkg-config \
        python3 \
        python3-dev \
        swig \
        tar \
        unzip \
        xz-utils \
        bzip2 \
        zip \
        zlib1g-dev \
        libzstd-dev \
        libxml2-dev \
        libedit-dev \
        libncurses-dev \
        liblzma-dev \
        libffi-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace