#!/bin/bash

set -e

# If osmosis environment needs to be created, the below versions of the tools will be used
OSMOSIS_VERSION="0.49.2"
MAPSFORGE_VERSION="0.25.0"

BIN_DIR=osmosis

TEMP_DIR="./tmp/"
mkdir -p ${TEMP_DIR}

# Download Osmosis

curl -L -o ${TEMP_DIR}/osmosis.zip https://github.com/openstreetmap/osmosis/releases/download/${OSMOSIS_VERSION}/osmosis-${OSMOSIS_VERSION}.zip
unzip -q ${TEMP_DIR}/osmosis.zip -d ${TEMP_DIR}/osmosis
mv ${TEMP_DIR}/osmosis/osmosis*/ ${BIN_DIR}

mkdir -p "${BIN_DIR}/bin/plugins"
curl -L -o "${BIN_DIR}/bin/plugins/mapsforge-map-writer-${MAPSFORGE_VERSION}-jar-with-dependencies.jar" \
"https://repo1.maven.org/maven2/org/mapsforge/mapsforge-map-writer/${MAPSFORGE_VERSION}/mapsforge-map-writer-${MAPSFORGE_VERSION}-jar-with-dependencies.jar"

# compile native tools
gcc native_tools/osmconvert.c -O3 -lz -o osmosis/osmconvert
gcc native_tools/osmfilter.c -O3 -lz -o osmosis/osmfilter