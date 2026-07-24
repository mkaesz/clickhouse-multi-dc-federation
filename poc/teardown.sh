#!/usr/bin/env bash
# Tears down the geo-poc kind cluster entirely.
# Run from anywhere: bash poc/teardown.sh

set -euo pipefail

# kind needs to know which runtime was used to create the cluster
if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
    : # docker is default, no env var needed
elif command -v podman &>/dev/null && podman info &>/dev/null 2>&1; then
    export KIND_EXPERIMENTAL_PROVIDER=podman
else
    echo "WARNING: no container runtime detected; attempting kind delete anyway"
fi

echo "Deleting kind cluster 'geo-poc' ..."
kind delete cluster --name geo-poc
echo "Done. Helm releases and all namespaces are gone with the cluster."
