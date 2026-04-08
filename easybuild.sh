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

TYPES=()
PARALLEL_JOBS=2
COUNTRIES=""
OUTPUT_BASE="output"
CONFIG_FILE="$BASE_DIR/countries.yml"
DEFAULT_MEMORY="8g"
FAILED_BUILDS="$WORK_DIR/failed_builds.txt"
touch "$FAILED_BUILDS"


if [ -z "${_JAVA_OPTIONS+x}" ]; then
    AUTO_JAVA_MEM=true
else
    AUTO_JAVA_MEM=false
    debug "found external _JAVA_OPTIONS: $_JAVA_OPTIONS"
fi

usage() {
    cat << 'EOF'
Local BCS300 Map Builder
========================

Usage: ./easybuild.sh [OPTIONS]

Options:
    -p               Prepare only (download & compile tools, no maps)
    -a               Build all countries
    -t TYPE[,TYPE]   Build type(s) (default: all types)
                     Comma-separated for multiple, e.g. -t water,green
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

    # Build all countries, all types
    ./easybuild.sh -a

    # Build specific type for Germany with 8 parallel jobs
    ./easybuild.sh -t water -c germany -j 8 -v

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
        t) 
            IFS=',' read -ra TYPES <<< "$OPTARG"
            for t in "${TYPES[@]}"; do
                is_valid_map_type "$t" || error "Invalid type: $t. Available: $AVAILABLE_MAP_TYPES"
            done
            ;;
        j) PARALLEL_JOBS="$OPTARG"
           if [ "$PARALLEL_JOBS" -gt 4 ]; then
               warn "More than 4 parallel jobs can cause high resource usage!"
           fi
           ;;
        c) COUNTRIES="$OPTARG" ;;
        o) OUTPUT_BASE="$OPTARG" ;;
        v) VERBOSE=true ;;
        h) usage; exit 0 ;;
        *) usage; exit 1 ;;
    esac
done

# Default: wenn keine types angegeben, alle bauen

if [ ${#TYPES[@]} -eq 0 ]; then
    read -ra TYPES <<< "$AVAILABLE_MAP_TYPES"
    info "No type specified, building all: ${TYPES[*]}"
fi

# Prepare mode

if [ "$PREPARE_ONLY" = true ]; then
    log "Preparing environment..."
    
    log "Checking system tools..."
    command -v curl >/dev/null 2>&1 || error "curl not found. Install: sudo apt install curl"
    command -v python3 >/dev/null 2>&1 || error "python3 not found. Install: sudo apt install python3"
    command -v unzip >/dev/null 2>&1 || error "unzip not found. Install: sudo apt install unzip"
    command -v gcc >/dev/null 2>&1 || error "gcc not found. Install: sudo apt install gcc"
    command -v java >/dev/null 2>&1 || error "java not found. Install: sudo apt install default-jre"
    command -v parallel >/dev/null 2>&1 || warn "GNU parallel not found. Install for faster builds: sudo apt install parallel"
    log "✓ System tools OK"
    
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
    
    if [ ! -d "$BASE_DIR/osmosis/bin" ] || [ ! -f "$BASE_DIR/osmosis/osmconvert" ]; then
        log "Setting up osmosis and tools..."
        cd "$BASE_DIR"
        if [ "$VERBOSE" = true ]; then
            bash setup_env.sh || error "Failed to setup osmosis"
        else
            bash setup_env.sh >/dev/null || error "Failed to setup osmosis"
        fi
    else
        log "✓ Osmosis already installed"
    fi
    
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

parse_countries() {
    python3 - "$CONFIG_FILE" "$COUNTRIES" "$DEFAULT_MEMORY" << 'PYEOF'
import sys, yaml

with open(sys.argv[1]) as f: 
    data = yaml.safe_load(f)

default_memory = sys.argv[3]

if sys.argv[2] == "all":
    countries_to_build = list(data['countries'].keys())
else:
    countries_to_build = [c.strip() for c in sys.argv[2].split(',')]

for country_spec in countries_to_build:
    # Check if specific region requested: "germany/bayern"
    if '/' in country_spec:
        country, requested_region = country_spec.split('/', 1)
        country = country.strip()
        requested_region = requested_region.strip()
        
        if country not in data['countries']:
            print(f"ERROR: Country '{country}' not found", file=sys.stderr)
            continue
        
        d = data['countries'][country]
        memory = d.get('memory', default_memory)
        
        if 'regions' not in d:
            print(f"ERROR: Country '{country}' has no regions", file=sys.stderr)
            continue
        
        # Find the specific region
        found = False
        for r in d['regions']:
            if r['name'] == requested_region:
                print(f"{country}\t{r['name']}\t{r['url']}\t{r['state']}\t{d['code']}\t{memory}")
                found = True
                break
        
        if not found:
            print(f"ERROR: Region '{requested_region}' not found in '{country}'", file=sys.stderr)
    
    else:
        # Normal country (all regions or single file)
        country = country_spec.strip()
        
        if country not in data['countries']:
            print(f"ERROR: Country '{country}' not found", file=sys.stderr)
            continue
        
        d = data['countries'][country]
        memory = d.get('memory', default_memory)
        
        if 'regions' in d:
            # Country with regions - output all
            for r in d['regions']:
                print(f"{country}\t{r['name']}\t{r['url']}\t{r['state']}\t{d['code']}\t{memory}")
        else:
            # Single-file country
            print(f"{country}\t{country}\t{d['url']}\t{d.get('state','00')}\t{d['code']}\t{memory}")
PYEOF
}

runtime_check() {
    log "Checking runtime prerequisites..."
    
    [ ! -f "$BASE_DIR/osmosis/osmconvert" ] && error "osmosis not found! Run with -p first."
    [ ! -f "$BASE_DIR/osmosis/osmfilter" ] && error "osmfilter not found! Run with -p first."
    [ ! -f "$BASE_DIR/generate_map.py" ] && error "generate_map.py not found!"
    
    python3 -c "import numpy, yaml" 2>/dev/null || error "Python packages missing! Run with -p first."
    
    mkdir -p "$BASE_DIR/$OUTPUT_BASE"
    
    log "✓ Runtime check passed"
}

# Phase 1: Download and convert

download_and_convert() {
    local task_file="$1"
    local work_base="$2"
    
    IFS=$'\t' read -r country region url state countrycode memory < "$task_file"
    
    local region_work="${work_base}/${country}-${region}"
    mkdir -p "$region_work"
    cd "$region_work"
    
    info "Phase 1: $country/$region - Download & Convert"
    
    # Download
    log "  → Downloading OSM data..."
    if [ "$VERBOSE" = true ]; then
        curl -L $url -o tmp.pbf -s -w "%{size_download} %{time_total}\n" | awk 'NF {printf("Downloaded %.2f MB in %.2fs (%.2f MB/s)\n", $1/1048576, $2, ($1/1048576)/$2)}'
    else
        curl -L $url -o tmp.pbf -sS 2>&1
    fi
    
    if [ ! -s tmp.pbf ]; then
        warn "  Download failed: $country/$region"
        echo "FAILED" > status.txt
        return 1
    fi
    
    # Convert to O5M
    log "  → Converting to O5M..."
    if [ "$VERBOSE" = true ]; then
        "$BASE_DIR/osmosis/osmconvert" tmp.pbf -o=tmp.o5m
    else
        "$BASE_DIR/osmosis/osmconvert" tmp.pbf -o=tmp.o5m >/dev/null 2>&1
    fi
    
    if [ ! -s tmp.o5m ]; then
        warn "  Convert failed: $country/$region"
        echo "FAILED" > status.txt
        return 1
    fi
    
    rm tmp.pbf
    echo "OK" > status.txt
    log "  ✓ Ready for type builds"
}


# Progress wrapper function

build_type_with_progress() {
    local task_file="$1"
    local total="$2"
    local start_time="$3"
    
    # Extract task number from filename (task_42.txt -> 42)
    local task_num=$(basename "$task_file" | sed 's/task_\([0-9]*\)\.txt/\1/')
    
    # Build the type
    build_type "$task_file"
    local result=$?
    
    # Calculate stats
    local elapsed=$(($(date +%s) - start_time))
    local percent=$((task_num * 100 / total))
    
    # Calculate ETA
    local eta_str=""
    if [ $task_num -gt 0 ]; then
        local avg_time=$((elapsed / task_num))
        local remaining=$((total - task_num))
        local eta_seconds=$((avg_time * remaining))
        eta_str=" | ETA: $(format_duration $eta_seconds)"
    fi
    
    log "Progress: $task_num/$total ($percent%) | Elapsed: $(format_duration $elapsed)$eta_str"
    
    return $result
}

export -f build_type_with_progress

# Phase 2: Build one type for one region
build_type() {
    local task_file="$1"
    
    # Read task info inkl. memory
    IFS=$'\t' read -r region_work type code state country region memory < "$task_file"
    
    # Check phase 1 success
    if [ ! -f "$region_work/status.txt" ] || [ "$(cat "$region_work/status.txt")" != "OK" ]; then
        warn "Skipping $country/$region/$type - Phase 1 failed"
        return 1
    fi
    
    if [ ! -f "$region_work/tmp.o5m" ]; then
        warn "Skipping $country/$region/$type - tmp.o5m not found"
        return 1
    fi
    
    # Source map-types in subshell
    source "$BASE_DIR/map-types.conf"
    
    local type_work="${region_work}/${type}"
    mkdir -p "$type_work"
    cd "$type_work"
    
    info "Phase 2: $country/$region/$type - Building map"
    
    local output_dir="$BASE_DIR/$OUTPUT_BASE/${type}"
    mkdir -p "$output_dir"
    
    # Filter
    log "  → Filtering ($type)..."
    local filter_cmd=$(get_filter_cmd "$type" "$VERBOSE" "$BASE_DIR/osmosis/osmfilter")
    filter_cmd="${filter_cmd/tmp.o5m/../tmp.o5m}"
    eval "$filter_cmd > tmp1.o5m" 2>&1 || { warn "  Filter failed"; return 1; }
    
    # Modify
    log "  → Modifying tags..."
    local modify_cmd=$(get_modify_cmd "$type" "$VERBOSE" "$BASE_DIR/osmosis/osmfilter")
    eval "$modify_cmd > tmp_filtered.o5m" 2>&1 || { warn "  Modify failed"; rm tmp1.o5m; return 1; }
    rm tmp1.o5m
    
    # Convert to PBF
    log "  → Converting to PBF..."
    if [ "$VERBOSE" = true ]; then
        "$BASE_DIR/osmosis/osmconvert" tmp_filtered.o5m -o=tmp_filtered.pbf
    else
        "$BASE_DIR/osmosis/osmconvert" tmp_filtered.o5m -o=tmp_filtered.pbf >/dev/null
    fi
    rm tmp_filtered.o5m
    
    # Build map
    log "  → Building map with Mapsforge..."
    local abs_input="$(pwd)/tmp_filtered.pbf"
    local tag_file=$(get_tag_file "$type")
    local abs_tag_file="$BASE_DIR/$tag_file"
    
    [ ! -L osmosis ] && ln -sf "$BASE_DIR/osmosis" osmosis
    
    if [ ! -f "$abs_tag_file" ]; then
        warn "  Tag file not found: $abs_tag_file"
        rm tmp_filtered.pbf
        return 1
    fi
    
    # Use memory from config or external override
    local java_opts
    if [ "$AUTO_JAVA_MEM" = true ]; then
        java_opts="-Xmx${memory} -Xms4g -XX:+UseG1GC -XX:+UseStringDeduplication "
        debug "Using memory from config for $country: $java_opts"
    else
        java_opts="$_JAVA_OPTIONS"
        debug "Using external _JAVA_OPTIONS: $java_opts"
    fi
    
    if [ "$VERBOSE" = true ]; then
        _JAVA_OPTIONS="$java_opts" python3 "$BASE_DIR/generate_map.py" -i "$abs_input" -c "$code" -s "$state" -t "$abs_tag_file"
    else
        _JAVA_OPTIONS="$java_opts" python3 "$BASE_DIR/generate_map.py" -i "$abs_input" -c "$code" -s "$state" -t "$abs_tag_file" >/dev/null
    fi
    
    # Move maps
    local moved=0
    for mapfile in *.map; do
        [ -f "$mapfile" ] && [ "$mapfile" != "*.map" ] || continue
        
        if [[ "$mapfile" == ${code}${state}* ]]; then
            log "  ✓ Created: $mapfile"
            mv "$mapfile" "${output_dir}/"
            moved=$((moved + 1))
        else
            warn "  Wrong format: $mapfile"
            mv "$mapfile" "${output_dir}/${mapfile}.wrong-format"
        fi
    done
    
    [ $moved -eq 0 ] && { 
        warn "  No map created for $type"
        echo "$country/$region/$type" >> "$FAILED_BUILDS"
    }

    rm tmp_filtered.pbf 2>/dev/null || true
}

# Export functions for parallel

export -f download_and_convert build_type format_duration log info warn error debug
export -f get_filter_cmd get_modify_cmd get_tag_file get_description is_valid_map_type
export VERBOSE BASE_DIR OUTPUT_BASE AUTO_JAVA_MEM DEFAULT_MEMORY CONFIG_FILE FAILED_BUILDS

# ═══════════════════════════════════════════════════════════

# MAIN EXECUTION

# ═══════════════════════════════════════════════════════════

START_TIME=$(date +%s)

runtime_check

log "════════════════════════════════════════════"
log "Starting 2-Phase Build Process"
info "Types: ${TYPES[*]} (${#TYPES[@]} type(s))"
info "Parallel jobs: $PARALLEL_JOBS"
info "Output: $BASE_DIR/$OUTPUT_BASE/"
log "════════════════════════════════════════════"

[ -z "$COUNTRIES" ] && COUNTRIES="all"

# Create work directory

WORK_DIR="$BASE_DIR/$OUTPUT_BASE/.work-$$"
mkdir -p "$WORK_DIR"

# Parse regions

ALL_REGIONS=$(mktemp)
parse_countries > "$ALL_REGIONS" 2>&1

if [ ! -s "$ALL_REGIONS" ]; then
    rm -rf "$WORK_DIR" "$ALL_REGIONS"
    error "No valid countries found!"
fi

# Create phase 1 task files

PHASE1_DIR="$WORK_DIR/phase1-tasks"
mkdir -p "$PHASE1_DIR"

REGION_COUNT=0
while IFS=$'\t' read -r country region url state code memory; do
    [ -z "$country" ] && continue
    REGION_COUNT=$((REGION_COUNT + 1))
    printf "%s\t%s\t%s\t%s\t%s\t%s\n" "$country" "$region" "$url" "$state" "$code" "${memory:-$DEFAULT_MEMORY}" > "$PHASE1_DIR/region_${REGION_COUNT}.txt"
done < "$ALL_REGIONS"

rm "$ALL_REGIONS"

[ "$REGION_COUNT" -eq 0 ] && { rm -rf "$WORK_DIR"; error "No regions found!"; }

log "Found $REGION_COUNT region(s) to process"

# ═══════════════════════════════════════════════════════════

# PHASE 1: Download & Convert

# ═══════════════════════════════════════════════════════════

log ""
log "═══════════════════════════════════════════"
log "PHASE 1: Download & Convert Regions"
log "═══════════════════════════════════════════"

PHASE1_START=$(date +%s)

if command -v parallel >/dev/null && [ "$PARALLEL_JOBS" -gt 1 ]; then
    log "Using GNU parallel with $PARALLEL_JOBS jobs"
    ls "$PHASE1_DIR"/region_*.txt | parallel -j "$PARALLEL_JOBS" download_and_convert {} "$WORK_DIR"
else
    [ "$PARALLEL_JOBS" -gt 1 ] && warn "GNU parallel not found, using sequential"
    for task_file in "$PHASE1_DIR"/region_*.txt; do
        download_and_convert "$task_file" "$WORK_DIR"
    done
fi

PHASE1_END=$(date +%s)
PHASE1_DURATION=$((PHASE1_END - PHASE1_START))

log "Phase 1 completed in $(format_duration $PHASE1_DURATION)"

# Check successful downloads

SUCCEEDED=0
for region_dir in "$WORK_DIR"/*; do
    [ ! -d "$region_dir" ] && continue
    [ "$(basename "$region_dir")" = "phase1-tasks" ] && continue
    [ -f "$region_dir/status.txt" ] && [ "$(cat "$region_dir/status.txt")" = "OK" ] && SUCCEEDED=$((SUCCEEDED + 1))
done

log "Successful downloads: $SUCCEEDED/$REGION_COUNT"

[ $SUCCEEDED -eq 0 ] && error "No regions downloaded successfully!"

# ═══════════════════════════════════════════════════════════

# PHASE 2: Build Types

# ═══════════════════════════════════════════════════════════

log ""
log "═══════════════════════════════════════════"
log "PHASE 2: Build Map Types"
log "═══════════════════════════════════════════"

PHASE2_START=$(date +%s)


# Create phase 2 task files

PHASE2_DIR="$WORK_DIR/phase2-tasks"
mkdir -p "$PHASE2_DIR"

TASK_COUNT=0
for task_file in "$PHASE1_DIR"/region_*.txt; do
    IFS=$'\t' read -r country region url state code memory < "$task_file"
    region_work="$WORK_DIR/${country}-${region}"
    
    # Only for successful phase 1
    if [ -f "$region_work/status.txt" ] && [ "$(cat "$region_work/status.txt")" = "OK" ]; then
        for type in "${TYPES[@]}"; do
            TASK_COUNT=$((TASK_COUNT + 1))
            printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "$region_work" "$type" "$code" "$state" "$country" "$region" "${memory:-$DEFAULT_MEMORY}" > "$PHASE2_DIR/task_${TASK_COUNT}.txt"
        done
    fi
done

log "Building $TASK_COUNT map(s) ($SUCCEEDED regions × ${#TYPES[@]} types)"

# Separate high-memory tasks

HIGHMEM_TASKS=$(mktemp)
NORMAL_TASKS=$(mktemp)

for task_file in "$PHASE2_DIR"/task_*.txt; do
    IFS=$'\t' read -r region_work type code state country region memory < "$task_file"
    if [ "$memory" != "$DEFAULT_MEMORY" ]; then
        echo "$task_file" >> "$HIGHMEM_TASKS"
    else
        echo "$task_file" >> "$NORMAL_TASKS"
    fi
done

HIGHMEM_COUNT=$(wc -l < "$HIGHMEM_TASKS" 2>/dev/null || echo 0)
NORMAL_COUNT=$(wc -l < "$NORMAL_TASKS" 2>/dev/null || echo 0)

if [ $HIGHMEM_COUNT -gt 0 ]; then
    log "Building $HIGHMEM_COUNT high-memory map(s) sequentially (j=1)"
    while read -r task_file; do
        build_type_with_progress "$task_file" "$TASK_COUNT" "$PHASE2_START"
    done < "$HIGHMEM_TASKS"
fi

if [ $NORMAL_COUNT -gt 0 ]; then
    log "Building $NORMAL_COUNT normal map(s) with $PARALLEL_JOBS jobs"
    if command -v parallel >/dev/null 2>&1 && [ "$PARALLEL_JOBS" -gt 1 ]; then
        log "Using GNU parallel with $PARALLEL_JOBS jobs"
        cat "$NORMAL_TASKS" | parallel -j "$PARALLEL_JOBS" build_type_with_progress {} "$TASK_COUNT" "$PHASE2_START"
    else
        while read -r task_file; do
            build_type_with_progress "$task_file" "$TASK_COUNT" "$PHASE2_START"
        done < "$NORMAL_TASKS"
    fi
fi

rm -f "$HIGHMEM_TASKS" "$NORMAL_TASKS"

PHASE2_END=$(date +%s)
PHASE2_DURATION=$((PHASE2_END - PHASE2_START))

log "Phase 2 completed in $(format_duration $PHASE2_DURATION)"

# ═══════════════════════════════════════════════════════════

# CLEANUP

# ═══════════════════════════════════════════════════════════

log ""
log "Cleaning up temporary files..."
rm -rf "$WORK_DIR"

END_TIME=$(date +%s)
TOTAL_DURATION=$((END_TIME - START_TIME))

log ""
log "════════════════════════════════════════════"
log "Build Complete!"
log "════════════════════════════════════════════"
log "Total time: $(format_duration $TOTAL_DURATION)"
log "  Phase 1 (Download): $(format_duration $PHASE1_DURATION)"
log "  Phase 2 (Build):    $(format_duration $PHASE2_DURATION)"
log ""

MAP_COUNT=$(find "$BASE_DIR/$OUTPUT_BASE" -name "*.map" 2>/dev/null | wc -l)
log "Maps created: $MAP_COUNT"

if [ "$MAP_COUNT" -gt 0 ]; then
    log "Output directory: $BASE_DIR/$OUTPUT_BASE/"
    log "Total size: $(du -sh "$BASE_DIR/$OUTPUT_BASE" 2>/dev/null | cut -f1)"
    log ""
    log "Maps by type:"
    for type in "${TYPES[@]}"; do
        if [ -d "$BASE_DIR/$OUTPUT_BASE/$type" ]; then
            type_count=$(find "$BASE_DIR/$OUTPUT_BASE/$type" -name "*.map" 2>/dev/null | wc -l)
            type_size=$(du -sh "$BASE_DIR/$OUTPUT_BASE/$type" 2>/dev/null | cut -f1)
            log "  - $type: $type_count maps ($type_size)"
        fi
    done
fi

log "════════════════════════════════════════════"

if [ -f "$FAILED_BUILDS" ] && [ -s "$FAILED_BUILDS" ]; then
    warn "Some builds FAILED:"
    cat "$FAILED_BUILDS"
    exit 2
fi

exit 0
