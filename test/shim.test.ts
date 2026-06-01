import { test, expect, beforeEach } from "bun:test";
import { readFileSync } from "fs";

const shimSrc = readFileSync(new URL("../frontend/zigware.js", import.meta.url), "utf8");

function freshWindow(): any {
  const posted: any[] = [];
  const win: any = {
    webkit: { messageHandlers: { zig: { postMessage: (m: string) => posted.push(m) } } },
    _posted: posted,
  };
  // zigware.js references `fetch`; stub it per test when binary is exercised.
  const fn = new Function("window", "fetch", shimSrc + "\nreturn window.Zigware;");
  win.Zigware = fn(win, win.fetch || (() => Promise.reject(new Error("no fetch"))));
  return win;
}

let win: any;
beforeEach(() => { win = freshWindow(); });

test("invoke posts {id,cmd,args} and increments id", () => {
  win.Zigware.invoke("sha256", { megabytes: 4 });
  win.Zigware.invoke("sha256", {});
  expect(win._posted.length).toBe(2);
  expect(JSON.parse(win._posted[0])).toEqual({ id: 1, cmd: "sha256", args: { megabytes: 4 } });
  expect(JSON.parse(win._posted[1]).id).toBe(2);
});

test("_resolve settles the matching promise", async () => {
  const p = win.Zigware.invoke("sha256", {});
  win.Zigware._resolve(1, { hash: "abc" });
  await expect(p).resolves.toEqual({ hash: "abc" });
});

test("_reject rejects with a ZigError carrying code", async () => {
  const p = win.Zigware.invoke("x", {});
  win.Zigware._reject(1, { code: "not_found", message: "nope" });
  await expect(p).rejects.toThrow("nope");
});

test("_reject error exposes .code on the ZigError", async () => {
  const p = win.Zigware.invoke("x", {});
  win.Zigware._reject(1, { code: "not_found", message: "nope" });
  let caught: any;
  try { await p; } catch (e) { caught = e; }
  expect(caught.name).toBe("ZigError");
  expect(caught.code).toBe("not_found");
});

test("_stream delivers frames to opts.onStream", () => {
  const frames: any[] = [];
  win.Zigware.invoke("sha256", {}, { onStream: (f: any) => frames.push(f) });
  win.Zigware._stream(1, { pct: 25 });
  win.Zigware._stream(1, { pct: 50 });
  expect(frames).toEqual([{ pct: 25 }, { pct: 50 }]);
});

test("binary: resolve waits for the advertised _bin fetch then assembles", async () => {
  const w = freshWindow();
  const bytes = new Uint8Array([0, 1, 2, 3]);
  w.fetch = () => Promise.resolve({ arrayBuffer: () => Promise.resolve(bytes.buffer) });
  w.Zigware = new Function("window", "fetch", shimSrc + "\nreturn window.Zigware;")(w, w.fetch);
  const p = w.Zigware.invoke("thumb", {});
  w.Zigware._bin(1, 0, 4, "application/octet-stream");
  w.Zigware._resolve(1, null); // terminal arrives before the fetch resolves
  const result = await p;
  expect(result).toBeInstanceOf(Uint8Array);
  expect(Array.from(result)).toEqual([0, 1, 2, 3]);
});

test("resolving an unknown id is a no-op", () => {
  expect(() => win.Zigware._resolve(999, {})).not.toThrow();
});

test("hostile _resolve payloads never pollute Object.prototype", async () => {
  const payloads = [
    JSON.parse('{"__proto__":{"polluted":true}}'),
    { hash: "x".repeat(100000) },
    { s: "</script><script>alert(1)</script>" },
  ];
  for (const payload of payloads) {
    const w = freshWindow();
    const p = w.Zigware.invoke("x", {});
    w.Zigware._resolve(1, payload);
    await p;
    expect(({} as any).polluted).toBeUndefined();
  }
});

test("every Zig-emitted jsString output evaluates to its input", () => {
  const raw = readFileSync(new URL("./fixtures/js_escapes.jsonl", import.meta.url), "utf8");
  const lines = raw.split("\n").filter((l) => l.trim());
  expect(lines.length).toBeGreaterThan(0); // guard: a missing/empty fixture must FAIL, not pass vacuously
  for (const line of lines) {
    const { in: input, out } = JSON.parse(line);
    const parsed = new Function("return " + out)();
    expect(parsed).toBe(input);
  }
});
