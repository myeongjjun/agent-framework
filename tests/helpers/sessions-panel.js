// Evaluate the Sessions panel template's `entries` with stubbed cmux sidebar globals.
// usage: node sessions-panel.js <template> <plan-json> <workspaces-json> <epoch> [teams-json]
// prints one JSON line per entry, then `HEADER <header text>`.
const fs = require("fs");
const [tpl, plan, workspaces, epoch, teams] = process.argv.slice(2);
const src = fs.readFileSync(tpl, "utf8")
  .replace(/^const PLAN = .*$/m, "const PLAN = " + plan + ";")
  .replace(/^const TEAMS = .*$/m, "const TEAMS = " + (teams || "[]") + ";")
  .replace(/^sidebar\(/m, "return [entries, headerText];\n(");
const ctx = {
  signal: (v) => [() => v, () => {}],
  computed: (f) => f,
  data: { clock: () => ({ epoch: Number(epoch) }), workspaces: () => JSON.parse(workspaces) },
};
const [entries, headerText] = new Function(...Object.keys(ctx), src)(...Object.values(ctx));
for (const e of entries()) console.log(JSON.stringify(e));
console.log("HEADER " + headerText(entries()));
