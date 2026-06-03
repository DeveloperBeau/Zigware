(function () {
  const Z = window.Zigware || (window.Zigware = {});
  const listeners = new Map();
  Z._emit = function (event, payload) {
    const set = listeners.get(event);
    if (set) for (const fn of set) { try { fn(payload); } catch (e) {} }
  };
  function listen(event, cb) {
    let set = listeners.get(event);
    if (!set) listeners.set(event, (set = new Set()));
    set.add(cb);
    return function () { set.delete(cb); };
  }
  function makeWindow(label) {
    return {
      label,
      setTitle: (title) => Z.invoke("window.setTitle", { label, title }),
      setSize: (width, height) => Z.invoke("window.setSize", { label, width, height }),
      setFullscreen: (on) => Z.invoke("window.setFullscreen", { label, on }),
      focus: () => Z.invoke("window.focus", { label }),
      close: () => Z.invoke("window.close", { label }),
      listen,
    };
  }
  Z.Window = {
    getCurrent: () => makeWindow(window.__ZIGWARE_LABEL__ || "main"),
    getByLabel: (label) => makeWindow(label),
    create: (opts) => Z.invoke("window.create", opts).then(() => makeWindow(opts.label)),
    listenAll: (event, cb) => listen(event, cb),
  };
})();
