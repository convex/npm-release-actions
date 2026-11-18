#!/bin/bash
# changeset version, then bring package-lock.json's version fields along.
set -euo pipefail
npx changeset version
npm install --package-lock-only --ignore-scripts
