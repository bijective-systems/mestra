#!/bin/sh
# Compile the C++ builder against a configured cpp/build tree.
#   sh build.sh REPO_ROOT HDF5_ROOT OUT_BINARY
set -e
repo=$1
hdf5=$2
out=$3
c++ -std=c++17 -O1 -Wall \
    -I"$repo/cpp/include" -I"$hdf5/include" \
    "$(dirname "$0")/build_all.cpp" \
    "$repo/cpp/build/libmestra.a" \
    -L"$hdf5/lib" -lhdf5 -lhdf5_hl \
    -Wl,-rpath,"$hdf5/lib" \
    -o "$out"
