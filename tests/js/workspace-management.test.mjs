import { assert, test } from 'vitest';
import { createRequire } from 'node:module';
import { readFileSync } from 'node:fs';
import { runInNewContext } from 'node:vm';

const require = createRequire(import.meta.url);
const m = require('../../src/WorkspaceModel.js');
const monitors = [{ name: 'DP-1', activeId: 12 }, { name: 'HDMI-A-1', activeId: 22 }];
const spaces = [
  { id: 11, monitor: 'DP-1' }, { id: 12, monitor: 'DP-1' },
  { id: 21, monitor: 'HDMI-A-1' }, { id: 22, monitor: 'HDMI-A-1' },
  { id: 32, monitor: 'DP-1' }, { id: -99, monitor: 'DP-1' },
];
const a = { workspaceId: 12, title: 'Window', address: '0xabc' };
const b = { workspaceId: 21, title: 'Window', address: 'abc2' };
const c = { workspaceId: -99, minimized: true, minimizedFrom: 12, title: 'Window', address: 'abc3' };
const orphan = { workspaceId: -99, minimized: true, minimizedFrom: 24, title: 'Minimized' };
const windows = [b, a, c, orphan];

test('picker groups by real ID and keeps minimized origins', () => {
  const catalog = m.catalog(spaces, monitors, windows);
  const rows = m.rows(windows, catalog, 12);
  assert.deepEqual(rows.filter(row => row.kind === 'workspace').map(row => row.space.id), [12, 21, 24]);
  assert.isTrue(rows[0].current);
  assert.isTrue(rows[0].space.fullId);
  assert.deepEqual(rows.filter(row => row.kind === 'window').map(row => row.title),
    ['Window · 1', 'Window · 2', 'Window', 'Minimized']);
  assert.equal(rows[2].window, c);
  assert.isFalse(catalog.byId[24].present);
});

test('picker keeps numeric order across active workspace and monitor changes', () => {
  const pickerSpaces = [{ id: 10, monitor: 'DP-1' }, { id: 2, monitor: 'HDMI-A-1' }, ...spaces];
  const pickerWindows = [a, { workspaceId: 10 }, c, { workspaceId: 2 }, b];
  for (const [currentId, monitor] of [[10, 'DP-1'], [21, 'HDMI-A-1'], [12, 'DP-1']]) {
    const activeMonitors = monitors.map(item => item.name === monitor ? { ...item, activeId: currentId } : item);
    if (monitor === 'HDMI-A-1') activeMonitors.reverse();
    const catalog = m.catalog(pickerSpaces, activeMonitors, pickerWindows);
    const rows = m.rows(pickerWindows, catalog, currentId);
    const headers = rows.filter(row => row.kind === 'workspace');
    assert.deepEqual(headers.map(row => row.space.id), [2, 10, 12, 21]);
    assert.deepEqual(headers.filter(row => row.current).map(row => row.space.id), [currentId]);
    assert.deepEqual(rows.filter(row => row.kind === 'window').map(row => row.window),
      [pickerWindows[3], pickerWindows[1], a, c, b]);
  }
});

test('Mission Control tabs keep numeric order across focus changes and include empty active spaces', () => {
  const existing = spaces.filter(space => space.id !== 22).concat({ id: 20, monitor: 'DP-1' }).reverse();
  const catalog = m.catalog(existing, monitors, windows);
  const board = m.missionLayout(windows, catalog, monitors, 'HDMI-A-1', 22);
  const ids = [11, 12, 20, 21, 22, 32];
  assert.deepEqual(board.workspaces.map(space => space.id), ids);
  assert.deepEqual(board.currentCards, []);
  assert.deepEqual(board.otherCards.map(card => card.window), [b, a, c, orphan]);
  assert.equal(board.otherCards[2].space.id, 12);
  assert.equal(board.otherCards[3].space.id, 24);
  const local = m.missionLayout(windows, catalog, monitors, 'DP-1', 12);
  assert.deepEqual(local.workspaces.map(space => space.id), ids);
  assert.deepEqual(local.currentCards.map(card => card.window), [a, c]);
  assert.deepEqual(local.otherCards.map(card => card.window), [b, orphan]);
  assert.notProperty(catalog.byId, '-99');
});

test('Mission Control enlarges a few windows without overflowing the stage', () => {
  const single = m.missionGrid(1, 2500, 1000, 1);
  const four = m.missionGrid(4, 2500, 1000, 1);
  assert.equal(single.columns, 1);
  assert.equal(single.cellWidth, 920);
  assert.equal(four.columns, 2);
  assert.isAbove(four.cellHeight, 300);
  for (const count of [0, 1, 2, 4, 7, 30]) {
    for (const [width, height, scale] of [[340, 310, 1], [760, 230, 1.5], [2500, 1000, 1]]) {
      const grid = m.missionGrid(count, width, height, scale);
      assert.isAtMost(grid.width, width);
      assert.isAtMost(grid.height, height);
      assert.equal(grid.height === 0, count === 0);
      assert.isAtLeast(grid.columns, 1);
    }
  }
});

test('Mission Control highlights only legal drop destinations', () => {
  const catalog = m.catalog(spaces, monitors, windows);
  assert.isTrue(m.canDrop(a, catalog.byId[22]));
  for (const target of [catalog.byId[12], catalog.byId[24], null]) assert.isFalse(m.canDrop(a, target));
  assert.isFalse(m.canDrop(c, catalog.byId[22]));
});

test('destination list includes the other monitor but omits the source and missing workspaces', () => {
  const catalog = m.catalog(spaces, monitors, windows);
  const rows = m.destinations(catalog, monitors, 'DP-1', 12, a);
  assert.deepEqual(rows.filter(row => row.kind === 'destination').map(row => row.space.id), [11, 32, 22, 21]);
  assert.deepEqual(m.destinations(catalog, monitors, 'DP-1', 12, c), []);
});

test('Mission Control hit tests scrolled delegates and revalidates on release', () => {
  const source = readFileSync(new URL('../../src/MissionControl.qml', import.meta.url), 'utf8');
  const functions = ['workspaceAt', 'finishDrag'].map(name => {
    const start = source.indexOf(`  function ${name}(`);
    const end = source.indexOf('\n  }', start);
    assert.ok(start >= 0 && end > start);
    return source.slice(start, end + 4);
  }).join('\n');
  const moves = [];
  const remote = { id: 22, monitor: 'HDMI-A-1', present: true };
  const root = { dragWindow: a, dragAddress: a.address,
    clearDrag() { this.dragAddress = ''; },
    dock: { moveManagedWindow: (...args) => moves.push(args) } };
  const workspaces = {
    width: 100, height: 50,
    mapFromItem: (_item, x, y) => ({ x, y }),
    contentItem: { mapFromItem: (_item, x, y) => ({ x: x + 200, y }) },
    itemAt: (x, y) => y < 40 && x >= 230 ? { modelData: remote } : null,
  };
  const ctx = { root, workspaces, keys: {}, WorkspaceModel: m };
  runInNewContext(functions, ctx);
  root.workspaceAt = ctx.workspaceAt;
  assert.equal(ctx.workspaceAt({ x: 102, y: 20 }), null);
  assert.equal(ctx.workspaceAt({ x: 55, y: 48 }), null);
  assert.equal(ctx.workspaceAt({ x: 55, y: 20 }), remote);
  ctx.finishDrag({ x: 55, y: 20 });
  assert.equal(root.dragAddress, '');
  assert.deepEqual(moves, [['0xabc', 22, 'HDMI-A-1']]);
  remote.present = false;
  root.dragAddress = a.address;
  ctx.finishDrag({ x: 55, y: 20 });
  assert.equal(moves.length, 1);
});

test('move targets one address and numeric workspace without following', () => {
  assert.equal(m.moveExpression(b, 12), 'hl.dsp.window.move({ workspace = "12", window = "address:0xabc2", follow = false })');
  for (const id of [21, '12', -99, 1.5, '12" })']) assert.equal(m.moveExpression(b, id), '');
  assert.equal(m.moveExpression(c, 22), '');
  assert.equal(m.moveExpression({ ...b, address: 'abc"' }, 12), '');
  assert.equal(m.slot(20), 0);
});
