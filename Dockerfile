FROM debian:trixie-slim

LABEL description="Container for building BCS300/iGPSport map files from OpenStreetMap data"

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

WORKDIR /work

COPY . /work/

RUN apt update -qq && apt install -qqy --no-install-recommends \
    # Core tools
    wget \
    ca-certificates \
    # Build tools
    gcc \
    make \
    zlib1g-dev \
    # Java (needed for Osmosis/Mapsforge)
    default-jre-headless \
    # Python
    python3 \
    python3-numpy \
    python3-yaml \
    # Utilities
    unzip \
    parallel \
    # Cleanup
    && /work/easybuild.sh -p && \
    apt purge -y gcc make zlib1g-dev && apt autoremove -y && \
    apt clean \
    && rm -rf /var/lib/apt/lists/* \
    && rm -rf /tmp/*

ENTRYPOINT ["/work/easybuild.sh"]
CMD ["-h"]
