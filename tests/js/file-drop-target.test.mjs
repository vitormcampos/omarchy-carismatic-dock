import { assert, test } from 'vitest';
import fs from 'node:fs';
import vm from 'node:vm';
import { createRequire } from 'node:module';

// Production JS stays compatible with QML and CommonJS. Refresh the native
// module cache so watch reruns use the current model.
const require = createRequire(import.meta.url);
delete require.cache[require.resolve('../../DockModel.js')];
const model = require('../../DockModel.js');

// Exercise the actual QML handlers without starting a second desktop shell.
const source = fs.readFileSync(new URL('../../DockWindow.qml', import.meta.url), 'utf8');
function definition(marker, indent) {
  const start = source.indexOf(marker);
  assert.notStrictEqual(start, -1, marker);
  const end = source.indexOf('\n' + ' '.repeat(indent) + '}', start);
  assert.notStrictEqual(end, -1, marker);
  return source.slice(start, end + indent + 2);
}

function fixture(position = 'bottom', scale = 1, groups = [2, 2, 2]) {
  const size = Math.round(60 * scale), padding = Math.round(6 * scale), gap = 11;
  const items = [], rects = [], dividers = [];
  let cursor = padding + size;
  groups.forEach((count, group) => {
    if (count && items.length) {
      dividers.push(items.length);
      cursor += gap;
    }
    for (let i = 0; i < count; i++) {
      const item = { key: `${group}:${i}`, type: group === 2 ? 'folder' : 'app' };
      items.push(item);
      rects.push({ start: cursor, end: cursor + size, item });
      cursor += size;
    }
  });
  const vertical = model.isVertical(position);
  const calls = [];
  const context = {
    vertical, dockPadding: padding, slotSize: size, dividerSpace: gap,
    dividerIndexes: dividers, workspaceItems: items,
    workspaceItemModel: { count: items.length },
    body: { x: 100, y: 200, width: vertical ? size + 2 * padding : cursor + padding,
      height: vertical ? cursor + padding : size + 2 * padding },
    Qt: { point: (x, y) => ({ x, y }), CopyAction: 1 },
    folderDrop: { active: true, checked: true, directory: false, lastPoint: { x: 0, y: 0 } },
    checked: true, directory: false, pathCheck: { running: false },
    Util: { execDetached: command => calls.push(command) },
    dock: { openDroppedFile: (item, file) => calls.push({ item, file }) },
  };
  context.window = context;
  vm.createContext(context);
  for (const name of ['slotStart', 'slotIndexAt', 'slotItemAt', 'draggedIndex']) {
    vm.runInContext(definition('function ' + name + '(', 2), context);
  }
  for (const name of ['localFolderUrl', 'localPath']) {
    vm.runInContext(definition('function ' + name + '(', 6), context);
  }
  vm.runInContext('var dropHandler = ' + definition('function(drop) {', 6), context);
  const binding = source.match(/readonly property var fileTargetItem: ([\s\S]*?)\n\n/)[1];
  const point = (along, across = padding + size / 2) => vertical
    ? { x: across, y: along } : { x: along, y: across };
  const hit = (along, across) => {
    const p = point(along, across);
    return context.slotItemAt(p.x, p.y);
  };
  const highlight = p => {
    context.folderDrop.lastPoint = { x: p.x + context.body.x, y: p.y + context.body.y };
    return vm.runInContext(binding, context);
  };
  return { context, rects, padding, size, hit, point, highlight, binding, calls };
}

for (const position of ['top', 'bottom', 'left', 'right']) {
  for (const scale of [0.75, 1, 1.5]) {
    for (const groups of [[2, 2, 2], [0, 2, 1], [2, 0, 0], [0, 0, 2], [0, 0, 0]]) {
      test(`${position}, scale ${scale}, groups ${groups}: full slots and excluded regions`, () => {
        const f = fixture(position, scale, groups);
        for (const r of f.rects) {
          for (const along of [r.start, (r.start + r.end) / 2, r.end - 0.01]) {
            assert.strictEqual(f.hit(along), r.item);
            assert.strictEqual(f.highlight(f.point(along)), r.item);
          }
          assert.strictEqual(f.hit(r.start, f.padding - 0.01), null);
          assert.strictEqual(f.hit(r.start, f.padding), r.item);
          assert.strictEqual(f.hit(r.start, f.padding + f.size), null);
        }
        // Compare every pixel with independently constructed slot rectangles.
        const length = f.context.vertical ? f.context.body.height : f.context.body.width;
        for (let along = -1; along <= length + 1; along += 0.5) {
          const expected = f.rects.find(r => along >= r.start && along < r.end);
          assert.strictEqual(f.hit(along), expected ? expected.item : null, `coordinate ${along}`);
        }
        for (const r of f.rects) {
          const next = f.rects.find(other => other.start === r.end);
          assert.strictEqual(f.hit(r.end), next ? next.item : null);
        }
      });
    }
  }
}

test('highlight and drop use current geometry and the same full-slot target', () => {
  for (const position of ['top', 'bottom', 'left', 'right']) {
    const f = fixture(position);
    const last = f.rects.at(-1), p = f.point(last.end - 1);
    assert.strictEqual(f.highlight(p), last.item);
    f.context.dropHandler({ ...p, hasUrls: true, urls: ['file:///tmp/dock%20test.txt'], accept() {} });
    assert.strictEqual(f.calls[0].item, last.item);
    assert.strictEqual(f.calls[0].file, '/tmp/dock test.txt');

    // A stationary pointer changes targets if the body moves by one slot.
    if (f.context.vertical) f.context.body.y += f.size;
    else f.context.body.x += f.size;
    assert.strictEqual(vm.runInContext(f.binding, f.context), f.rects.at(-2).item);
    f.context.folderDrop.active = false;
    assert.strictEqual(vm.runInContext(f.binding, f.context), null);
  }
});

test('insertion and internal drag keep their center-based behavior', () => {
  const f = fixture('bottom', 1, [3, 0, 0]);
  f.rects.forEach((r, i) => {
    assert.strictEqual(f.context.slotIndexAt(f.point(r.start + f.size / 2 - 1)), i);
    assert.strictEqual(f.context.slotIndexAt(f.point(r.start + f.size / 2)), i + 1);
    assert.strictEqual(f.context.draggedIndex(i, 0), i);
  });
  assert.strictEqual(f.context.draggedIndex(0, f.size), 1);
  assert.strictEqual(f.context.draggedIndex(2, -f.size), 1);
});
