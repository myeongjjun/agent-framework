// Evaluate the Sessions panel template's `entries` with stubbed cmux sidebar globals.
// usage: node sessions-panel.js <template> <plan-json> <workspaces-json> <epoch>
// prints one JSON line per entry.
const fs = require("fs");
const [tpl, plan, workspaces, epoch] = process.argv.slice(2);
const src = fs.readFileSync(tpl, "utf8")
  .replace(/^const PLAN = .*$/m, "const PLAN = " + plan + ";")
  .replace(/^sidebar\(/m, "return entries;\n(");
const ctx = {
  signal: (v) => [() => v, () => {}],
  computed: (f) => f,
  data: { clock: () => ({ epoch: Number(epoch) }), workspaces: () => JSON.parse(workspaces) },
};
const entries = new Function(...Object.keys(ctx), src)(...Object.values(ctx));
for (const e of entries()) console.log(JSON.stringify(e));
