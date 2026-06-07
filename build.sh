#!/bin/bash
# Erzeugt house_data.scad aus CSV und rendert STL direkt per OpenSCAD CLI.
# Aufruf: ./build.sh [datei.csv] [ausgabe.stl]
set -e
cd "$(dirname "$0")"
CSV="${1:-sample.csv}"
STL="${2:-house_mask.stl}"
python3 parse_house.py "$CSV" > house_data.scad
echo "house_data.scad erzeugt."
openscad -o "$STL" house_mask.scad
echo "STL gespeichert: $STL"
