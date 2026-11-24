#!/bin/bash
set -euo pipefail

plan=$(mktemp)
trap 'rm -f "$plan"' EXIT
npx --no-install changeset status --output "$plan"

node - "$plan" <<'JS' >> "$GITHUB_OUTPUT"
const fs = require("node:fs");
const manifest = JSON.parse(fs.readFileSync("package.json", "utf8"));
const plan = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const releases = plan.releases.filter(
  (release) => release.oldVersion !== release.newVersion,
);
const primaryRelease = releases.find((release) => release.name === manifest.name);
const release = primaryRelease ?? (releases.length === 1 ? releases[0] : undefined);

if (release) {
  console.log(`title=Release v${release.newVersion}`);
}
JS
