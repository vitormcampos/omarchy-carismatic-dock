import { assert, test } from 'vitest';
import fs from 'node:fs';
import vm from 'node:vm';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
delete require.cache[require.resolve('../../src/DockModel.js')];
const model = require('../../src/DockModel.js');
const dockSource = fs.readFileSync(new URL('../../src/Dock.qml', import.meta.url), 'utf8');
const windowSource = fs.readFileSync(new URL('../../src/DockWindow.qml', import.meta.url), 'utf8');
const plain = value => JSON.parse(JSON.stringify(value));

function loadFunctions(source, names, context) {
  for (const name of names) {
    const start = source.indexOf('  function ' + name + '(');
    assert.notStrictEqual(start, -1, name);
    const end = source.indexOf('\n  }', start);
    vm.runInContext(source.slice(start, end + 4), context);
  }
}

function fixture(pins = ['A'], order = ['A', 'B', 'C', 'folder:/one', 'folder:/two']) {
  const writes = [];
  const folders = model.folderItems({ folders: [{ path: '/one' }, { path: '/two' }] });
  const context = {
    DockModel: model, pendingOrder: null, pendingPins: null,
    config: { pinned: pins, order },
    Util: { shellQuote: JSON.stringify, execDetached: command => writes.push(command) },
    folderCommand: () => 'folders.sh',
  };
  Object.defineProperties(context, {
    order: { get: () => context.pendingOrder || model.configuredOrder(context.config) },
    pinnedKeys: { get: () => context.pendingPins || model.pinnedIds(context.config) },
  });
  context.root = context;
  vm.createContext(context);
  loadFunctions(dockSource, ['isPinned', 'placeAt', 'saveOrder', 'moveItem', 'pinAt', 'setPinned'], context);
  const items = () => model.groupItems(model.orderItems(
    model.buildItems(context.pinnedKeys.filter(key => ['A', 'B', 'C'].includes(key)),
      ['A', 'B', 'C'].map(key => ({ key, hasEntry: true, workspaceId: 1 }))).concat(folders), context.order));
  context.shownKeys = () => items().map(item => item.key);
  const move = (key, to) => {
    const keys = context.shownKeys();
    context.moveItem(keys.indexOf(key), to, keys);
  };
  const reload = () => {
    // Decode the exact JSON payload passed to the atomic persistence command.
    const payload = writes.at(-1).slice('folders.sh order '.length);
    const strings = payload.match(/"(?:\\.|[^"\\])*"/g).map(JSON.parse);
    context.config = { order: JSON.parse(strings[0]), pinned: JSON.parse(strings[1]) };
    context.pendingPins = null;
    context.pendingOrder = null;
  };
  return { context, writes, items, move, reload };
}

test('reordering running apps preserves pins and survives configuration reload', () => {
  const f = fixture();
  f.move('C', 1);
  assert.deepEqual(plain(f.context.pinnedKeys), ['A']);
  assert.deepEqual(f.context.shownKeys(), ['A', 'C', 'B', 'folder:/one', 'folder:/two']);
  f.reload();
  assert.deepEqual(f.context.shownKeys(), ['A', 'C', 'B', 'folder:/one', 'folder:/two']);
  assert.deepEqual(f.context.pinnedKeys, ['A']);
});

test('a pinned destination pins once at the requested position', () => {
  const f = fixture(['A', 'B']);
  f.move('C', 1);
  assert.deepEqual(plain(f.context.pinnedKeys), ['A', 'C', 'B']);
  f.reload();
  assert.deepEqual(f.items().filter(item => item.pinned && item.type === 'app').map(item => item.key), ['A', 'C', 'B']);
});

test('pinned apps and folders cannot leave their groups', () => {
  const f = fixture(['A', 'B']);
  f.move('A', 4);
  assert.deepEqual(f.context.shownKeys(), ['B', 'A', 'C', 'folder:/one', 'folder:/two']);
  f.move('folder:/two', 0);
  assert.deepEqual(f.context.shownKeys(), ['B', 'A', 'C', 'folder:/two', 'folder:/one']);
  assert.deepEqual(plain(f.context.pinnedKeys), ['B', 'A']);
});

test('original and group-clamped original positions do not write config', () => {
  const f = fixture();
  f.move('B', 1);
  f.move('A', 4);
  f.move('folder:/one', 0);
  assert.equal(f.writes.length, 0);
  assert.equal(f.context.pendingOrder, null);
  assert.equal(f.context.pendingPins, null);
});

test('empty pinned group has no implicit pin region; grid and menu still pin', () => {
  const f = fixture([]);
  f.move('C', 0);
  assert.deepEqual(plain(f.context.pinnedKeys), []);
  f.context.pinAt('B', 5, f.context.shownKeys());
  assert.deepEqual(plain(f.context.pinnedKeys), ['B']);
  assert.equal(f.context.shownKeys()[0], 'B');
  const menu = fixture([]);
  menu.context.setPinned('C', true, menu.context.shownKeys());
  assert.deepEqual(plain(menu.context.pinnedKeys), ['C']);
  const empty = fixture([], []);
  empty.context.pinAt('new-app', 0, []);
  assert.deepEqual(plain(empty.context.pinnedKeys), ['new-app']);
});

test('uninstalled pins and invisible order keys are retained', () => {
  const f = fixture(['A', 'missing'], ['missing', 'A', 'hidden', 'B', 'C', 'folder:/one', 'folder:/two']);
  f.move('C', 1);
  assert.deepEqual(plain(f.context.pinnedKeys), ['A', 'missing']);
  assert.ok(f.context.order.includes('hidden'));
  assert.ok(f.context.order.includes('missing'));
  f.reload();
  assert.deepEqual(f.context.pinnedKeys, ['A', 'missing']);
  assert.ok(f.context.order.includes('hidden'));
});

test('empty dock and isolated groups keep their bounds', () => {
  assert.equal(model.moveTarget([], 0, 0), null);
  for (const group of [0, 1, 2]) {
    const items = [0, 1].map(i => ({ key: String(i), type: group === 2 ? 'folder' : 'app', pinned: group === 0 }));
    assert.deepEqual(model.moveTarget(items, 1, 0), { index: 0, pin: false });
  }
});

test('grid preview limits explicit insertion to pinned slots', () => {
  for (const pins of [[], ['A'], ['A', 'B', 'C']]) {
    const f = fixture(pins);
    const context = { DockModel: model, workspaceItems: f.items(), shown: true, autohide: false,
      vertical: false, body: { x: 0, y: 0, width: 500, height: 60 }, slotSize: 60,
      Qt: { point: (x, y) => ({ x, y }) }, origin: () => ({ x: 0, y: 0 }), slotIndexAt: () => 5 };
    context.window = context;
    vm.createContext(context);
    loadFunctions(windowSource, ['moveExternalDrag'], context);
    context.moveExternalDrag(400, 30);
    assert.equal(context.insertIndex, pins.length);
    f.context.pinAt('new-app', context.insertIndex, f.context.shownKeys());
    assert.equal(f.context.order.indexOf('new-app'), context.insertIndex);
  }
});

test('preview and committed destination agree for every source and target, including empty groups', () => {
  for (const pins of [[], ['A'], ['A', 'B', 'C']]) {
    const initial = fixture(pins).items();
    for (const source of initial) {
      for (let to = 0; to < initial.length; to++) {
        const f = fixture(pins);
        const context = { DockModel: model, workspaceItems: f.items(), dividerIndexes: model.dividersBefore(f.items()),
          dockPadding: 6, slotSize: 60, dividerSpace: 11 };
        context.window = context;
        vm.createContext(context);
        loadFunctions(windowSource, ['slotStart', 'draggedIndex', 'constrainedDragOffset'], context);
        const from = initial.findIndex(item => item.key === source.key);
        const offset = context.slotStart(to) - context.slotStart(from);
        const preview = context.draggedIndex(from, offset);
        const limited = context.constrainedDragOffset(from, offset);
        assert.equal(context.draggedIndex(from, limited), preview);
        f.move(source.key, preview);
        assert.equal(f.context.shownKeys().indexOf(source.key), preview);
      }
    }
  }
});
