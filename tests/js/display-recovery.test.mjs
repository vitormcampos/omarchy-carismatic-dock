import { readFileSync } from 'node:fs';
import { createContext, runInContext } from 'node:vm';
import { assert, test } from 'vitest';

const dock = readFileSync(new URL('../../src/Dock.qml', import.meta.url), 'utf8');
const window = readFileSync(new URL('../../src/DockWindow.qml', import.meta.url), 'utf8');

function setup() {
  const calls = [];
  const add = name => () => calls.push(name);
  const context = createContext({
    dock: { displayRecoveryAttempts: 2, refresh: add('layouts') },
    docks: { instances: [] },
    displayRefreshTimer: { restart: add('debounce') },
    displayReadyTimer: { stop: add('cancel settle'), restart: add('settle') },
    Hyprland: { refreshMonitors: add('monitors'), refreshWorkspaces: add('workspaces'),
      refreshToplevels: add('windows') },
  });
  context.root = context.dock;
  for (const name of ['scheduleDisplayRecovery', 'refreshDisplayState', 'finishDisplayRecovery']) {
    const start = dock.indexOf(`  function ${name}(`);
    assert.isAtLeast(start, 0);
    runInContext(dock.slice(start, dock.indexOf('\n  }', start) + 4), context);
  }
  return { context, calls, add };
}

test('display changes debounce and refresh all compositor snapshots before remapping', () => {
  const { context: c, calls, add } = setup();
  c.scheduleDisplayRecovery();
  c.refreshDisplayState();
  assert.equal(c.dock.displayRecoveryAttempts, 1);
  assert.deepEqual(calls, ['cancel settle', 'debounce', 'monitors', 'workspaces', 'windows', 'settle']);
  c.finishDisplayRecovery();
  assert.equal(calls.at(-1), 'debounce');
  c.docks.instances = [{ monitor: { name: 'HDMI-A-1' }, workspace: { id: 12 }, remapAfterDisplayChange: add('dock remap') }];
  c.finishDisplayRecovery();
  assert.deepEqual(calls.slice(-2), ['layouts', 'dock remap']);
});

test('unresolved outputs stop retrying and never remap a placeholder', () => {
  const { context: c, calls, add } = setup();
  c.dock.displayRecoveryAttempts = 4;
  c.docks.instances = [{ monitor: null, workspace: null, remapAfterDisplayChange: add('invalid remap') },
    { monitor: {}, workspace: {}, remapAfterDisplayChange: add('dock remap') }];
  c.finishDisplayRecovery();
  assert.deepEqual(calls, ['layouts', 'dock remap']);
});

test('the dock resolves a returning monitor from its connector, not an old object', () => {
  const binding = window.match(/readonly property var monitor: (\{[\s\S]*?\n  \})/)[1];
  const old = { name: 'HDMI-A-1', id: 0 }, replacement = { name: 'HDMI-A-1', id: 1 };
  const c = createContext({ screen: { name: 'HDMI-A-1' }, Hyprland: { monitors: { values: [old] } } });
  const resolve = () => runInContext(`(function() ${binding})()`, c);
  assert.strictEqual(resolve(), old);
  c.Hyprland.monitors.values = [];
  assert.isNull(resolve());
  c.Hyprland.monitors.values = [replacement, { name: 'FALLBACK' }];
  assert.strictEqual(resolve(), replacement);
  c.screen.name = 'FALLBACK';
  assert.isNull(resolve());
});
