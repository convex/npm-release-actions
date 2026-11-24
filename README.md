# Release actions

Composite GitHub Actions for staging Convex npm packages from CI with npm
trusted publishing. A pushed `v<version>` tag selects the exact commit to
release; a build job without npm credentials tests and packs it; a separate job
stages the tarball on npm for a maintainer to approve with 2FA.

| Action                | Use in                                               | Does                                                                                                                   |
| --------------------- | ---------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| `validate-tag`        | build job, before installing                         | Checks the run is on `v<version>` matching `package.json`, stable versions are on `main`, and picks the npm dist-tag.  |
| `check-release-notes` | build job, after installing                          | Fails on pending Changesets or a missing CHANGELOG entry for the version.                                              |
| `pack`                | build job, after tests                               | Packs without scripts, records the SHA-256, uploads the tarball.                                                       |
| `stage`               | stage job with `id-token: write`, no checkout        | Checks the tarball's SHA-256 and runs `npm stage publish`.                                                             |
| `version-pr`          | push to `main`, `contents` and `pull-requests` write | Opens or updates the Changesets version PR, also updating `package-lock.json`'s version unless `sync-lockfile: false`. |
| `tag-version`         | push to `main`, `contents` and `actions` write       | Tags the commit that set an untagged, unpublished version and starts the release workflow on the tag.                  |

Each action takes a `working-directory` input where it reads `package.json`.

`version-pr` titles the PR and its commit `Release v<version>` using the
Changesets release plan. It uses the package in `working-directory` when that
package is being released, or the sole planned release when there is just one.
Otherwise, the defaults are `Prepare next release` and `Version packages`.
The `pr-title` and `commit-message` inputs can override either default.
See [action-cache](https://github.com/convex/action-cache/tree/main/.github/workflows)
for a complete `release.yml` and `version.yml`.

## Concurrency

Group Release runs per tag and the version workflow per commit, without
`queue`:

```yaml
# release.yml
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: false
# version.yml
concurrency:
  group: ${{ github.workflow }}-${{ github.sha }}
  cancel-in-progress: false
```

Runs for different tags or commits never cancel each other. A newer run for
the same tag or commit (a duplicate dispatch or a moved tag) replaces an older
pending one, which is equivalent or the one you want. `version-pr` skips runs
whose commit is no longer the tip of the base branch, and `tag-version` accepts a
tag that another run just created on the same commit.

Pin these actions by commit SHA. npm trusted publishing checks the calling
workflow's filename, so registering the caller's `release.yml` is enough.

Run the tests with `test/run.sh`.
