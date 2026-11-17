import { assert, test } from 'vitest';
import fs from 'node:fs';
import vm from 'node:vm';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
delete require.cache[require.resolve('../../src/DockModel.js')];
const model = require('../../src/DockModel.js');
const dockSource = fs.readFileSync(new URL('../../src/Dock.qml', import.meta.url), 'utf8');
const windowSource = fs.readFileSync(new URL('../../src/DockWindow.qml', import.meta.url), 'utf8');

function load(source, names, context) {
  for (const name of names) {
    const start = source.indexOf('  function ' + name + '(');
    assert.ok(start >= 0, name);
    const end = source.indexOf('\n  }', start);
    assert.ok(end >= 0, name);
    vm.runInContext(source.slice(start, end + 4), context);
  }
}

function folders() {
  return model.folderShortcuts(model.folderItems({
    folders: [{ path: '/Downloads' }, { path: '/Projects' }],
  }), '/home/user');
}

test('Home and Trash appear even without user folders', () => {
  const items = model.folderShortcuts([], '/home/user/');
  assert.deepEqual(items.map(item => item.key), ['folder:home', 'folder:trash']);
  assert.equal(items[0].path, '/home/user');
  assert.equal(items[0].icon, 'user-home');
  assert.equal(items[1].path, 'trash:///');
  assert.equal(items[1].icon, 'user-trash');
  assert.ok(items.every(item => item.fixed && item.type === 'folder' && item.windows.length === 0));
});

test('user Home shortcuts are deduplicated without mutating saved folders', () => {
  const config = { folders: [{ path: '/home/user/', icon: 'custom-home' }, { path: '/Downloads' }] };
  const before = JSON.stringify(config);
  const items = model.folderShortcuts(model.folderItems(config), '/home/user');
  assert.deepEqual(items.map(item => item.key), ['folder:home', 'folder:/Downloads', 'folder:trash']);
  assert.equal(JSON.stringify(config), before);
  assert.deepEqual(model.folderShortcuts(items, '/home/user'), items);
});

test('fixed entries frame the folder group regardless of persisted order', () => {
  const items = [
    { key: 'pinned', type: 'app', pinned: true },
    { key: 'running', type: 'app', pinned: false },
    ...folders(),
  ];
  const ordered = model.groupItems(model.orderItems(items,
    ['folder:trash', 'folder:/Projects', 'running', 'folder:home', 'pinned', 'folder:/Downloads']));
  assert.deepEqual(ordered.map(item => item.key), [
    'pinned', 'running', 'folder:home', 'folder:/Projects', 'folder:/Downloads', 'folder:trash',
  ]);
  assert.deepEqual(model.dividersBefore(ordered), [1, 2]);
});

test('user folders reorder only between Home and Trash; fixed entries cannot move', () => {
  const items = folders();
  assert.equal(model.moveTarget(items, 0, 2), null);
  assert.equal(model.moveTarget(items, 3, 1), null);
  assert.deepEqual(model.moveTarget(items, 1, 0), { index: 1, pin: false });
  assert.deepEqual(model.moveTarget(items, 1, 3), { index: 2, pin: false });
  assert.deepEqual(model.moveTarget(items, 2, 0), { index: 1, pin: false });
  assert.deepEqual(model.moveTarget(items, 2, 3), { index: 2, pin: false });
});

test('built-ins are never mistaken for pinned app destinations', () => {
  const items = [
    { key: 'pinned', type: 'app', pinned: true },
    { key: 'running', type: 'app', pinned: false },
    ...folders(),
  ];
  assert.deepEqual(model.moveTarget(items, 1, 2), { index: 1, pin: false });
  assert.deepEqual(model.moveTarget(items, 1, 5), { index: 1, pin: false });
  assert.deepEqual(model.moveTarget(items, 1, 0), { index: 0, pin: true });
});

test('Home opens as a local directory, Trash as a GIO URI', () => {
  const calls = [];
  const context = {
    Util: { shellQuote: JSON.stringify, execDetached: command => calls.push(command) },
  };
  context.root = context;
  vm.createContext(context);
  load(dockSource, ['launch'], context);
  const [home, , , trash] = folders();
  context.launch(home);
  context.launch(trash);
  assert.ok(calls[0].includes('xdg-open "/home/user"'));
  assert.equal(calls[1], 'gio open trash:///');
  assert.ok(!calls[1].includes('rm') && !calls[1].includes('trash --empty'));
});

test('fixed shortcuts cannot be removed or have files dropped into Trash', () => {
  const calls = [];
  const context = {
    order: ['folder:home', 'folder:/Downloads', 'folder:trash'],
    folderCommand: () => 'folders.sh',
    Util: { shellQuote: JSON.stringify, execDetached: command => calls.push(command) },
  };
  context.root = context;
  vm.createContext(context);
  load(dockSource, ['removeFolder', 'openDroppedFile'], context);
  const [home, downloads, , trash] = folders();
  context.removeFolder(home);
  context.removeFolder(trash);
  context.openDroppedFile(trash, '/file.txt');
  assert.equal(calls.length, 0);
  context.openDroppedFile(home, '/file.txt');
  assert.equal(calls[0], 'folders.sh move "/file.txt" "/home/user"');
  context.removeFolder(downloads);
  assert.equal(calls[1], 'folders.sh remove "/Downloads"');
});

for (const position of ['top', 'bottom', 'left', 'right']) {
  test(`${position}: fixed entries retain full click targets, Trash rejects file drops`, () => {
    const items = folders();
    const context = {
      DockModel: model, workspaceItems: items, dividerIndexes: [],
      slotSize: 13.125, dockPadding: .5, dividerSpace: 2,
      vertical: model.isVertical(position),
      workspaceItemModel: { count: items.length },
    };
    context.window = context;
    const depth = context.slotSize + context.dockPadding * 2;
    const length = (items.length + 1) * context.slotSize + context.dockPadding * 2;
    context.body = { width: context.vertical ? depth : length, height: context.vertical ? length : depth };
    vm.createContext(context);
    load(windowSource, ['slotStart', 'slotItemAt', 'draggedIndex', 'constrainedDragOffset'], context);
    for (let i = 0; i < items.length; i++) {
      const along = context.slotStart(i) + context.slotSize / 2;
      const across = context.dockPadding + context.slotSize / 2;
      const actual = context.vertical
        ? context.slotItemAt(across, along) : context.slotItemAt(along, across);
      assert.strictEqual(actual, items[i].builtin === 'trash' ? null : items[i]);
    }
    for (const index of [0, 3]) {
      assert.equal(context.draggedIndex(index, 10000), index);
      assert.equal(context.constrainedDragOffset(index, 10000), 0);
    }
  });
}

test('committed reorders use fixed metadata and match the preview', () => {
  let items = folders();
  const writes = [];
  const context = {
    DockModel: model, itemFor: key => items.find(item => item.key === key),
    shownKeys: () => items.map(item => item.key),
    placeAt: (key, index, keys) => {
      writes.push({ key, index });
      items = model.groupItems(model.orderItems(items, model.orderWithKeyAt(keys, key, index)));
    },
  };
  context.root = context;
  vm.createContext(context);
  load(dockSource, ['moveItem'], context);
  context.moveItem(0, 2);
  context.moveItem(3, 1);
  assert.equal(writes.length, 0);
  context.moveItem(2, 0);
  assert.deepEqual(items.map(item => item.key), [
    'folder:home', 'folder:/Projects', 'folder:/Downloads', 'folder:trash',
  ]);
  assert.deepEqual(writes, [{ key: 'folder:/Projects', index: 1 }]);
});

test('Trash context menu never treats its URI as a local folder stack', () => {
  const calls = [];
  const context = { openStack: item => calls.push(item), closeStack: () => {}, dock: {} };
  context.window = context;
  vm.createContext(context);
  load(windowSource, ['openMenu', 'openStack'], context);
  const trash = folders().at(-1);
  context.openStack(trash, {});
  assert.equal(calls.length, 0);
  context.openMenu(trash, {});
  assert.strictEqual(context.menuItem, trash);
  // Removal is absent from both fixed entries' context menus.
  assert.ok(windowSource.includes('visible: menu.folder && !menu.item.fixed'));
});
