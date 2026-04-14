[![Maps Build](https://github.com/MoritzThome/BSC300-Maps/actions/workflows/build-maps.yml/badge.svg)](https://github.com/MoritzThome/BSC300-Maps/actions/workflows/build-maps.yml)

# IGPSPORT BSC300 / BSC300T Map Creator

This is a clone from https://github.com/adrianf0/bsc300_maps and https://github.com/manujedi/BSC300-Maps with an added universal script and many performance improvements so github builds maps but you can also built it yourself in an easy container, easy extensible.

## Maps Types
* `streets-only`: smallest one
* `steets-names`: same as `streets-only` but with names
* `water`: same as `streets-names` but including lakes, rivers, ...
* `green`: same as `water`, but including forests, grass, ... (biggest map, but i like it)

They are defined in `map-types.conf`.

## Download monthly rebuilt maps
1. from [Github Releases](https://github.com/MoritzThome/BSC300-Maps/releases)
2. Download desired map archives (githubs max file size is 2GB, therefore Map Types are split into multiple archives containing different countries)
3. Extract ZIPs archive on your machine
4. Copy existing maps from your iGPSport device to backup (yes, copy speed is only 450kb/s)
5. Copy \`.map\` files to device via USB
6. Restart device to load new maps


## Build yourself only needed maps
This can take a long while depending on countries and map-types. Minimum free ram required: 8gb, more for git countries like norway and on parallel jobs.

`docker run --rm -it -v $(pwd):/work/output ghcr.io/moritzthome/bsc300-maps:master`

optionally, specify arguments for building only some countries and map-types. To build france and netherlands with water in 4 parallel Jobs, run:

`docker run --rm -it -v $(pwd):/work/output ghcr.io/moritzthome/bsc300-maps:master -j 4 -c france,netherlands -t water`

Files will be placed in your current Working directory.

You can also run the script `./easybuild.sh` without docker, but dependencies are needed then.

## Detailed Information

It is based on the description by CYMES [source](https://www.pepper.pl/dyskusji/igpsport-bsc300-informacje-o-mapach-1046955?page=2#comments) but the maps are heavily filtered and modified.

The idea is that we have up to date maps and not rely on the igpsport maps from 2023 and regions that are not officially available. Also, the maps are shit.
If someone is interested, [this are the maps](https://manujedi.github.io/BSC300-Maps/BoundingBoxes_FactoryMaps.html) that came preinstalled on my device. Only open the link on a performant browser (not on mobile).

### Improvments:
  Original iGPSPORT Map|New Map           | OSM
| -------------------- | -------------------- | -------------------- |
![](docs/igpsport_map.jpg)   | ![](docs/mymap.jpg)  | ![](docs/osm.png)
cycleway is included in the maps but not rendered as it is too crowded | contains cycleway | |
random stuff included |inaccessible streets removed |  |
from 2023 | up to date |  |

#### in cruiser:
Original iGPSPORT Map | New Map 
| -------------------- | -------------------- | 
![](docs/cruiser_igpsport_map.png)  |  ![](docs/cruiser_my_map.png) |
includes a lot of random stuff making the file bigger (e.g. footway/sidewalks) | also not perfect, missing one road (highway=service and no bicycle=* tag, should be fixed in osm)
highly simplified | way better resolution
cycleway is useless as it is not rendered on the device (too crowded) | everything rendered

### Map format
- Format is mapsforge
- Renderer on the BSC300:
  - anything you want green use landuse=grass (--modify-tags="landuse=something to =grass" or leisure=garden to landuse=grass)
  - it can only render some amount of roads/ways. Even the original maps are not rendered fully. Random roads are missing.
    - thats the reason why I [filter extensively](template_state_country.yml) which ways to add.
  - Code on this repo does not use simplification-factor for zoom levels 13 and 14. Original uses some factor > 0.5 making the maps even smaller but less accurate 

  - Supported tags (colors from night mode):
    - thick yellow line
      - primary
      - primary_link
      - trunk
      - trunk_link
    - less thick yellow
      - secondary
      - secondary_link
      - tertiary
      - tertiary_link
    - thin white line
      - cycleway
      - living_street
      - pedestrian
      - track
    - medium thick gray
      - residential
      - road
      - unclassified
      - service (destroys other stuff like living street?)

  - Not rendered tags examples (some are included in igpsport maps...):
    - path
    - footway
    - motorway
    - motorway_link
    - bridleway
    - construction

### Output Filename Format

The filename should include:

* **Country code**
* **4-digit region code** (see explanation below)
* **Date** in the format `YYMMDD`
* **Coordinates** in base36
**Example:** `-o PL00002507043EJ20506N068` (for Poland)

### Region Code Explanation

The **4-digit map version number** in the filename actually represents a region within the given country.
- `0000` means the map covers the *whole country*.
- Other 4-digit codes correspond to specific regions (e.g., voivodeships in Poland).
- see [fernandoglatz/igpsport-map-updater](https://github.com/fernandoglatz/igpsport-map-updater?tab=readme-ov-file#igpsport-filename-structure) for more information
