#!/bin/sh
# Build libctcodec.dylib (arm64). Run from anywhere; outputs next to this script.
set -e
cd "$(dirname "$0")"
clang -arch arm64 -O2 -Wall -Wextra -dynamiclib -o libctcodec.dylib ctcodec.c
echo "built: $(pwd)/libctcodec.dylib"
