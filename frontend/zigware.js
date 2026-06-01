// window.Zigware — the single framework global. B owns it; later sub-projects
// hang their surfaces (E's Window.*, F's __dev) off this root.
class ZigError extends Error {
  constructor(e) {
    super(e && e.message ? e.message : "command failed");
    this.name = "ZigError";
    this.code = e && e.code;
    this.payload = e && e.payload;
  }
}

window.Zigware = {
  ZigError,
  _seq: 0,
  _pending: new Map(), // id -> { res, rej, onStream?, chunks:[], pending:0, settled:null }

  invoke(name, args, opts) {
    const id = ++this._seq;
    const self = this;
    return new Promise((res, rej) => {
      self._pending.set(id, {
        res,
        rej,
        onStream: opts && opts.onStream,
        chunks: [],
        pending: 0,
        settled: null,
      });
      window.webkit.messageHandlers.zig.postMessage(
        JSON.stringify({ id, cmd: name, args: args || {} })
      );
    });
  },

  _stream(id, frame) {
    const p = this._pending.get(id);
    if (p && p.onStream) p.onStream(frame);
  },

  _streamEnd(id) {
    /* no-op marker; the terminal resolve/reject still follows */
  },

  _bin(id, seq, len, mime) {
    const p = this._pending.get(id);
    if (!p) return;
    p.pending++;
    // Path-based URL: __zigware_stream is a PATH segment under the app://localhost
    // origin (NOT the URL host), so the path reaching the scheme handler is
    // /__zigware_stream/<id>/<seq> — which is what serveStream's parseStreamPath
    // and the reserved-route guard (isReservedRoute) both match. A host-based
    // app://__zigware_stream/... URL would arrive with path /<id>/<seq>, which the
    // reserved-route guard would NOT catch.
    fetch(`app://localhost/__zigware_stream/${id}/${seq}`)
      .then((r) => r.arrayBuffer())
      .then((buf) => {
        p.chunks[seq] = new Uint8Array(buf);
        p.pending--;
        this._maybeFinish(id);
      })
      .catch(() => {
        p.pending--;
        this._maybeFinish(id);
      });
  },

  _resolve(id, val) {
    const p = this._pending.get(id);
    if (p) {
      p.settled = { ok: val };
      this._maybeFinish(id);
    }
  },

  _reject(id, err) {
    const p = this._pending.get(id);
    if (p) {
      p.settled = { err };
      this._maybeFinish(id);
    }
  },

  _maybeFinish(id) {
    const p = this._pending.get(id);
    if (!p || !p.settled || p.pending > 0) return;
    this._pending.delete(id);
    if (p.settled.err) {
      p.rej(new ZigError(p.settled.err));
      return;
    }
    const val = p.chunks.length ? this._assemble(p) : p.settled.ok;
    p.res(val);
  },

  // v0.1.0 assembly: a single advertised chunk (seq 0) becomes the resolved
  // value directly (a Uint8Array). Multi-chunk concatenation is reserved; the
  // backend currently advertises one seq per Bytes result.
  _assemble(p) {
    const parts = p.chunks.filter((c) => c != null);
    if (parts.length === 1) return parts[0];
    let total = 0;
    for (const c of parts) total += c.length;
    const out = new Uint8Array(total);
    let off = 0;
    for (const c of parts) {
      out.set(c, off);
      off += c.length;
    }
    return out;
  },
};
