#!/bin/bash

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

VERBOSE=false

log() { echo -e "${GREEN}[$(date +'%H:%M:%S')]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; usage; exit 1; }
warn() { echo -e "${YELLOW}[WARNING]${NC} $1" >&2; }
info() { echo -e "${BLUE}[INFO]${NC} $1"; }
debug() { [ "$VERBOSE" = true ] && echo -e "${BLUE}[DEBUG]${NC} $1" || true; }

v_exec() {
    if [ "$VERBOSE" = true ]; then
        "$@"
    else
        "$@" >/dev/null 2>&1
    fi
}

format_duration() {
    local seconds=$1
    local hours=$((seconds / 3600))
    local minutes=$(((seconds % 3600) / 60))
    local secs=$((seconds % 60))
    
    if [ $hours -gt 0 ]; then
        printf "%dh %dm %ds" $hours $minutes $secs
    elif [ $minutes -gt 0 ]; then
        printf "%dm %ds" $minutes $secs
    else
        printf "%ds" $secs
    fi
}

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load map type configuration

source "$BASE_DIR/map-types.conf" || error "Failed to load map-types.conf"

# Defaults

TYPE="water"
PARALLEL_JOBS=2
COUNTRIES=""
OUTPUT_BASE="output"
CONFIG_FILE="$BASE_DIR/countries.yml"

usage() {
    cat << EOF
Local BCS300 Map Builder
========================

Usage: ./easybuild.sh [OPTIONS]

Options:
    -a               Build all countries from countries.yml
    -t TYPE          Build type (default: water)
EOF
    
    # Dynamically show available types from config
    for map_type in $AVAILABLE_MAP_TYPES; do
        local desc=$(get_config "description" "$map_type")
        printf "                     - %-15s : %s\n" "$map_type" "$desc"
    done
    
    cat << 'EOF'
    
    -j JOBS          Parallel jobs (default: 2)
    -c COUNTRIES     Comma-separated country list
    -o OUTPUT        Output directory (default: output)
    -v               Verbose mode (show all tool output)
    -h               Show this help

Examples:
    # Build all countries with water type, verbose
    ./easybuild.sh -a -v

    # Build Germany with green type, 4 parallel jobs
    ./easybuild.sh -c germany -t green -j 4 -v

    # Build multiple countries, streets-only (smallest)
    ./easybuild.sh -c "germany,switzerland,austria" -t streets-only

Available countries:
EOF
    python3 -c "
import yaml
with open('$CONFIG_FILE', 'r') as f:
    data = yaml.safe_load(f)
    for country in sorted(data['countries'].keys()):
        country_data = data['countries'][country]
        if 'regions' in country_data:
            print(f'    - {country:20} ({country_data[\"code\"]}) - {len(country_data[\"regions\"])} regions')
        else:
            print(f'    - {country:20} ({country_data[\"code\"]})')
" 2>/dev/null || echo "    (countries.yml not found or invalid)"
}

# Parse arguments

while getopts "at:j:c:o:vh" opt; do
    case $opt in
        a) COUNTRIES="all" ;;
        t) TYPE="$OPTARG" ;;
        j) PARALLEL_JOBS="$OPTARG"
           if [ "$PARALLEL_JOBS" -gt 2 ]; then
               warn "More than 2 parallel jobs can cause resource issues!"
               warn "Each job uses up to 8GB RAM."
           fi
           ;;
        c) COUNTRIES="$OPTARG" ;;
        o) OUTPUT_BASE="$OPTARG" ;;
        v) VERBOSE=true ;;
        h) usage; exit 0 ;;
        *) usage; exit 1 ;;
    esac
done

# Validate type

if ! is_valid_map_type "$TYPE"; then
    error "Invalid type: $TYPE. Use one of: $AVAILABLE_MAP_TYPES"
fi

[ ! -f "$CONFIG_FILE" ] && error "Configuration file not found: $CONFIG_FILE"

# Get config for selected type (dynamically!)

TYPE_DESC=$(get_config "description" "$TYPE")
TAG_FILE=$(get_config "tag_file" "$TYPE")
FILTER_ARGS=$(get_config "filter_args" "$TYPE")
TAG_MODIFICATIONS=$(get_config "tag_modifications" "$TYPE")

# Verify we got all needed config

[ -z "$TYPE_DESC" ] && error "No description found for type: $TYPE"
[ -z "$TAG_FILE" ] && error "No tag file found for type: $TYPE"
[ -z "$FILTER_ARGS" ] && error "No filter args found for type: $TYPE"
[ -z "$TAG_MODIFICATIONS" ] && error "No tag modifications found for type: $TYPE"

# Parse countries.yml

parse_countries() {
    python3 - "$CONFIG_FILE" "$COUNTRIES" << 'PYEOF'
import sys
import yaml

config_file = sys.argv[1]
countries_filter = sys.argv[2]

with open(config_file, 'r') as f:
    data = yaml.safe_load(f)

if countries_filter == "all":
    countries_to_process = data['countries'].keys()
else:
    countries_to_process = [c.strip() for c in countries_filter.split(',')]

for country_name in countries_to_process:
    if country_name not in data['countries']:
        print(f"WARNING: Country '{country_name}' not found in config", file=sys.stderr)
        continue
    
    country = data['countries'][country_name]
    code = country['code']
    
    if 'regions' in country:
        for region in country['regions']:
            print(f"{country_name}\t{region['name']}\t{region['url']}\t{region['state']}\t{code}")
    else:
        url = country['url']
        state = country.get('state', '00')
        print(f"{country_name}\t{country_name}\t{url}\t{state}\t{code}")
PYEOF
}

export -f format_duration log info warn error debug v_exec
export VERBOSE TYPE OUTPUT_BASE BASE_DIR TAG_FILE FILTER_ARGS TAG_MODIFICATIONS TYPE_DESC

setup_check() {
    log "Checking prerequisites..."
    
    command -v wget >/dev/null 2>&1 || error "wget not found. Install: sudo apt install wget"
    command -v python3 >/dev/null 2>&1 || error "python3 not found. Install: sudo apt install python3"
    command -v unzip >/dev/null 2>&1 || error "unzip not found. Install: sudo apt install unzip"
    command -v gcc >/dev/null 2>&1 || error "gcc not found. Install: sudo apt install gcc"
    command -v java >/dev/null 2>&1 || error "java not found. Install: sudo apt install default-jre"
    
    python3 -c "import yaml" 2>/dev/null || {
        warn "PyYAML not found, installing..."
        pip3 install pyyaml
    }
    
    python3 -c "import numpy" 2>/dev/null || {
        warn "numpy not found, installing..."
        pip3 install numpy
    }
    
    if [ ! -d "$BASE_DIR/osmosis/bin" ] || [ ! -f "$BASE_DIR/osmosis/osmconvert" ]; then
        log "Setting up osmosis..."
        cd "$BASE_DIR"
        v_exec bash setup_env.sh || error "Failed to setup osmosis"
    fi
    
    [ ! -d "$BASE_DIR/osmosis/bin" ] && error "osmosis/bin not found after setup!"
    [ ! -f "$BASE_DIR/osmosis/osmconvert" ] && error "osmosis/osmconvert not found!"
    [ ! -f "$BASE_DIR/osmosis/osmfilter" ] && error "osmosis/osmfilter not found!"
    [ ! -f "$BASE_DIR/generate_map.py" ] && error "generate_map.py not found!"
    
    if ! ls "$BASE_DIR/osmosis/bin/plugins/mapsforge-map-writer-"*.jar >/dev/null 2>&1; then
        error "Mapsforge plugin not found in osmosis/bin/plugins/"
    fi
    
    mkdir -p "$BASE_DIR/$OUTPUT_BASE"
    
    log "✓ All prerequisites met"
}

build_single() {
    local task_file="$1"
    
    IFS=$'\t' read -r country region url state countrycode < "$task_file"
    
    local work_dir="$BASE_DIR/$OUTPUT_BASE/.tmp/${country}-${region}-$$-$RANDOM"
    local output_dir="$BASE_DIR/$OUTPUT_BASE/${TYPE}"
    
    mkdir -p "$work_dir" "$output_dir"
    cd "$work_dir"
    
    info "════════════════════════════════════════════════════════════"
    info "Building: $country/$region ($TYPE - $TYPE_DESC)"
    debug "Country Code: $countrycode | State: $state"
    debug "URL: $url"
    
    # Download
    log "→ Downloading OSM data..."
    if [ "$VERBOSE" = true ]; then
        wget --show-progress "$url" -O tmp.pbf 2>&1 || error "Download failed: $url"
    else
        wget -q "$url" -O tmp.pbf 2>&1 || error "Download failed: $url"
    fi
    
    [ ! -s tmp.pbf ] && error "Downloaded file is empty: $url"
    debug "Downloaded: $(du -h tmp.pbf | cut -f1)"
    
    # Convert to O5M
    log "→ Converting to O5M..."
    v_exec "$BASE_DIR/osmosis/osmconvert" tmp.pbf -o=tmp.o5m
    debug "Converted: $(du -h tmp.o5m | cut -f1)"
    rm tmp.pbf
    
    # Filter (using config from map-types.conf)
    log "→ Filtering ($TYPE)..."
    if [ "$VERBOSE" = true ]; then
        eval "$BASE_DIR/osmosis/osmfilter -v tmp.o5m $FILTER_ARGS --out-o5m -o tmp1.o5m"
    else
        eval "$BASE_DIR/osmosis/osmfilter tmp.o5m $FILTER_ARGS --out-o5m -o tmp1.o5m"
    fi
    
    debug "Filtered: $(du -h tmp1.o5m | cut -f1)"
    
    # Modify tags (using config from map-types.conf)
    log "→ Modifying tags..."
    if [ "$VERBOSE" = true ]; then
        "$BASE_DIR/osmosis/osmfilter" -v tmp1.o5m --modify-tags="$TAG_MODIFICATIONS" \
            --drop-author --drop-version --out-o5m -o tmp_filtered.o5m
    else
        "$BASE_DIR/osmosis/osmfilter" tmp1.o5m --modify-tags="$TAG_MODIFICATIONS" \
            --drop-author --drop-version --out-o5m -o tmp_filtered.o5m
    fi
    
    rm tmp.o5m tmp1.o5m
    debug "Modified: $(du -h tmp_filtered.o5m | cut -f1)"
    
    # Convert to PBF
    log "→ Converting to PBF..."
    v_exec "$BASE_DIR/osmosis/osmconvert" tmp_filtered.o5m -o=tmp_filtered.pbf
    rm tmp_filtered.o5m
    debug "Final PBF: $(du -h tmp_filtered.pbf | cut -f1)"
    
    # Build map
    log "→ Building map with Mapsforge..."
    local abs_input="$(pwd)/tmp_filtered.pbf"
    
    ln -sf "$BASE_DIR/osmosis" osmosis
    
    debug "Tag file: $BASE_DIR/$TAG_FILE"
    
    if [ "$VERBOSE" = true ]; then
        python3 "$BASE_DIR/generate_map.py" \
            -i "$abs_input" \
            -c "$countrycode" \
            -s "$state" \
            -t "$BASE_DIR/$TAG_FILE"
    else
        python3 "$BASE_DIR/generate_map.py" \
            -i "$abs_input" \
            -c "$countrycode" \
            -s "$state" \
            -t "$BASE_DIR/$TAG_FILE" >/dev/null 2>&1
    fi
    
    # Find and move generated maps
    log "→ Collecting maps..."
    local moved_count=0
    for mapfile in *.map; do
        if [ -f "$mapfile" ] && [ "$mapfile" != "*.map" ]; then
            debug "Found: $mapfile ($(du -h "$mapfile" | cut -f1))"
            
            if [[ "$mapfile" == ${countrycode}${state}* ]]; then
                log "✓ Created: $mapfile"
                mv "$mapfile" "${output_dir}/"
                moved_count=$((moved_count + 1))
            else
                warn "Wrong format: $mapfile (expected: ${countrycode}${state}*)"
                mv "$mapfile" "${output_dir}/${mapfile}.wrong-format"
            fi
        fi
    done
    
    if [ $moved_count -eq 0 ]; then
        warn "No map file created for $country/$region"
        [ "$VERBOSE" = true ] && ls -lah
    else
        log "✓ Successfully saved $moved_count map(s)"
    fi
    
    # Cleanup
    cd "$BASE_DIR"
    rm -rf "$work_dir"
    
    info "════════════════════════════════════════════════════════════"
}

export -f build_single

# Main

START_TIME=$(date +%s)

setup_check

log "Starting batch build"
info "Type: $TYPE ($TYPE_DESC)"
info "Parallel jobs: $PARALLEL_JOBS"
info "Verbose: $VERBOSE"
info "Output: $BASE_DIR/$OUTPUT_BASE/$TYPE/"

[ -z "$COUNTRIES" ] && COUNTRIES="all"

# Collect tasks

TASKS_DIR=$(mktemp -d)
ALL_TASKS=$(mktemp)

parse_countries > "$ALL_TASKS" 2>&1

if [ ! -s "$ALL_TASKS" ]; then
    rm -rf "$TASKS_DIR" "$ALL_TASKS"
    error "No valid countries found!"
fi

# Create task files

TASK_NUM=0
while IFS=$'\t' read -r c r u s code; do
    [ -z "$c" ] && continue
    TASK_NUM=$((TASK_NUM + 1))
    printf "%s\t%s\t%s\t%s\t%s\n" "$c" "$r" "$u" "$s" "$code" > "$TASKS_DIR/task_${TASK_NUM}.txt"
done < "$ALL_TASKS"

rm "$ALL_TASKS"

TOTAL_TASKS=$(ls "$TASKS_DIR"/task_*.txt 2>/dev/null | wc -l)

if [ "$TOTAL_TASKS" -eq 0 ]; then
    rm -rf "$TASKS_DIR"
    error "No tasks found!"
fi

log "Building $TOTAL_TASKS map(s)"

# Execute builds

if command -v parallel >/dev/null 2>&1 && [ "$PARALLEL_JOBS" -gt 1 ]; then
    log "Using GNU parallel with $PARALLEL_JOBS jobs"
    ls "$TASKS_DIR"/task_*.txt | parallel -j "$PARALLEL_JOBS" build_single {}
else
    if [ "$PARALLEL_JOBS" -gt 1 ]; then
        warn "GNU parallel not found, using sequential execution"
        info "Install for faster builds: sudo apt install parallel"
    fi
    
    CURRENT=0
    for task_file in "$TASKS_DIR"/task_*.txt; do
        CURRENT=$((CURRENT + 1))
        info "Progress: $CURRENT/$TOTAL_TASKS"
        build_single "$task_file"
    done
fi

rm -rf "$TASKS_DIR"

# Summary

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

log "════════════════════════════════════════════════════════════════"
log "Build complete!"
log "Total time: $(format_duration $DURATION)"
log "Output: $BASE_DIR/$OUTPUT_BASE/$TYPE/"

MAP_COUNT=$(find "$BASE_DIR/$OUTPUT_BASE/$TYPE" -name "*.map" 2>/dev/null | wc -l)
log "Maps created: $MAP_COUNT"

if [ "$MAP_COUNT" -gt 0 ]; then
    TOTAL_SIZE=$(du -sh "$BASE_DIR/$OUTPUT_BASE/$TYPE" 2>/dev/null | cut -f1)
    log "Total size: $TOTAL_SIZE"
    
    if [ "$VERBOSE" = true ]; then
        log "════════════════════════════════════════════════════════════════"
        info "Created maps:"
        find "$BASE_DIR/$OUTPUT_BASE/$TYPE" -name "*.map" -exec basename {} \; | sort | sed 's/^/  /'
    fi
fi

log "════════════════════════════════════════════════════════════════"

exit 0
