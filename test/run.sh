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
printf '#!/bin/bash\necho "gh $*" >> "$LOG"\n' > "$stub/gh"; chmod +x "$stub"/*
tagver() { # name repo pkgdir npm-mode want-exit want-sha
  local log; log=$(mktemp)
  ( cd "$2/$3" && PATH="$stub:$PATH" LOG=$log NPM_MODE=$4 GITHUB_REPOSITORY=o/r GITHUB_STEP_SUMMARY=/dev/null RELEASE_WORKFLOW=release.yml \
    bash -eo pipefail -c "$TAG" >/dev/null 2>&1 ); local rc=$?
  local sha; sha=$(sed -n 's/.* -f sha=\([0-9a-f]*\).*/\1/p' "$log")
  check "tag-version: $1" "$rc:${sha:-none}" "$5:${6:-none}" "$(tr '\n' ';' < "$log")"
}
r=$(mktemp -d); git_repo "$r"
setv "$r" 0.3.1 a >/dev/null; git -C "$r" tag v0.3.1
setv "$r" 0.3.1 dep >/dev/null; BUMP=$(setv "$r" 0.3.2 bump); setv "$r" 0.3.2 later-dep >/dev/null
tagver "untagged and not on npm"   "$r" . missing 0 "$BUMP"
tagver "already on npm"            "$r" . published 0
tagver "npm unreachable"           "$r" . down 1
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

[[ $failures == 0 ]] && echo "all passed" || { echo "$failures failed"; exit 1; }
