#!/bin/bash
# Run the shell in validate-tag and tag-version against real git histories,
# with npm and gh stubbed. Usage: test/run.sh
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
# Print the `run: |` block of an action's only shell step, unindented.
script() { awk '/^      run: \|/ { on=1; next } on && /^      [^ ]/ { on=0 } on { sub(/^        /, ""); print }' "$root/$1/action.yml"; }
VALIDATE=$(script validate-tag)
TAG=$(script tag-version)
failures=0
check() { # name got want detail
  if [[ "$2" == "$3" ]]; then printf 'ok    %s\n' "$1"; else printf 'FAIL  %s (got %s, want %s) %s\n' "$1" "$2" "$3" "$4"; failures=$((failures + 1)); fi
}
git_repo() { git init -q -b main "$1"; git -C "$1" config user.email t@t; git -C "$1" config user.name t; }
setv() { # dir version note [pkgdir]
  mkdir -p "$1/${4:-.}"; echo "{\"name\":\"@x/pkg\",\"version\":\"$2\",\"x\":\"$3\"}" > "$1/${4:-.}/package.json"
  git -C "$1" add -A; git -C "$1" commit -qm "$2 $3"; git -C "$1" rev-parse HEAD
}

# validate-tag: a bare origin with main and a feature branch.
tmp=$(mktemp -d)
git init -q --bare -b main "$tmp/origin.git"; git_repo "$tmp/w"; git -C "$tmp/w" remote add origin "$tmp/origin.git"
A=$(setv "$tmp/w" 0.3.1 a); B=$(setv "$tmp/w" 0.3.2 bump)
echo f > "$tmp/w/f"; git -C "$tmp/w" add f; git -C "$tmp/w" commit -qm fix; C=$(git -C "$tmp/w" rev-parse HEAD)
git -C "$tmp/w" push -q origin main
git -C "$tmp/w" checkout -qb feat
P=$(setv "$tmp/w" 0.4.0-alpha.0 pre); S=$(setv "$tmp/w" 0.4.0 stable)
BAD=$(setv "$tmp/w" 0.5.0-Bad.0 bad); BM=$(setv "$tmp/w" 1.2.3+build-alpha bm)
git -C "$tmp/w" push -q origin feat
validate() { # name sha ref-name ref-type want
  local d out; d=$(mktemp -d); git clone -q "$tmp/origin.git" "$d/c" 2>/dev/null; git -C "$d/c" checkout -q "$2"; out=$(mktemp)
  ( cd "$d/c" && GITHUB_SHA=$2 GITHUB_REF=refs/x/$3 GITHUB_REF_NAME=$3 GITHUB_REF_TYPE=$4 GITHUB_OUTPUT=$out MAIN_BRANCH=main \
    bash -eo pipefail -c "$VALIDATE" >/dev/null 2>"$d/err" ) && got=pass || got=fail
  check "validate-tag: $1" "$got" "$5" "$(head -c 80 "$d/err")"
}
validate "stable at the bump commit"     "$B" v0.3.2 tag pass
validate "stable at a later commit"      "$C" v0.3.2 tag pass
validate "older stable on main"          "$A" v0.3.1 tag pass
validate "tag doesn't match version"     "$C" v0.3.3 tag fail
validate "branch named like the tag"     "$C" v0.3.2 branch fail
validate "stable off main"               "$S" v0.4.0 tag fail
validate "prerelease off main"           "$P" v0.4.0-alpha.0 tag pass
validate "invalid prerelease channel"    "$BAD" v0.5.0-Bad.0 tag fail
validate "build metadata"                "$BM" v1.2.3+build-alpha tag fail

# tag-version: stub npm and gh.
stub=$(mktemp -d)
cat > "$stub/npm" <<'S'
#!/bin/bash
case "$NPM_MODE" in published) echo "${2##*@}";; missing) echo "npm error code E404" >&2; exit 1;; down) echo "npm error code ECONNRESET" >&2; exit 1;; esac
S
cat > "$stub/gh" <<'S'
#!/bin/bash
echo "gh $*" >> "$LOG"
# GH_EXISTING simulates a tag another run already created: creating it fails, reading it returns that SHA.
if [[ -n "${GH_EXISTING:-}" && "$*" == *"git/refs -f ref="* ]]; then echo "Reference already exists" >&2; exit 1; fi
if [[ -n "${GH_EXISTING:-}" && "$*" == *"git/ref/tags/"* ]]; then echo "$GH_EXISTING"; fi
S
chmod +x "$stub"/*
tagver() { # name repo pkgdir npm-mode want-exit want-sha [existing-sha]
  local log; log=$(mktemp)
  ( cd "$2/$3" && PATH="$stub:$PATH" LOG=$log NPM_MODE=$4 GH_EXISTING=${7:-} GITHUB_REPOSITORY=o/r GITHUB_STEP_SUMMARY=/dev/null RELEASE_WORKFLOW=release.yml \
    bash -eo pipefail -c "$TAG" >/dev/null 2>&1 ); local rc=$?
  local sha; sha=$(sed -n 's/.* -f sha=\([0-9a-f]*\).*/\1/p' "$log")
  local ran; ran=$(grep -c 'workflow run' "$log" || true)
  if [[ -n "${7:-}" ]]; then check "tag-version: $1 (no release started)" "$ran" "0" ""; fi
  check "tag-version: $1" "$rc:${sha:-none}" "$5:${6:-none}" "$(tr '\n' ';' < "$log")"
}
r=$(mktemp -d); git_repo "$r"
setv "$r" 0.3.1 a >/dev/null; git -C "$r" tag v0.3.1
setv "$r" 0.3.1 dep >/dev/null; BUMP=$(setv "$r" 0.3.2 bump); setv "$r" 0.3.2 later-dep >/dev/null
tagver "untagged and not on npm"   "$r" . missing 0 "$BUMP"
tagver "already on npm"            "$r" . published 0
tagver "npm unreachable"           "$r" . down 1
tagver "raced: same commit"         "$r" . missing 0 "$BUMP" "$BUMP"
tagver "raced: other commit"        "$r" . missing 1 "$BUMP" "0000000000000000000000000000000000000000"
git -C "$r" tag v0.3.2 "$BUMP"
tagver "tag exists"                "$r" . missing 0
m=$(mktemp -d); git_repo "$m"
setv "$m" 1.0.0 a >/dev/null; git -C "$m" tag v1.0.0; git -C "$m" checkout -qb pr; setv "$m" 1.1.0 vbump >/dev/null
git -C "$m" checkout -q main; echo z > "$m/z"; git -C "$m" add z; git -C "$m" commit -qm other
git -C "$m" merge -q --no-ff pr -m "Merge version PR"; MERGE=$(git -C "$m" rev-parse HEAD)
tagver "merged version PR"         "$m" . missing 0 "$MERGE"
s=$(mktemp -d); git_repo "$s"
setv "$s" 0.0.47 a pkg >/dev/null; git -C "$s" tag v0.0.47; SUB=$(setv "$s" 0.0.48 bump pkg)
setv "$s" 9.9.9 other other >/dev/null
tagver "package in a subdirectory" "$s" pkg missing 0 "$SUB"

# version-pr's lockfile script: changeset version, then a lockfile-only install.
v=$(mktemp -d); vlog=$(mktemp)
printf '#!/bin/bash\necho "npx $*" >> "%s"\n' "$vlog" > "$v/npx"
printf '#!/bin/bash\necho "npm $*" >> "%s"\n' "$vlog" > "$v/npm"; chmod +x "$v"/*
PATH="$v:$PATH" bash "$root/version-pr/version.sh"
check "version-pr: lockfile sync order" "$(tr '\n' ';' < "$vlog")" "npx changeset version;npm install --package-lock-only --ignore-scripts;" ""

# version-pr: read the plan from a package directory on a detached checkout.
git_repo "$v/repo"
TITLE_HEAD=$(setv "$v/repo" 1.2.0 initial pkg)
git -C "$v/repo" checkout -q --detach "$TITLE_HEAD"
git -C "$v/repo" branch -D main >/dev/null
mkdir -p "$v/repo/pkg/node_modules/@changesets/cli"
cat > "$v/repo/pkg/node_modules/@changesets/cli/bin.js" <<'JS'
const assert = require("node:assert/strict");
const { execFileSync } = require("node:child_process");
const fs = require("node:fs");
assert.deepEqual(process.argv.slice(2, 4), ["status", "--output"]);
assert.equal(
  execFileSync("git", ["rev-parse", "refs/heads/main"], { encoding: "utf8" }).trim(),
  process.env.TITLE_HEAD,
);
fs.writeFileSync(process.argv[4], process.env.PLAN);
JS
release_title() { # name releases expected-title
  local out
  out=$(mktemp)
  if (cd "$v/repo/pkg" && BASE_BRANCH=main TITLE_HEAD="$TITLE_HEAD" PLAN="{\"releases\":$2}" \
    GITHUB_OUTPUT="$out" node "$root/version-pr/release-title.cjs"); then
    check "version-pr: $1" "$(cat "$out")" "$3" ""
  else
    check "version-pr: $1" "failed" "$3" ""
  fi
}
release_title "primary package in a workspace" \
  '[{"name":"other","newVersion":"4.2.1"},{"name":"@x/pkg","newVersion":"1.3.0"}]' \
  "title=Release v1.3.0"
release_title "sole changed package, including prerelease suffix" \
  '[{"name":"@x/pkg","oldVersion":"1.2.0","newVersion":"1.2.0"},{"name":"other","newVersion":"4.2.1-alpha.0"}]' \
  "title=Release v4.2.1-alpha.0"
release_title "several packages with no primary release" \
  '[{"name":"first","newVersion":"1.3.0"},{"name":"second","newVersion":"4.2.1"}]' ""
check "version-pr: temporary base branch removed" \
  "$(git -C "$v/repo" for-each-ref --format='%(refname)' refs/heads/main)" "" ""

[[ $failures == 0 ]] && echo "all passed" || { echo "$failures failed"; exit 1; }
