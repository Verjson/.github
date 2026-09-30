#!/usr/bin/env node

const { spawnSync } = require("node:child_process");
const path = require("node:path");

const generator = path.resolve(__dirname, "../scripts/gen-adr-index.sh");
const consumerRoot = process.cwd();
const result = spawnSync("bash", [generator, ...process.argv.slice(2)], {
  cwd: consumerRoot,
  env: { ...process.env, VERJSON_ADR_INDEX_ROOT: consumerRoot },
  stdio: "inherit",
});

if (result.error) {
  console.error(`gen-adr-index: unable to start bash: ${result.error.message}`);
  process.exit(1);
}
process.exit(result.status === 0 ? 0 : result.status === 2 ? 2 : 1);
