#!/bin/bash

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

VERBOSE=false
PREPARE_ONLY=false

log() { echo -e "${GREEN}[$(date +'%H:%M:%S')]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; [ "$PREPARE_ONLY" = false ] && usage; exit 1; }
warn() { echo -e "${YELLOW}[WARNING]${NC} $1" >&2; }
info() { echo -e "${BLUE}[INFO]${NC} $1"; }
debug() { [ "$VERBOSE" = true ] && echo -e "${BLUE}[DEBUG]${NC} $1" || true; }

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

# Load map types

source "$BASE_DIR/map-types.conf" || error "Failed to load map-types.conf"

TYPE="water"
PARALLEL_JOBS=2
COUNTRIES=""
OUTPUT_BASE="output"
CONFIG_FILE="$BASE_DIR/countries.yml"

usage() {
    cat << 'EOF'
Local BCS300 Map Builder
========================

Usage: ./easybuild.sh [OPTIONS]

Options:
    -p               Prepare only (download & compile tools, no maps)
    -a               Build all countries
    -t TYPE          Build type (default: water)
EOF
    
    for map_type in $AVAILABLE_MAP_TYPES; do
        printf "                     - %-15s : %s\n" "$map_type" "$(get_description "$map_type")"
    done
    
    cat << 'EOF'
    
    -j JOBS          Parallel jobs (default: 2)
    -c COUNTRIES     Comma-separated country list (default: all)
    -o OUTPUT        Output directory (default: output)
    -v               Verbose mode (show all tool output)
    -h               Show this help

Examples:
    # Prepare environment (for Dockerfile)
    ./easybuild.sh -p

    # Build all countries
    ./easybuild.sh -a

    # Build with verbose
    ./easybuild.sh -t water -j 8 -v

Available countries:
EOF
    python3 -c "
import yaml
with open('$CONFIG_FILE', 'r') as f:
    data = yaml.safe_load(f)
    for country in sorted(data['countries'].keys()):
        print(f'    - {country}')
" 2>/dev/null || echo "    (countries.yml not found)"
}

while getopts "pat:j:c:o:vh" opt; do
    case $opt in
        p) PREPARE_ONLY=true ;;
        a) COUNTRIES="all" ;;
        t) TYPE="$OPTARG" ;;
        j) PARALLEL_JOBS="$OPTARG"
           if [ "$PARALLEL_JOBS" -gt 2 ]; then
               warn "More than 2 parallel jobs can cause resource issues!"
           fi
           ;;
        c) COUNTRIES="$OPTARG" ;;
        o) OUTPUT_BASE="$OPTARG" ;;
        v) VERBOSE=true ;;
        h) usage; exit 0 ;;
        *) usage; exit 1 ;;
    esac
done

# Prepare mode: setup everything, then exit

if [ "$PREPARE_ONLY" = true ]; then
    log "Preparing environment..."
    
    # Check basic tools
    log "Checking system tools..."
    command -v wget >/dev/null 2>&1 || error "wget not found. Install: sudo apt install wget"
    command -v python3 >/dev/null 2>&1 || error "python3 not found. Install: sudo apt install python3"
    command -v unzip >/dev/null 2>&1 || error "unzip not found. Install: sudo apt install unzip"
    command -v gcc >/dev/null 2>&1 || error "gcc not found. Install: sudo apt install gcc"
    command -v java >/dev/null 2>&1 || error "java not found. Install: sudo apt install default-jre"
    command -v parallel >/dev/null 2>&1 || warn "GNU parallel not found. Install for faster builds: sudo apt install parallel"
    log "✓ System tools OK"
    
    # Check/install Python packages
    log "Checking Python packages..."
    python3 -c "import numpy" 2>/dev/null || {
        log "Installing numpy..."
        pip3 install numpy || error "Failed to install numpy"
    }
    python3 -c "import yaml" 2>/dev/null || {
        log "Installing pyyaml..."
        pip3 install pyyaml || error "Failed to install pyyaml"
    }
    log "✓ Python packages OK"
    
    # Setup osmosis
    if [ ! -d "$BASE_DIR/osmosis/bin" ] || [ ! -f "$BASE_DIR/osmosis/osmconvert" ]; then
        log "Setting up osmosis and tools (this may take a moment)..."
        cd "$BASE_DIR"
        if [ "$VERBOSE" = true ]; then
            bash setup_env.sh || error "Failed to setup osmosis"
        else
            bash setup_env.sh >/dev/null 2>&1 || error "Failed to setup osmosis"
        fi
    else
        log "✓ Osmosis already installed"
    fi
    
    # Verify installation
    log "Verifying installation..."
    [ ! -f "$BASE_DIR/osmosis/osmconvert" ] && error "osmosis/osmconvert not found!"
    [ ! -f "$BASE_DIR/osmosis/osmfilter" ] && error "osmosis/osmfilter not found!"
    [ ! -f "$BASE_DIR/generate_map.py" ] && error "generate_map.py not found!"
    
    if ! ls "$BASE_DIR/osmosis/bin/plugins/mapsforge-map-writer-"*.jar >/dev/null 2>&1; then
        error "Mapsforge plugin not found in osmosis/bin/plugins/"
    fi
    
    log "════════════════════════════════════════════"
    log "✓ Environment prepared successfully!"
    log "Ready to build maps."
    log "════════════════════════════════════════════"
    exit 0
fi

# Normal mode: validate type

is_valid_map_type "$TYPE" || error "Invalid type: $TYPE. Use: $AVAILABLE_MAP_TYPES"

parse_countries() {
    python3 - "$CONFIG_FILE" "$COUNTRIES" << 'PYEOF'
import sys, yaml
with open(sys.argv[1]) as f: data = yaml.safe_load(f)
countries = data['countries'].keys() if sys.argv[2] == "all" else [c.strip() for c in sys.argv[2].split(',')]
for c in countries:
    if c not in data['countries']: continue
    d = data['countries'][c]
    if 'regions' in d:
        for r in d['regions']: print(f"{c}\t{r['name']}\t{r['url']}\t{r['state']}\t{d['code']}")
    else: print(f"{c}\t{c}\t{d['url']}\t{d.get('state','00')}\t{d['code']}")
PYEOF
}

export -f format_duration log info warn error debug
export VERBOSE TYPE OUTPUT_BASE BASE_DIR

runtime_check() {
    log "Checking runtime prerequisites..."
    
    # Quick check that tools exist (already installed in prepare)
    [ ! -f "$BASE_DIR/osmosis/osmconvert" ] && error "osmosis not found! Run with -p first."
    [ ! -f "$BASE_DIR/osmosis/osmfilter" ] && error "osmfilter not found! Run with -p first."
    [ ! -f "$BASE_DIR/generate_map.py" ] && error "generate_map.py not found!"
    
    python3 -c "import numpy, yaml" 2>/dev/null || error "Python packages missing! Run with -p first."
    
    mkdir -p "$BASE_DIR/$OUTPUT_BASE"
    
    log "✓ Runtime check passed"
}

build_single() {
    local task_file="$1"
    
    # Load config in subshell
    source "$BASE_DIR/map-types.conf"
    
    IFS=$'\t' read -r country region url state countrycode < "$task_file"
    
    local work_dir="$BASE_DIR/$OUTPUT_BASE/.tmp/${country}-${region}-$$-$RANDOM"
    local output_dir="$BASE_DIR/$OUTPUT_BASE/${TYPE}"
    
    mkdir -p "$work_dir" "$output_dir"
    cd "$work_dir"
    
    info "════════════════════════════════════════════════════════════"
    info "Building: $country/$region ($TYPE)"
    debug "Country Code: $countrycode | State: $state"
    
    # Download
    log "→ Downloading OSM data..."
    if [ "$VERBOSE" = true ]; then
        wget --show-progress "$url" -O tmp.pbf 2>&1
    else
        wget -q "$url" -O tmp.pbf 2>&1
    fi
    
    if [ ! -s tmp.pbf ]; then
        warn "Download failed: $country/$region"
        cd "$BASE_DIR" && rm -rf "$work_dir"
        return 1
    fi
    debug "Downloaded: $(du -h tmp.pbf | cut -f1)"
    
    # Convert to O5M
    log "→ Converting to O5M..."
    if [ "$VERBOSE" = true ]; then
        "$BASE_DIR/osmosis/osmconvert" tmp.pbf -o=tmp.o5m
    else
        "$BASE_DIR/osmosis/osmconvert" tmp.pbf -o=tmp.o5m >/dev/null 2>&1
    fi
    rm tmp.pbf
    debug "Converted: $(du -h tmp.o5m | cut -f1)"
    
    # Filter using function from config
    log "→ Filtering ($TYPE)..."
    local filter_cmd=$(get_filter_cmd "$TYPE" "$VERBOSE" "$BASE_DIR/osmosis/osmfilter")
    eval "$filter_cmd > tmp1.o5m"
    rm tmp.o5m
    debug "Filtered: $(du -h tmp1.o5m | cut -f1)"
    
    # Modify tags using function from config
    log "→ Modifying tags..."
    local modify_cmd=$(get_modify_cmd "$TYPE" "$VERBOSE" "$BASE_DIR/osmosis/osmfilter")
    eval "$modify_cmd > tmp_filtered.o5m"
    rm tmp1.o5m
    debug "Modified: $(du -h tmp_filtered.o5m | cut -f1)"
    
    # Convert to PBF
    log "→ Converting to PBF..."
    if [ "$VERBOSE" = true ]; then
        "$BASE_DIR/osmosis/osmconvert" tmp_filtered.o5m -o=tmp_filtered.pbf
    else
        "$BASE_DIR/osmosis/osmconvert" tmp_filtered.o5m -o=tmp_filtered.pbf >/dev/null 2>&1
    fi
    rm tmp_filtered.o5m
    debug "Final PBF: $(du -h tmp_filtered.pbf | cut -f1)"
    
    # Build map
    log "→ Building map with Mapsforge..."
    local abs_input="$(pwd)/tmp_filtered.pbf"
    local tag_file=$(get_tag_file "$TYPE")
    local abs_tag_file="$BASE_DIR/$tag_file"
    
    # Symlink osmosis in working directory
    ln -sf "$BASE_DIR/osmosis" osmosis
    
    debug "Input: $abs_input"
    debug "Tag file: $abs_tag_file"
    
    # Verify tag file exists
    if [ ! -f "$abs_tag_file" ]; then
        warn "Tag file not found: $abs_tag_file"
        cd "$BASE_DIR" && rm -rf "$work_dir"
        return 1
    fi
    
    if [ "$VERBOSE" = true ]; then
        python3 "$BASE_DIR/generate_map.py" -i "$abs_input" -c "$countrycode" -s "$state" -t "$abs_tag_file"
    else
        python3 "$BASE_DIR/generate_map.py" -i "$abs_input" -c "$countrycode" -s "$state" -t "$abs_tag_file" >/dev/null 2>&1
    fi
    
    # Move generated maps
    local moved_count=0
    for mapfile in *.map; do
        if [ -f "$mapfile" ] && [ "$mapfile" != "*.map" ]; then
            debug "Found: $mapfile ($(du -h "$mapfile" | cut -f1))"
            
            if [[ "$mapfile" == ${countrycode}${state}* ]]; then
                log "✓ Created: $mapfile"
                mv "$mapfile" "${output_dir}/"
                moved_count=$((moved_count + 1))
            else
                warn "Wrong format: $mapfile"
                mv "$mapfile" "${output_dir}/${mapfile}.wrong-format"
            fi
        fi
    done
    
    [ $moved_count -eq 0 ] && warn "No map file created for $country/$region"
    
    cd "$BASE_DIR"
    rm -rf "$work_dir"
    
    info "════════════════════════════════════════════════════════════"
}

export -f build_single

# Main

START_TIME=$(date +%s)

runtime_check

log "Starting batch build"
info "Type: $TYPE ($(get_description "$TYPE"))"
info "Parallel jobs: $PARALLEL_JOBS | Verbose: $VERBOSE"
info "Output: $BASE_DIR/$OUTPUT_BASE/$TYPE/"

[ -z "$COUNTRIES" ] && COUNTRIES="all"

TASKS_DIR=$(mktemp -d)
ALL_TASKS=$(mktemp)

parse_countries > "$ALL_TASKS" 2>&1

if [ ! -s "$ALL_TASKS" ]; then
    rm -rf "$TASKS_DIR" "$ALL_TASKS"
    error "No valid countries found!"
fi

TASK_NUM=0
while IFS=$'\t' read -r c r u s code; do
    [ -z "$c" ] && continue
    TASK_NUM=$((TASK_NUM + 1))
    printf "%s\t%s\t%s\t%s\t%s\n" "$c" "$r" "$u" "$s" "$code" > "$TASKS_DIR/task_${TASK_NUM}.txt"
done < "$ALL_TASKS"

rm "$ALL_TASKS"

TOTAL_TASKS=$(ls "$TASKS_DIR"/task_*.txt 2>/dev/null | wc -l)

[ "$TOTAL_TASKS" -eq 0 ] && { rm -rf "$TASKS_DIR"; error "No tasks found!"; }

log "Building $TOTAL_TASKS map(s)"

if command -v parallel >/dev/null 2>&1 && [ "$PARALLEL_JOBS" -gt 1 ]; then
    log "Using GNU parallel with $PARALLEL_JOBS jobs"
    ls "$TASKS_DIR"/task_*.txt | parallel -j "$PARALLEL_JOBS" build_single {}
else
    [ "$PARALLEL_JOBS" -gt 1 ] && warn "GNU parallel not found, using sequential"
    for task_file in "$TASKS_DIR"/task_*.txt; do
        build_single "$task_file"
    done
fi

rm -rf "$TASKS_DIR"

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

log "════════════════════════════════════════════"
log "Build complete! Time: $(format_duration $DURATION)"
log "Output: $BASE_DIR/$OUTPUT_BASE/$TYPE/"

MAP_COUNT=$(find "$BASE_DIR/$OUTPUT_BASE/$TYPE" -name "*.map" 2>/dev/null | wc -l)
log "Maps created: $MAP_COUNT"

[ "$MAP_COUNT" -gt 0 ] && log "Total size: $(du -sh "$BASE_DIR/$OUTPUT_BASE/$TYPE" 2>/dev/null | cut -f1)"

log "════════════════════════════════════════════"

exit 0
