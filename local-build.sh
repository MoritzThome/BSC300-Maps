#!/bin/bash

set -e

# Farben

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${GREEN}[$(date +'%H:%M:%S')]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
warn() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
info() { echo -e "${BLUE}[INFO]${NC} $1"; }
debug() { echo -e "${BLUE}[DEBUG]${NC} $1"; }

# Get absolute base directory

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Defaults

TYPE="green"
PARALLEL_JOBS=4
COUNTRIES=""
OUTPUT_BASE="output"

usage() {
    cat << 'EOF'
Local BCS300 Map Builder
========================

Usage: ./local-batch-build.sh [OPTIONS]

Options:
    -t TYPE          Build type (default: green)
                     - streets-only    : No street names
                     - streets-names   : With street names
                     - water          : With water features
                     - green          : With water + green areas (largest)
    
    -j JOBS          Parallel jobs (default: 4, max recommended: 8)
    -c COUNTRIES     Comma-separated country list (default: all)
    -o OUTPUT        Output directory (default: output)
    -h               Show this help

Examples:
    # Build all countries with green stuff, 4 parallel jobs
    ./local-batch-build.sh

    # Build only water maps, 8 parallel
    ./local-batch-build.sh -t water -j 8

    # Build specific countries
    ./local-batch-build.sh -c "albania,germany,switzerland" -t streets-only

    # Build single-threaded (for debugging)
    ./local-batch-build.sh -j 1

Available countries:
EOF
    ls "$BASE_DIR/.github/workflows/build-"*.yml 2>/dev/null | sed 's/.*build-//;s/.yml$//' | sort | sed 's/^/    - /'
    exit 0
}

# Parse arguments

while getopts "t:j:c:o:h" opt; do
    case $opt in
        t) TYPE="$OPTARG" ;;
        j) PARALLEL_JOBS="$OPTARG"
           if [ "$PARALLEL_JOBS" -gt 8 ]; then
               warn "More than 8 parallel jobs can cause resource issues!"
               warn "Each job uses ~2GB RAM. Recommended: 2-8 jobs."
           fi
           ;;
        c) COUNTRIES="$OPTARG" ;;
        o) OUTPUT_BASE="$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done

# Validate type

case "$TYPE" in
    streets-only|streets-names|water|green) ;;
    *) error "Invalid type: $TYPE. Use: streets-only, streets-names, water, green" ;;
esac

# Country-Code Mapping function (not associative array for parallel compatibility!)

get_country_code() {
    case "$1" in
        albania) echo "AL" ;;
        andorra) echo "AD" ;;
        austria) echo "AT" ;;
        belgium) echo "BE" ;;
        bosnia-herzegovina) echo "BA" ;;
        bulgaria) echo "BG" ;;
        croatia) echo "HR" ;;
        cyprus) echo "CY" ;;
        czech-republic) echo "CZ" ;;
        denmark) echo "DK" ;;
        estonia) echo "EE" ;;
        finland) echo "FI" ;;
        france) echo "FR" ;;
        germany) echo "DE" ;;
        greece) echo "GR" ;;
        hungary) echo "HU" ;;
        iceland) echo "IS" ;;
        ireland) echo "IE" ;;
        italy) echo "IT" ;;
        latvia) echo "LV" ;;
        liechtenstein) echo "LI" ;;
        lithuania) echo "LT" ;;
        luxembourg) echo "LU" ;;
        malta) echo "MT" ;;
        montenegro) echo "ME" ;;
        netherlands) echo "NL" ;;
        north-macedonia) echo "MK" ;;
        norway) echo "NO" ;;
        poland) echo "PL" ;;
        portugal) echo "PT" ;;
        romania) echo "RO" ;;
        serbia) echo "RS" ;;
        slovakia) echo "SK" ;;
        slovenia) echo "SI" ;;
        spain) echo "ES" ;;
        sweden) echo "SE" ;;
        switzerland) echo "CH" ;;
        united-kingdom) echo "GB" ;;
        *) echo "XX" ;;
    esac
}

export -f get_country_code

# Get country list

if [ -z "$COUNTRIES" ]; then
    COUNTRY_LIST=$(ls "$BASE_DIR/.github/workflows/build-"*.yml 2>/dev/null | sed 's/.*build-//;s/.yml$//' | sort)
else
    COUNTRY_LIST=$(echo "$COUNTRIES" | tr ',' '\n')
fi

[ -z "$COUNTRY_LIST" ] && error "No countries found!"

# Setup check

setup_check() {
    log "Checking prerequisites..."
    
    command -v wget >/dev/null 2>&1 || error "wget not found. Install: sudo apt install wget"
    command -v python3 >/dev/null 2>&1 || error "python3 not found"
    command -v unzip >/dev/null 2>&1 || error "unzip not found. Install: sudo apt install unzip"
    command -v gcc >/dev/null 2>&1 || error "gcc not found. Install: sudo apt install gcc"
    
    python3 -c "import numpy" 2>/dev/null || {
        warn "numpy not found, installing..."
        pip install numpy
    }
    
    if [ ! -d "$BASE_DIR/osmosis/bin" ] || [ ! -f "$BASE_DIR/osmosis/osmconvert" ]; then
        log "Setting up osmosis (this may take a moment)..."
        cd "$BASE_DIR"
        bash setup_env.sh || error "Failed to setup osmosis"
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

# Parse YAML to extract map configs

parse_workflow() {
    local country="$1"
    local workflow_file="$BASE_DIR/.github/workflows/build-${country}.yml"
    
    [ ! -f "$workflow_file" ] && error "Workflow not found: $workflow_file"
    
    local maps_section=$(sed -n '/matrix:/,/^[[:space:]]*steps:/p' "$workflow_file" | grep -A 50 "maps:")
    
    echo "$maps_section" | grep -o '{[^}]*}' | while read -r map_entry; do
        local name=$(echo "$map_entry" | grep -o 'name: [^,]*' | sed 's/name: //')
        local url=$(echo "$map_entry" | grep -o 'url: [^,]*' | sed 's/url: //')
        local state=$(echo "$map_entry" | grep -o 'state: "[^"]*"' | sed 's/state: "//;s/"//')
        
        printf "%s\t%s\t%s\t%s\n" "$country" "$name" "$url" "$state"
    done
}

# Build single map

build_single() {
    local task_file="$1"
    
    IFS=$'\t' read -r country region url state < "$task_file"
    
    local countrycode=$(get_country_code "$country")
    local map_name="${region}"
    local work_dir="$BASE_DIR/$OUTPUT_BASE/.tmp/${country}-${region}-$$-$RANDOM"
    local output_dir="$BASE_DIR/$OUTPUT_BASE/${TYPE}"
    
    mkdir -p "$work_dir" "$output_dir"
    cd "$work_dir"
    
    info "═══════════════════════════════════════════════════════════"
    info "Building: $country/$region ($TYPE)"
    debug "Country: $country"
    debug "Region: $region"
    debug "Country Code: $countrycode"
    debug "State Code: $state"
    debug "URL: $url"
    debug "Work Dir: $work_dir"
    debug "Output Dir: $output_dir"
    
    # Download
    log "→ Downloading OSM data..."
    if ! wget -q --show-progress "$url" -O tmp.pbf 2>&1; then
        error "Download failed: $url"
    fi
    
    if [ ! -s tmp.pbf ]; then
        error "Downloaded file is empty: $url"
    fi
    debug "Downloaded: $(du -h tmp.pbf | cut -f1)"
    
    # Convert
    log "→ Converting to O5M..."
    "$BASE_DIR/osmosis/osmconvert" tmp.pbf -o=tmp.o5m
    debug "Converted: $(du -h tmp.o5m | cut -f1)"
    rm tmp.pbf
    
    # Filter based on type
    case "$TYPE" in
        streets-only)
            log "→ Filtering (streets-only - no names)..."
            "$BASE_DIR/osmosis/osmfilter" -v tmp.o5m \
                --keep="highway=primary =primary_link =secondary =secondary_link =tertiary =tertiary_link =trunk =trunk_link =cycleway =living_street =residential =road =track =unclassified" \
                --keep="highway=service and ( bicycle=designated or bicycle=yes or bicycle=permissive )" \
                --keep="highway=footway and ( bicycle=designated or bicycle=yes or bicycle=permissive )" \
                --keep="highway=bridleway and ( bicycle=designated or bicycle=yes or bicycle=permissive )" \
                --keep="highway=path and ( bicycle=designated or bicycle=yes or bicycle=permissive )" \
                --keep="highway=pedestrian and ( bicycle=designated or bicycle=yes or bicycle=permissive )" \
                --keep="highway=unclassified and ( bicycle=designated or bicycle=yes or bicycle=permissive )" \
                --keep="sidewalk:*:bicycle=yes" \
                --keep="route=bicycle =mtb" \
                --keep="cycleway:*=lane :*=track *:=shared_lane *:=share_busway *:=separate *:=crossing *:=shoulder *:=link *:=traffic_island" \
                --keep="bicycle_road=yes" \
                --keep="cyclestreet=yes" \
                --drop-tags="name= ref=" \
                --out-o5m > tmp1.o5m
            TAG_FILE="tags_minimal_street_only.xml"
            ;;
            
        streets-names)
            log "→ Filtering (streets with names)..."
            "$BASE_DIR/osmosis/osmfilter" -v tmp.o5m \
                --keep="highway=primary =primary_link =secondary =secondary_link =tertiary =tertiary_link =trunk =trunk_link =cycleway =living_street =residential =road =track =unclassified" \
                --keep="highway=service and ( bicycle=designated or bicycle=yes or bicycle=permissive )" \
                --keep="highway=footway and ( bicycle=designated or bicycle=yes or bicycle=permissive )" \
                --keep="highway=bridleway and ( bicycle=designated or bicycle=yes or bicycle=permissive )" \
                --keep="highway=path and ( bicycle=designated or bicycle=yes or bicycle=permissive )" \
                --keep="highway=pedestrian and ( bicycle=designated or bicycle=yes or bicycle=permissive )" \
                --keep="highway=unclassified and ( bicycle=designated or bicycle=yes or bicycle=permissive )" \
                --keep="sidewalk:*:bicycle=yes" \
                --keep="route=bicycle =mtb" \
                --keep="cycleway:*=lane :*=track *:=shared_lane *:=share_busway *:=separate *:=crossing *:=shoulder *:=link *:=traffic_island" \
                --keep="bicycle_road=yes" \
                --keep="cyclestreet=yes" \
                --out-o5m > tmp1.o5m
            TAG_FILE="tags_minimal_street_only.xml"
            ;;
            
        water)
            log "→ Filtering (streets + water)..."
            "$BASE_DIR/osmosis/osmfilter" -v tmp.o5m \
                --keep="highway=primary =primary_link =secondary =secondary_link =tertiary =tertiary_link =trunk =trunk_link =cycleway =living_street =residential =road =track =unclassified" \
                --keep="highway=service and ( bicycle=designated or bicycle=yes or bicycle=permissive )" \
                --keep="highway=footway and ( bicycle=designated or bicycle=yes or bicycle=permissive )" \
                --keep="highway=bridleway and ( bicycle=designated or bicycle=yes or bicycle=permissive )" \
                --keep="highway=path and ( bicycle=designated or bicycle=yes or bicycle=permissive )" \
                --keep="highway=pedestrian and ( bicycle=designated or bicycle=yes or bicycle=permissive )" \
                --keep="highway=unclassified and ( bicycle=designated or bicycle=yes or bicycle=permissive )" \
                --keep="sidewalk:*:bicycle=yes" \
                --keep="waterway= landuse= natural=" \
                --keep="route=bicycle =mtb" \
                --keep="cycleway:*=lane :*=track *:=shared_lane *:=share_busway *:=separate *:=crossing *:=shoulder *:=link *:=traffic_island" \
                --keep="bicycle_road=yes" \
                --keep="cyclestreet=yes" \
                --out-o5m > tmp1.o5m
            TAG_FILE="tags_with_water.xml"
            ;;
            
        green)
            log "→ Filtering (streets + water + green)..."
            "$BASE_DIR/osmosis/osmfilter" -v tmp.o5m \
                --keep="highway=primary =primary_link =secondary =secondary_link =tertiary =tertiary_link =trunk =trunk_link =cycleway =living_street =residential =road =track =unclassified" \
                --keep="highway=service and ( bicycle=designated or bicycle=yes or bicycle=permissive )" \
                --keep="highway=footway and ( bicycle=designated or bicycle=yes or bicycle=permissive )" \
                --keep="highway=bridleway and ( bicycle=designated or bicycle=yes or bicycle=permissive )" \
                --keep="highway=path and ( bicycle=designated or bicycle=yes or bicycle=permissive )" \
                --keep="highway=pedestrian and ( bicycle=designated or bicycle=yes or bicycle=permissive )" \
                --keep="highway=unclassified and ( bicycle=designated or bicycle=yes or bicycle=permissive )" \
                --keep="sidewalk:*:bicycle=yes" \
                --keep="waterway= landuse= natural= leisure=" \
                --keep="route=bicycle =mtb" \
                --keep="cycleway:*=lane :*=track *:=shared_lane *:=share_busway *:=separate *:=crossing *:=shoulder *:=link *:=traffic_island" \
                --keep="bicycle_road=yes" \
                --keep="cyclestreet=yes" \
                --out-o5m > tmp1.o5m
            TAG_FILE="tags_with_green_stuff.xml"
            ;;
    esac
    
    debug "Filtered: $(du -h tmp1.o5m | cut -f1)"
    
    # Modify tags
    log "→ Modifying tags..."
    if [ "$TYPE" = "green" ]; then
        EXTRA_TAGS="leisure=garden to landuse=grass leisure=playground to landuse=grass leisure=park to landuse=grass landuse=orchard to =grass landuse=allotments to =grass landuse=farmland to =grass landuse=flowerbed to =grass landuse=meadow to =grass landuse=plant_nursery to =grass landuse=vineyard to =grass landuse=greenfield to =grass landuse=village_green to =grass landuse=greenery to =grass landuse=cemetery to =grass natural=scrub to landuse=grass"
    else
        EXTRA_TAGS=""
    fi
    
    "$BASE_DIR/osmosis/osmfilter" -v tmp1.o5m --modify-tags=" \
        highway=trunk_link to =primary \
        highway=trunk to =primary \
        highway=primary_link to =primary \
        highway=tertiary_link to =tertiary \
        highway=secondary_link to =secondary \
        highway=footway to =cycleway \
        highway=bridleway to =cycleway \
        highway=sidewalk to =cycleway \
        highway=path to =cycleway \
        highway=pedestrian to =cycleway \
        highway=unclassified to =cycleway \
        $EXTRA_TAGS \
        " \
        --drop-author --drop-version --out-o5m > tmp_filtered.o5m
    
    rm tmp.o5m tmp1.o5m
    debug "Modified: $(du -h tmp_filtered.o5m | cut -f1)"
    
    # Convert to PBF
    log "→ Converting to PBF..."
    "$BASE_DIR/osmosis/osmconvert" tmp_filtered.o5m -o=tmp_filtered.pbf
    rm tmp_filtered.o5m
    debug "Final PBF: $(du -h tmp_filtered.pbf | cut -f1)"
    
    # Build map
    log "→ Building map with Mapsforge..."
    local abs_input="$(pwd)/tmp_filtered.pbf"
    
    # Create symlink to osmosis (generate_map.py needs it in CWD)
    ln -sf "$BASE_DIR/osmosis" osmosis
    
    debug "Calling generate_map.py:"
    debug "  Input: $abs_input"
    debug "  Country Code: $countrycode"
    debug "  State Code: $state"
    debug "  Tag File: $BASE_DIR/$TAG_FILE"
    
    # Run with full output (no filtering)
    python3 "$BASE_DIR/generate_map.py" \
        -i "$abs_input" \
        -c "$countrycode" \
        -s "$state" \
        -t "$BASE_DIR/$TAG_FILE"
    
    # Find and move generated maps
    log "→ Looking for generated maps..."
    local moved_count=0
    for mapfile in *.map; do
        if [ -f "$mapfile" ] && [ "$mapfile" != "*.map" ]; then
            debug "Found map file: $mapfile"
            debug "File size: $(du -h "$mapfile" | cut -f1)"
            
            # Verify filename starts with country code
            if [[ "$mapfile" == ${countrycode}${state}* ]]; then
                log "✓ Created: $mapfile (correct iGPSport format!)"
                mv "$mapfile" "${output_dir}/"
                moved_count=$((moved_count + 1))
            else
                warn "Map file has wrong naming format: $mapfile"
                warn "Expected to start with: ${countrycode}${state}"
                mv "$mapfile" "${output_dir}/${mapfile}.wrong-format"
            fi
        fi
    done
    
    if [ $moved_count -eq 0 ]; then
        warn "No map file created for $country/$region"
        debug "Files in work directory:"
        ls -lah
    else
        log "✓ Successfully saved $moved_count map(s) to: ${output_dir}/"
    fi
    
    # Cleanup
    cd "$BASE_DIR"
    rm -rf "$work_dir"
    
    info "═══════════════════════════════════════════════════════════"
}

export -f build_single log info warn error debug
export TYPE OUTPUT_BASE BASE_DIR

# Main

setup_check

log "Starting batch build"
info "Base directory: $BASE_DIR"
info "Type: $TYPE"
info "Parallel jobs: $PARALLEL_JOBS"
info "Output: $BASE_DIR/$OUTPUT_BASE/$TYPE/"

# Collect all build tasks

TASKS_DIR=$(mktemp -d)
ALL_TASKS=$(mktemp)

for country in $COUNTRY_LIST; do
    parse_workflow "$country" >> "$ALL_TASKS"
done

# Remove duplicates

log "Deduplicating tasks..."
sort -u "$ALL_TASKS" > "${ALL_TASKS}.unique"
mv "${ALL_TASKS}.unique" "$ALL_TASKS"

TASK_NUM=0
while IFS=$'\t' read -r c r u s; do
    [ -z "$c" ] && continue
    TASK_NUM=$((TASK_NUM + 1))
    printf "%s\t%s\t%s\t%s\n" "$c" "$r" "$u" "$s" > "$TASKS_DIR/task_${TASK_NUM}.txt"
done < "$ALL_TASKS"

rm "$ALL_TASKS"

TOTAL_TASKS=$(ls "$TASKS_DIR"/task_*.txt 2>/dev/null | wc -l)

if [ "$TOTAL_TASKS" -eq 0 ]; then
    error "No tasks found!"
fi

log "Found $TOTAL_TASKS unique maps to build across $(echo "$COUNTRY_LIST" | wc -w) countries"

# Execute builds

if command -v parallel >/dev/null 2>&1 && [ "$PARALLEL_JOBS" -gt 1 ]; then
    log "Using GNU parallel with $PARALLEL_JOBS jobs"
    ls "$TASKS_DIR"/task_*.txt | parallel -j "$PARALLEL_JOBS" --bar build_single {}
else
    if [ "$PARALLEL_JOBS" -gt 1 ]; then
        warn "GNU parallel not found, using sequential execution"
        info "Install for faster builds: sudo apt install parallel"
    fi
    
    for task_file in "$TASKS_DIR"/task_*.txt; do
        build_single "$task_file"
    done
fi

# Cleanup

rm -rf "$TASKS_DIR"

# Summary

log "════════════════════════════════════════"
log "Build complete!"
log "Output directory: $BASE_DIR/$OUTPUT_BASE/$TYPE/"
MAP_COUNT=$(find "$BASE_DIR/$OUTPUT_BASE/$TYPE" -name "*.map" 2>/dev/null | wc -l)
log "Maps created: $MAP_COUNT"

if [ "$MAP_COUNT" -gt 0 ]; then
    log "Total size: $(du -sh "$BASE_DIR/$OUTPUT_BASE/$TYPE" 2>/dev/null | cut -f1)"
    log "════════════════════════════════════════"
    
    info "Created maps:"
    find "$BASE_DIR/$OUTPUT_BASE/$TYPE" -name "*.map" 2>/dev/null -exec basename {} \; | sort | sed 's/^/  /'
fi

exit 0
