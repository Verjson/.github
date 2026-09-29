#!/usr/bin/env node

const { spawnSync } = require("node:child_process");
const path = require("node:path");

const engine = path.resolve(__dirname, "../scripts/changelog.py");
const result = spawnSync(
  "python3",
  [engine, "render-next", "--repo-root", process.cwd(), ...process.argv.slice(2)],
  { stdio: "inherit" },
);

if (result.error) {
  console.error(`render-next: unable to start python3: ${result.error.message}`);
  process.exit(1);
}
process.exit(result.status ?? 1);
