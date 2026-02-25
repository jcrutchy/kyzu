import init, { start } from "../../kyzu-core/pkg/kyzu_core.js";

async function run() {
  await init();
  await start("gfx");
}

run();
