const { execFileSync, spawnSync } = require("node:child_process");
const fs = require("node:fs");
const { createRequire } = require("node:module");
const { tmpdir } = require("node:os");
const path = require("node:path");

const cwd = process.cwd();
const projectRequire = createRequire(path.join(cwd, "package.json"));
const cli = projectRequire.resolve("@changesets/cli/bin.js");
const cliRequire = createRequire(cli);
const manifest = projectRequire("./package.json");

function resolveRevision(revision) {
  const result = spawnSync(
    "git",
    ["rev-parse", "--verify", "--quiet", "--end-of-options", revision],
    { encoding: "utf8" },
  );
  if (result.error) throw result.error;
  return result.status === 0 ? result.stdout.trim() : undefined;
}

function prepareBase(configuredBase) {
  const remote = /^(?:refs\/remotes\/)?origin\/(.+)$/.exec(configuredBase);
  const branch = remote ? remote[1] : configuredBase.replace(/^refs\/heads\//, "");
  const remoteRef = `refs/remotes/origin/${branch}`;
  const ref = remote ? remoteRef : `refs/heads/${branch}`;
  const current = resolveRevision(`${configuredBase}^{commit}`);
  const isTarget = branch === process.env.BASE_BRANCH;
  if (!isTarget && current) return;

  // The workflow verified GITHUB_SHA against the live target branch.
  const source = isTarget ? process.env.GITHUB_SHA : remoteRef;
  const commit = source && resolveRevision(`${source}^{commit}`);
  if (!commit) {
    throw new Error(`Changesets base ref ${JSON.stringify(configuredBase)} is unavailable`);
  }
  if (current === commit) return;

  const previous = resolveRevision(ref) ?? "";
  if (previous && spawnSync("git", ["symbolic-ref", "--quiet", ref]).status === 0) {
    throw new Error(`Cannot temporarily replace the symbolic base ref ${JSON.stringify(ref)}`);
  }
  execFileSync("git", ["update-ref", "--no-deref", ref, commit, previous]);
  return { ref, commit, previous };
}

async function readPlan() {
  const { version } = projectRequire("@changesets/cli/package.json");
  // Changesets 2 reads config from its working directory. Changesets 3
  // discovers the workspace root before reading config.
  const configDir = version.startsWith("2.")
    ? cwd
    : (await cliRequire("@manypkg/get-packages").getPackages(cwd)).rootDir;
  const config = JSON.parse(fs.readFileSync(path.join(configDir, ".changeset/config.json"), "utf8"));
  const configuredBase = config.baseBranch ?? cliRequire("@changesets/config").defaultConfig.baseBranch;
  const temporaryDir = fs.mkdtempSync(path.join(tmpdir(), "release-title-"));
  const planFile = path.join(temporaryDir, "plan.json");
  let temporaryBase;
  try {
    temporaryBase = prepareBase(configuredBase);
    if (temporaryBase && resolveRevision(`${configuredBase}^{commit}`) !== temporaryBase.commit) {
      throw new Error(`Changesets base ref ${JSON.stringify(configuredBase)} is ambiguous`);
    }
    // Changesets 2 joins this argument with cwd, while Changesets 3 resolves it.
    execFileSync(process.execPath, [cli, "status", "--output", path.relative(cwd, planFile)], {
      stdio: "inherit",
    });
    return JSON.parse(fs.readFileSync(planFile, "utf8"));
  } finally {
    try {
      if (temporaryBase) {
        const { ref, commit, previous } = temporaryBase;
        const restore = previous ? [ref, previous, commit] : ["-d", ref, commit];
        execFileSync("git", ["update-ref", "--no-deref", ...restore]);
      }
    } finally {
      fs.rmSync(temporaryDir, { recursive: true, force: true });
    }
  }
}

async function writeTitle() {
  const plan = await readPlan();
  const releases = plan.releases.filter(
    (release) => release.oldVersion !== release.newVersion,
  );
  const primary = releases.find((release) => release.name === manifest.name);
  const release = primary ?? (releases.length === 1 ? releases[0] : undefined);

  if (!release) return;
  const version = release.newVersion;
  if (typeof version !== "string" || /[\x00-\x1f\x7f]/.test(version)) {
    throw new Error("Invalid release version for the workflow output");
  }
  fs.appendFileSync(process.env.GITHUB_OUTPUT, `title=Release v${version}\n`);
}

writeTitle().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
