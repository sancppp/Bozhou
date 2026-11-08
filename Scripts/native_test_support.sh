#!/bin/bash
# Source after building Bozhou. Link exactly the current dependency objects,
# including registered plugin modules, never stale *.o files from moved sources.
BIN_PATH="$(swift build --show-bin-path)"
SOURCES=()
for FILE in Sources/Bozhou/*.swift; do
    [[ "$FILE" == "Sources/Bozhou/BozhouApp.swift" ]] || SOURCES+=("$FILE")
done
NATIVE_OBJECTS=()
while IFS= read -r FILE; do
    FILE="${FILE#\"}"
    FILE="${FILE%\"}"
    case "$FILE" in
        */Bozhou.build/*) ;;
        *) NATIVE_OBJECTS+=("$FILE") ;;
    esac
done < "$BIN_PATH/Bozhou.product/Objects.LinkFileList"
