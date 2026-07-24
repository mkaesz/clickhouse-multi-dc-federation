#!/usr/bin/env bash
# Usage: wait-for-pods.sh <namespace> <label-selector> <expected-count>
# Waits until all pods matching the selector are Running and Ready.

set -euo pipefail

NS="$1"
SELECTOR="$2"
EXPECTED="${3:-1}"
TIMEOUT=300
INTERVAL=5
ELAPSED=0

echo "  Waiting for $EXPECTED pod(s) in ns=$NS selector=$SELECTOR ..."

while true; do
    READY=$(kubectl get pods -n "$NS" -l "$SELECTOR" \
        --field-selector=status.phase=Running \
        -o jsonpath='{range .items[*]}{range .status.containerStatuses[*]}{.ready}{"\n"}{end}{end}' 2>/dev/null \
        | grep -c "^true$" || true)

    if [ "$READY" -ge "$EXPECTED" ]; then
        echo "  Ready ($READY/$EXPECTED)"
        exit 0
    fi

    if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
        echo "  ERROR: Timed out after ${TIMEOUT}s waiting for pods"
        kubectl get pods -n "$NS" -l "$SELECTOR" 2>/dev/null || true
        exit 1
    fi

    echo "  ... $READY/$EXPECTED ready (${ELAPSED}s elapsed)"
    sleep "$INTERVAL"
    ELAPSED=$((ELAPSED + INTERVAL))
done
