// frontend/bindings.d.ts is generated and git-ignored. Generate it before the
// tests run so `bun test` works from a clean checkout with no manual step.
import { existsSync } from "fs";

const out = new URL("../frontend/bindings.d.ts", import.meta.url);
if (!existsSync(out)) {
  const root = new URL("..", import.meta.url).pathname;
  const run = Bun.spawnSync(["zig", "build", "dts"], { cwd: root });
  if (run.exitCode !== 0 || !existsSync(out)) {
    throw new Error(`zig build dts failed (is Zig 0.16.0 on PATH?):\n${run.stderr.toString()}`);
  }
}
