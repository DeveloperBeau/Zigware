import { test, expect, beforeEach } from "bun:test";
import { readFileSync } from "fs";

const shimSrc = readFileSync(new URL("../frontend/app.js", import.meta.url), "utf8");

function freshWindow(): any {
  const posted: any[] = [];
  const events: any[] = [];
  const win: any = {
    webkit: { messageHandlers: { zig: { postMessage: (m: string) => posted.push(m) } } },
    dispatchEvent: (e: any) => events.push(e),
    addEventListener: () => {},
    _posted: posted,
    _events: events,
  };
  (win as any).CustomEvent = class {
    type: string; detail: any;
    constructor(type: string, init: any) { this.type = type; this.detail = init?.detail; }
  };
  const splitMarker = "// --- demo UI wiring";
  const shimOnly = shimSrc.split(splitMarker)[0];
  const fn = new Function("window", "CustomEvent", shimOnly + "\nreturn window.zig;");
  win.zig = fn(win, (win as any).CustomEvent);
  return win;
}

let win: any;
beforeEach(() => { win = freshWindow(); });

test("invoke posts {id,cmd,args} and increments id", () => {
  win.zig.invoke("sha256", { megabytes: 4 });
  win.zig.invoke("sha256", {});
  expect(win._posted.length).toBe(2);
  const a = JSON.parse(win._posted[0]);
  const b = JSON.parse(win._posted[1]);
  expect(a).toEqual({ id: 1, cmd: "sha256", args: { megabytes: 4 } });
  expect(b.id).toBe(2);
});

test("_resolve settles the matching promise", async () => {
  const p = win.zig.invoke("sha256", {});
  win.zig._resolve(1, { hash: "abc" });
  await expect(p).resolves.toEqual({ hash: "abc" });
});

test("_reject rejects the matching promise", async () => {
  const p = win.zig.invoke("sha256", {});
  win.zig._reject(1, "unknown command");
  await expect(p).rejects.toThrow("unknown command");
});

test("_emit dispatches a zig:<channel> CustomEvent", () => {
  win.zig._emit("progress", { pct: 50 });
  expect(win._events.length).toBe(1);
  expect(win._events[0].type).toBe("zig:progress");
  expect(win._events[0].detail).toEqual({ pct: 50 });
});

test("resolving an unknown id is a no-op", () => {
  expect(() => win.zig._resolve(999, {})).not.toThrow();
});

function* hostilePayloads() {
  yield JSON.parse('{"__proto__":{"polluted":true}}');
  yield { constructor: { prototype: { polluted: true } } };
  yield { hash: "x".repeat(1_000_000) };
  yield { s: "  " };
  yield { s: "</script><script>alert(1)</script>" };
  for (let i = 0; i < 200; i++) {
    yield { s: String.fromCharCode((i * 2654435761) % 0x10000) };
  }
}

test("hostile _resolve payloads never pollute Object.prototype or eval", async () => {
  for (const payload of hostilePayloads()) {
    const w = freshWindow();
    const p = w.zig.invoke("x", {});
    w.zig._resolve(1, payload);
    await p;
    expect(({} as any).polluted).toBeUndefined();
  }
});

test("hostile _emit payloads settle without prototype pollution", () => {
  for (const payload of hostilePayloads()) {
    const w = freshWindow();
    expect(() => w.zig._emit("c", payload)).not.toThrow();
    expect(({} as any).polluted).toBeUndefined();
  }
});

test("every Zig-emitted jsString output evaluates as a JS string equal to its input", () => {
  const raw = readFileSync(new URL("./fixtures/js_escapes.jsonl", import.meta.url), "utf8");
  const lines = raw.split("\n").filter((l) => l.trim().length > 0);
  expect(lines.length).toBeGreaterThan(0);
  for (const line of lines) {
    const { in: input, out } = JSON.parse(line);
    const parsed = new Function("return " + out)();
    expect(typeof parsed).toBe("string");
    expect(parsed).toBe(input);
  }
});
