#!/bin/bash
set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
VERBOSE=false

log() { echo -e "${GREEN}[$(date +'%H:%M:%S')]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1" >&2; }

format_duration() {
    local s=$1 h=$((s/3600)) m=$(((s%3600)/60)) s=$((s%60))
    [ $h -gt 0 ] && printf "%dh %dm %ds" $h $m $s || [ $m -gt 0 ] && printf "%dm %ds" $m $s || printf "%ds" $s
}

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$BASE_DIR/map-types.conf" || error "Failed to load map-types.conf"

TYPE="water"; PARALLEL_JOBS=2; COUNTRIES=""; OUTPUT_BASE="output"; CONFIG_FILE="$BASE_DIR/countries.yml"

usage() {
    echo "Usage: ./easybuild.sh [-a] [-t TYPE] [-j JOBS] [-c COUNTRIES] [-o OUTPUT] [-v] [-h]"
    echo "Types:"
    for t in $AVAILABLE_MAP_TYPES; do
        local var="MAP_TYPE_DESC_$(echo $t | tr '[:lower:]-' '[:upper:]_')"
        printf "  %-15s : %s\n" "$t" "${!var}"
    done
    exit 0
}

while getopts "at:j:c:o:vh" opt; do
    case $opt in
        a) COUNTRIES="all" ;;
        t) TYPE="$OPTARG" ;;
        j) PARALLEL_JOBS="$OPTARG" ;;
        c) COUNTRIES="$OPTARG" ;;
        o) OUTPUT_BASE="$OPTARG" ;;
        v) VERBOSE=true ;;
        h) usage ;;
        *) usage ;;
    esac
done

# Validate & get config

[[ " $AVAILABLE_MAP_TYPES " =~ " $TYPE " ]] || error "Invalid type: $TYPE"
TYPE_VAR=$(echo "$TYPE" | tr '[:lower:]-' '[:upper:]_')
TYPE_DESC="MAP_TYPE_DESC_${TYPE_VAR}"; TYPE_DESC="${!TYPE_DESC}"
TAG_FILE="TAG_FILE_${TYPE_VAR}"; TAG_FILE="${!TAG_FILE}"
FILTER_ARGS="FILTER_ARGS_${TYPE_VAR}"; FILTER_ARGS="${!FILTER_ARGS}"
TAG_MODS="TAG_MODIFICATIONS_${TYPE_VAR}"; TAG_MODS="${!TAG_MODS}"

[ ! -f "$CONFIG_FILE" ] && error "Config not found: $CONFIG_FILE"

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

export -f log warn error format_duration
export VERBOSE TYPE OUTPUT_BASE BASE_DIR TAG_FILE FILTER_ARGS TAG_MODS

setup_check() {
    for cmd in wget python3 unzip gcc java; do
        command -v $cmd >/dev/null 2>&1 || error "$cmd not found"
    done
    python3 -c "import yaml, numpy" 2>/dev/null || { pip3 install pyyaml numpy >/dev/null 2>&1; }
    
    if [ ! -f "$BASE_DIR/osmosis/osmconvert" ]; then
        log "Setting up osmosis..."
        cd "$BASE_DIR"
        if [ "$VERBOSE" = true ]; then
            bash setup_env.sh
        else
            bash setup_env.sh >/dev/null 2>&1
        fi
    fi
    
    [ ! -f "$BASE_DIR/osmosis/osmconvert" ] && error "osmosis setup failed"
    mkdir -p "$BASE_DIR/$OUTPUT_BASE"
}

build_single() {
    IFS=$'\t' read -r country region url state code < "$1"
    
    local work="$BASE_DIR/$OUTPUT_BASE/.tmp/${country}-${region}-$$-$RANDOM"
    local out="$BASE_DIR/$OUTPUT_BASE/${TYPE}"
    mkdir -p "$work" "$out" && cd "$work"
    
    log "Building: $country/$region"
    
    # Download
    if [ "$VERBOSE" = true ]; then
        wget --show-progress "$url" -O tmp.pbf 2>&1
    else
        wget -q "$url" -O tmp.pbf 2>&1
    fi
    [ ! -s tmp.pbf ] && { warn "Download failed: $country/$region"; cd "$BASE_DIR" && rm -rf "$work"; return; }
    
    # Convert to O5M
    if [ "$VERBOSE" = true ]; then
        "$BASE_DIR/osmosis/osmconvert" tmp.pbf -o=tmp.o5m
    else
        "$BASE_DIR/osmosis/osmconvert" tmp.pbf -o=tmp.o5m >/dev/null 2>&1
    fi
    rm tmp.pbf
    
    # Filter
    if [ "$VERBOSE" = true ]; then
        eval "$BASE_DIR/osmosis/osmfilter -v tmp.o5m $FILTER_ARGS --out-o5m -o tmp1.o5m"
    else
        eval "$BASE_DIR/osmosis/osmfilter tmp.o5m $FILTER_ARGS --out-o5m -o tmp1.o5m" >/dev/null 2>&1
    fi
    
    # Modify tags
    if [ "$VERBOSE" = true ]; then
        "$BASE_DIR/osmosis/osmfilter" -v tmp1.o5m --modify-tags="$TAG_MODS" --drop-author --drop-version --out-o5m -o tmp2.o5m
    else
        "$BASE_DIR/osmosis/osmfilter" tmp1.o5m --modify-tags="$TAG_MODS" --drop-author --drop-version --out-o5m -o tmp2.o5m >/dev/null 2>&1
    fi
    rm tmp.o5m tmp1.o5m
    
    # Convert to PBF
    if [ "$VERBOSE" = true ]; then
        "$BASE_DIR/osmosis/osmconvert" tmp2.o5m -o=tmp.pbf
    else
        "$BASE_DIR/osmosis/osmconvert" tmp2.o5m -o=tmp.pbf >/dev/null 2>&1
    fi
    rm tmp2.o5m
    
    # Build map
    ln -sf "$BASE_DIR/osmosis" osmosis
    if [ "$VERBOSE" = true ]; then
        python3 "$BASE_DIR/generate_map.py" -i "$(pwd)/tmp.pbf" -c "$code" -s "$state" -t "$BASE_DIR/$TAG_FILE"
    else
        python3 "$BASE_DIR/generate_map.py" -i "$(pwd)/tmp.pbf" -c "$code" -s "$state" -t "$BASE_DIR/$TAG_FILE" >/dev/null 2>&1
    fi
    
    # Move maps
    local count=0
    for m in *.map; do
        [ -f "$m" ] && [ "$m" != "*.map" ] && [[ "$m" == ${code}${state}* ]] && mv "$m" "$out/" && count=$((count+1))
    done
    
    if [ $count -eq 0 ]; then
        warn "No maps: $country/$region"
    else
        log "✓ $country/$region ($count map$([ $count -gt 1 ] && echo 's'))"
    fi
    
    cd "$BASE_DIR" && rm -rf "$work"
}

export -f build_single

# Main

START=$(date +%s)
setup_check

log "Building: $TYPE | Parallel: $PARALLEL_JOBS | Verbose: $VERBOSE"
[ -z "$COUNTRIES" ] && COUNTRIES="all"

TASKS=$(mktemp -d)
parse_countries | while IFS=$'\t' read -r c r u s code; do
    [ -z "$c" ] && continue
    echo -e "$c\t$r\t$u\t$s\t$code" > "$TASKS/$(uuidgen 2>/dev/null || echo $$-$RANDOM).task"
done

TOTAL=$(ls "$TASKS"/*.task 2>/dev/null | wc -l)
[ "$TOTAL" -eq 0 ] && { rm -rf "$TASKS"; error "No tasks found"; }

log "Building $TOTAL map(s)"

if command -v parallel >/dev/null 2>&1 && [ "$PARALLEL_JOBS" -gt 1 ]; then
    if [ "$VERBOSE" = true ]; then
        ls "$TASKS"/*.task | parallel -j "$PARALLEL_JOBS" --bar build_single {}
    else
        ls "$TASKS"/*.task | parallel -j "$PARALLEL_JOBS" build_single {} 2>/dev/null
    fi
else
    for t in "$TASKS"/*.task; do build_single "$t"; done
fi

rm -rf "$TASKS"

# Summary

DURATION=$(($(date +%s) - START))
COUNT=$(find "$BASE_DIR/$OUTPUT_BASE/$TYPE" -name "*.map" 2>/dev/null | wc -l)
SIZE=$(du -sh "$BASE_DIR/$OUTPUT_BASE/$TYPE" 2>/dev/null | cut -f1)

log "═══════════════════════════════════════════════════════"
log "Complete! Time: $(format_duration $DURATION) | Maps: $COUNT | Size: $SIZE"
log "═══════════════════════════════════════════════════════"

exit 0
