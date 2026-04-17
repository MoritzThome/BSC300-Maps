FROM eclipse-temurin:25-jre-alpine

LABEL description="Container for building BCS300/iGPSport map files from OpenStreetMap data"

ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

WORKDIR /work

COPY easybuild.sh generate_map.py README.md LICENSE /work/
COPY conf /work/conf
COPY native_tools /work/native_tools

RUN apk add --no-cache \
    # Core tools
    curl \
    ca-certificates \
    # Build tools (temporary)
    gcc \
    make \
    musl-dev \
    zlib-dev \
    # Python
    python3 \
    py3-numpy \
    py3-yaml \
    # Utilities
    unzip \
    parallel \
    bash \
    # prepare environment
    && /work/easybuild.sh -p \
    # cleanup
    && apk del gcc make musl-dev zlib-dev unzip \
    && rm -rf /tmp/*

ENTRYPOINT ["/work/easybuild.sh"]
CMD ["-h"]