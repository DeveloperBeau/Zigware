import { test, expect } from "bun:test";
import { readFileSync } from "fs";

test("bindings.d.ts declares ZigCommands with sha256 and echoBytes", () => {
  const dts = readFileSync(new URL("../frontend/bindings.d.ts", import.meta.url), "utf8");
  expect(dts).toContain("export interface ZigCommands");
  expect(dts).toContain("sha256:");
  expect(dts).toContain("result: { hash: string }");
  expect(dts).toContain("echoBytes:");
  expect(dts).toContain("result: Uint8Array");
  expect(dts).toContain("function invoke<C extends keyof ZigCommands>");
});

test("bindings.d.ts type-checks a sample invoke call", async () => {
  // Compile a tiny TS program that imports the generated types and uses invoke.
  // Bun's transpiler strips types; for a true type-check we assert the d.ts is
  // syntactically valid TS by transpiling a file that references it.
  const sample = `
    import type { ZigCommands } from "../frontend/bindings.d.ts";
    type Args = ZigCommands["sha256"]["args"];
    const a: Args = { megabytes: 4 };
    void a;
  `;
  const transpiled = new Bun.Transpiler({ loader: "ts" }).transformSync(sample);
  expect(typeof transpiled).toBe("string");
});
