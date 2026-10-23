// Runs the real hero demo (terminal.js) against a small fake DOM and a clock
// the test advances by hand, so its controls are exercised, not just its
// strings: pausing mid-word, resuming, switching steps while a timer is
// pending, hiding the page, and the still frames under reduced motion.

import assert from "node:assert/strict";
import test from "node:test";

class FakeText {
  constructor(text) {
    this.nodeValue = String(text);
    this.parent = null;
  }

  get textContent() {
    return this.nodeValue;
  }

  set textContent(value) {
    this.nodeValue = String(value);
  }

  remove() {
    this.parent?.removeChildNode(this);
  }
}

class FakeElement {
  constructor(attributes = {}) {
    this.children = [];
    this.parent = null;
    this.hidden = false;
    this.className = "";
    this.dataset = {};
    this.offsetWidth = 0;
    this.attributes = new Map(Object.entries(attributes));
    this.listeners = new Map();
    this.style = { setProperty() {} };
    const classes = new Set();
    this.classList = {
      add: (...names) => names.forEach((name) => classes.add(name)),
      remove: (...names) => names.forEach((name) => classes.delete(name)),
      contains: (name) => classes.has(name),
      toggle: (name, force) => {
        const on = force === undefined ? !classes.has(name) : force;
        if (on) classes.add(name);
        else classes.delete(name);
        return on;
      },
    };
  }

  setAttribute(key, value) {
    this.attributes.set(key, String(value));
  }

  getAttribute(key) {
    return this.attributes.has(key) ? this.attributes.get(key) : null;
  }

  get textContent() {
    return this.children.map((child) => child.textContent).join("");
  }

  set textContent(value) {
    this.replaceChildren();
    if (value !== "" && value != null) this.append(new FakeText(value));
  }

  append(...nodes) {
    for (const node of nodes) {
      const child = typeof node === "string" ? new FakeText(node) : node;
      child.parent?.removeChildNode(child);
      child.parent = this;
      this.children.push(child);
    }
  }

  replaceChildren(...nodes) {
    for (const child of this.children) child.parent = null;
    this.children = [];
    this.append(...nodes);
  }

  insertBefore(node, reference) {
    node.parent?.removeChildNode(node);
    const index = this.children.indexOf(reference);
    node.parent = this;
    this.children.splice(index < 0 ? this.children.length : index, 0, node);
  }

  removeChildNode(node) {
    const index = this.children.indexOf(node);
    if (index >= 0) this.children.splice(index, 1);
    node.parent = null;
  }

  remove() {
    this.parent?.removeChildNode(this);
  }

  addEventListener(type, listener) {
    if (!this.listeners.has(type)) this.listeners.set(type, []);
    this.listeners.get(type).push(listener);
  }

  dispatch(type) {
    for (const listener of this.listeners.get(type) ?? []) listener({});
  }

  click() {
    this.dispatch("click");
  }
}

// A clock that only moves when the test advances it. Due timers run in
// order, and the microtasks they queue settle before the next one fires.
function fakeClock() {
  let now = 0;
  let nextId = 1;
  const timers = new Map();
  const settle = () => new Promise((resolve) => setImmediate(resolve));
  return {
    now: () => now,
    pending: () => timers.size,
    setTimeout(callback, delay) {
      const id = nextId++;
      timers.set(id, { at: now + Math.max(0, delay), callback });
      return id;
    },
    clearTimeout(id) {
      timers.delete(id);
    },
    async advance(ms) {
      const target = now + ms;
      await settle();
      for (;;) {
        let next = null;
        for (const [id, timer] of timers) {
          if (timer.at <= target && (next === null || timer.at < next[1].at))
            next = [id, timer];
        }
        if (next === null) break;
        timers.delete(next[0]);
        now = next[1].at;
        next[1].callback();
        await settle();
      }
      now = target;
      await settle();
    },
    // Advance in small steps until the condition holds.
    async until(condition, limit = 20000) {
      for (let waited = 0; waited <= limit; waited += 10) {
        if (condition()) return;
        await this.advance(10);
      }
      throw new Error("condition not reached");
    },
  };
}

let loadCount = 0;

async function loadDemo({ reducedMotion = false } = {}) {
  const clock = fakeClock();
  const el = (attributes) => new FakeElement(attributes);
  const win = el();
  const section = el();
  const nodes = {
    "[data-nc-panes]": el(),
    '[data-nc-pane="left"]': el(),
    '[data-nc-pane="right"]': el(),
    "[data-nc-tab-label]": el(),
    "[data-nc-palette]": el(),
    "[data-nc-query]": el(),
    "[data-nc-count]": el(),
    "[data-nc-status]": el(),
    "[data-nc-results]": el(),
  };
  win.querySelector = (selector) => nodes[selector] ?? null;
  win.closest = (selector) => (selector === ".nc-demo" ? section : null);

  const steps = [0, 1, 2].map(() => el({ "aria-pressed": "false" }));
  const motion = el();
  const chips = ["palette", "enter", "focus"].map((name) => {
    const chip = el();
    chip.dataset.ncKey = name;
    return chip;
  });
  section.querySelector = (selector) =>
    selector === "[data-nc-motion]" ? motion : null;
  section.querySelectorAll = (selector) =>
    selector === "[data-nc-step]"
      ? steps
      : selector === "[data-nc-key]"
        ? chips
        : [];

  const document = el();
  document.hidden = false;
  document.createElement = () => el();
  document.createTextNode = (text) => new FakeText(text);
  document.querySelector = (selector) =>
    selector === "[data-nc-demo]" ? win : null;

  const media = { matches: reducedMotion, listeners: [] };
  media.addEventListener = (type, listener) => media.listeners.push(listener);
  let observerCallback = null;

  globalThis.document = document;
  globalThis.window = {
    setTimeout: (callback, delay) => clock.setTimeout(callback, delay),
    clearTimeout: (id) => clock.clearTimeout(id),
    matchMedia: () => media,
    IntersectionObserver: class {
      constructor(callback) {
        observerCallback = callback;
      }

      observe() {}

      disconnect() {}
    },
  };
  Object.defineProperty(globalThis, "performance", {
    value: { now: () => clock.now() },
    configurable: true,
    writable: true,
  });

  // A fresh module instance runs initDemo against this page.
  loadCount += 1;
  await import(`../terminal.js?demo=${loadCount}`);

  return {
    clock,
    steps,
    motion,
    query: nodes["[data-nc-query]"],
    bar: nodes["[data-nc-palette]"],
    right: nodes['[data-nc-pane="right"]'],
    panes: nodes["[data-nc-panes]"],
    state: () => section.getAttribute("data-motion"),
    pressed: () =>
      steps.findIndex((step) => step.getAttribute("aria-pressed") === "true"),
    setHidden(hidden) {
      document.hidden = hidden;
      document.dispatch("visibilitychange");
    },
    scrollAway() {
      observerCallback([{ isIntersecting: false }]);
    },
  };
}

test("the demo plays the palette step and types the query", async () => {
  const demo = await loadDemo();
  assert.equal(demo.state(), "playing");
  assert.equal(demo.pressed(), 0);
  await demo.clock.until(() => demo.query.textContent === "split");
  assert.equal(demo.bar.hidden, false);
});

test("pausing mid-word holds the text, and playing resumes from it", async () => {
  const demo = await loadDemo();
  await demo.clock.until(() => demo.query.textContent.length === 2);
  demo.motion.click();
  assert.equal(demo.state(), "paused");
  assert.equal(demo.motion.textContent, "Play");
  const held = demo.query.textContent;
  await demo.clock.advance(10000);
  assert.equal(demo.query.textContent, held, "nothing types while paused");

  demo.motion.click();
  assert.equal(demo.state(), "playing");
  const seen = [];
  await demo.clock.until(() => {
    seen.push(demo.query.textContent);
    return demo.query.textContent === "split";
  });
  for (const text of seen)
    assert.ok(
      text.startsWith(held),
      `resumed text ${JSON.stringify(text)} restarted`,
    );
});

test("switching steps while a timer is pending cancels the old step", async () => {
  const demo = await loadDemo();
  await demo.clock.until(() => demo.query.textContent.length === 1);
  const typed = demo.query.textContent;
  demo.steps[2].click();
  assert.equal(demo.pressed(), 2);
  assert.equal(
    demo.bar.hidden,
    true,
    "the restore step starts from the split frame",
  );
  // The restore step runs about 5.4 s; the old palette step must stay dead.
  await demo.clock.advance(5000);
  assert.equal(demo.query.textContent, typed, "the cancelled step kept typing");
  assert.equal(demo.bar.hidden, true);
  await demo.clock.until(() => demo.pressed() === 0);
});

test("hiding the page or scrolling away holds the demo; returning resumes it", async () => {
  const demo = await loadDemo();
  await demo.clock.until(() => demo.query.textContent.length === 3);
  demo.setHidden(true);
  assert.equal(demo.state(), "paused");
  const held = demo.query.textContent;
  await demo.clock.advance(10000);
  assert.equal(demo.query.textContent, held);
  demo.setHidden(false);
  assert.equal(demo.state(), "playing");
  await demo.clock.until(() => demo.query.textContent === "split");

  demo.scrollAway();
  assert.equal(demo.state(), "paused");
});

test("under reduced motion the demo shows still frames and sets no timers", async () => {
  const demo = await loadDemo({ reducedMotion: true });
  assert.equal(demo.state(), "still");
  assert.equal(demo.pressed(), 0);
  assert.equal(
    demo.query.textContent,
    "split",
    "the first still frame shows the filtered palette",
  );
  assert.equal(demo.clock.pending(), 0);

  demo.steps[1].click();
  assert.equal(demo.pressed(), 1);
  assert.equal(demo.bar.hidden, true);
  assert.ok(demo.panes.classList.contains("is-split"));
  assert.match(demo.right.textContent, /README\.md/);
  assert.equal(demo.clock.pending(), 0);

  demo.motion.click();
  assert.equal(
    demo.state(),
    "playing",
    "the visitor can still choose to play it",
  );
  assert.ok(demo.clock.pending() > 0);
});
