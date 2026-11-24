const { execFileSync, spawnSync } = require("node:child_process");
const fs = require("node:fs");
const { createRequire } = require("node:module");
const { tmpdir } = require("node:os");
const path = require("node:path");

const projectRequire = createRequire(path.resolve("package.json"));
const cli = projectRequire.resolve("@changesets/cli/bin.js");
const manifest = projectRequire("./package.json");
const baseRef = `refs/heads/${process.env.BASE_BRANCH}`;
const head = execFileSync("git", ["rev-parse", "HEAD"], { encoding: "utf8" }).trim();
const baseExists = spawnSync("git", ["show-ref", "--verify", "--quiet", baseRef]);
if (baseExists.status !== 0 && baseExists.status !== 1) {
  throw new Error("Could not check for the local base branch");
}

const temporaryDir = fs.mkdtempSync(path.join(tmpdir(), "release-title-"));
const planFile = path.join(temporaryDir, "plan.json");
let createdRef = false;
let plan;
try {
  if (baseExists.status === 1) {
    // The freshness check already verified HEAD is the current base commit.
    // Changesets status needs the local branch name even on detached checkouts.
    execFileSync("git", ["update-ref", baseRef, head, ""]);
    createdRef = true;
  }
  execFileSync(process.execPath, [cli, "status", "--output", planFile], {
    stdio: "inherit",
  });
  plan = JSON.parse(fs.readFileSync(planFile, "utf8"));
} finally {
  fs.rmSync(temporaryDir, { recursive: true, force: true });
  if (createdRef) {
    execFileSync("git", ["update-ref", "-d", baseRef, head]);
  }
}

const releases = plan.releases.filter(
  (release) => release.oldVersion !== release.newVersion,
);
const primary = releases.find((release) => release.name === manifest.name);
const release = primary ?? (releases.length === 1 ? releases[0] : undefined);

if (release) {
  const version = release.newVersion;
  if (typeof version !== "string" || /[\x00-\x1f\x7f]/.test(version)) {
    throw new Error("Invalid release version for the workflow output");
  }
  fs.appendFileSync(process.env.GITHUB_OUTPUT, `title=Release v${version}\n`);
}
