#!/usr/bin/env bash
# Tears down the geo-poc kind cluster entirely.
# Run from anywhere: bash poc/teardown.sh

set -euo pipefail

echo "Deleting kind cluster 'geo-poc' ..."
kind delete cluster --name geo-poc
echo "Done. Helm releases and all namespaces are gone with the cluster."
