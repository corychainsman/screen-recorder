#!/usr/bin/env bash
set -euo pipefail

cd "$(cd "$(dirname "$0")/.." && pwd)"

echo "=== Screen Recorder Audio Test ==="
echo ""

echo "[1/2] Building TestRecorderApp..."
swift build --product TestRecorderApp 2>&1
echo ""

echo "[2/2] Running audio capture test (7s)..."
echo ""
.build/debug/TestRecorderApp
