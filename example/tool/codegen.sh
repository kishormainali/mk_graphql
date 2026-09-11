#!/usr/bin/env bash
# Regenerates GraphQL code and cleans up the result.
# Usage: ./tool/codegen.sh
set -euo pipefail

dart run build_runner build --delete-conflicting-outputs
dart fix --apply
