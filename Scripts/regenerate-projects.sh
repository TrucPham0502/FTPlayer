#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
xcodegen generate --spec "$ROOT/SDK/project.yml"
xcodegen generate --spec "$ROOT/Demo/project.yml"
