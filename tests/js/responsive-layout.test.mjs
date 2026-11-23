import { assert, test } from 'vitest';
import fs from 'node:fs';
import vm from 'node:vm';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
delete require.cache[require.resolve('../../src/DockModel.js')];
const model = require('../../src/DockModel.js');
const source = fs.readFileSync(new URL('../../src/DockWindow.qml', import.meta.url), 'utf8');

// Evaluate production bindings, not a second implementation of the sizing math.
function layout({ position = 'bottom', width = 1920, height = 1040, count = 10,
  fontScale = 1, drop = '', dividers = [3, 6], dock = { autohide: false },
  workspaceId = 1, fullscreenMode = 0, smartObstructed = false } = {}) {
  const context = {
    position, width, height, vertical: model.isVertical(position), DockModel: model,
    dock, workspaceId, fullscreenMode, smartObstructed,
    appRepeater: { count },
    dividerIndexes: dividers.filter(index => index < count),
    insertIndex: drop === 'app' ? 0 : -1,
    folderDrop: { active: !!drop, hasLocalUrl: !!drop, directory: drop === 'folder' },
    Style: {
      fontScale, normalBorderWidth: 1,
      spacing: { xs: Math.round(3 * fontScale), md: Math.round(6 * fontScale) },
      space: size => Math.round(size * fontScale),
    },
  };
  context.window = context;
  vm.createContext(context);
  for (const name of [
    'gap', 'baseIconSize', 'baseIconInset', 'baseSlotSize', 'baseDividerSpace',
    'reserveDropSlot', 'showWorkspaceButton', 'layoutSlotCount', 'naturalLength', 'availableLength',
    'layoutScale', 'dockPadding', 'iconSize', 'slotSize', 'iconInset',
    'dividerMargin', 'dividerThickness', 'dividerSpace',
    'runningIndicatorHeight', 'runningIndicatorY', 'appsIconSize',
    'shown', 'alwaysVisible', 'autohide',
  ]) {
    const binding = source.match(new RegExp(
      '^  readonly property \\w+ ' + name + ': (.*(?:\\n    [^\\n]*)*)', 'm',
    ));
    assert.ok(binding, name);
    Object.defineProperty(context, name, {
      get: () => vm.runInContext('(' + binding[1] + ')', context),
    });
  }
  for (const name of ['slotStart', 'slotItemAt', 'slotIndexAt', 'popupX', 'popupY']) {
    const start = source.indexOf('function ' + name + '(');
    const end = source.indexOf('\n  }', start);
    assert.ok(start >= 0 && end >= 0, name);
    vm.runInContext(source.slice(start, end + 4), context);
  }
  const length = context.layoutSlotCount * context.slotSize
    + context.dividerIndexes.length * context.dividerSpace + 2 * context.dockPadding;
  const depth = context.slotSize + 2 * context.dockPadding;
  context.body = { x: 0, y: 0, width: context.vertical ? depth : length,
    height: context.vertical ? length : depth };
  context.workspaceItems = Array.from({ length: count }, (_, i) => ({ key: String(i) }));
  context.workspaceItemModel = { count };
  return context;
}

test('running mark applies equally to windows on the current and other workspaces', () => {
  const binding = source.match(/Rectangle \{\s*visible: ([^\n]+)\n\s*x: \(appSlot.width - width\) \/ 2\n\s*y: window.runningIndicatorY/);
  assert.ok(binding, 'running mark visibility binding');
  for (const workspaceId of [1, 13]) {
    for (const [type, windows, expected] of [
      ['app', [{ workspaceId: 1 }], true],
      ['app', [{ workspaceId: 13 }], true],
      ['app', [], false],
      ['folder', [], false],
    ]) {
      assert.equal(vm.runInNewContext(binding[1], {
        appSlot: { modelData: { type, windows }, windowCount: windows.length },
        window: { workspaceId },
      }), expected);
    }
  }
});

test('optional workspace button fits without shifting app drop targets', () => {
  for (const position of ['top', 'bottom', 'left', 'right']) {
    const plain = layout({ position, count: 12, width: 800, height: 600, drop: 'folder' });
    const extra = layout({ position, count: 12, width: 800, height: 600, drop: 'folder',
      dock: { showWorkspaceButton: true } });
    assert.equal(extra.layoutSlotCount, plain.layoutSlotCount + 1);
    assert.ok((extra.vertical ? extra.body.height : extra.body.width) <= extra.availableLength + 1e-8);
    for (let i = 0; i < 12; i++) {
      const along = extra.slotStart(i) + extra.slotSize / 2;
      const across = extra.dockPadding + extra.slotSize / 2;
      assert.strictEqual(extra.slotItemAt(extra.vertical ? across : along, extra.vertical ? along : across),
        extra.workspaceItems[i]);
    }
  }
});

test('fitScale shrinks without a minimum and never enlarges the dock', () => {
  assert.equal(model.fitScale(1920, 1000), 1);
  assert.equal(model.fitScale(500, 1000), 0.5);
  assert.equal(model.fitScale(10, 100000), 0.0001);
  assert.equal(model.fitScale(0, 1000), 1);
  assert.equal(model.fitScale(1000, 0), 1);
});

test('always-visible reserves only the dock depth and releases it in fullscreen', () => {
  const reservation = source.match(/^  exclusiveZone: (.*\n    [^\n]*)/m)[1];
  for (const position of ['bottom', 'right']) {
    for (const [workspaceId, fullscreenMode, reserves] of [[1, 0, true], [1, 1, true], [1, 2, false], [-1, 0, false]]) {
      const dock = { alwaysVisible: true, autohide: true };
      const l = layout({ position, workspaceId, fullscreenMode, dock, smartObstructed: true });
      const depth = l.vertical ? l.body.width : l.body.height;
      assert.equal(l.autohide, false);
      assert.equal(vm.runInContext(reservation, l), reserves ? Math.ceil(depth + l.gap) : 0);
      dock.alwaysVisible = false;
      assert.equal(l.autohide, true);
      assert.equal(vm.runInContext(reservation, l), 0);
    }
  }
});

for (const position of ['top', 'bottom', 'left', 'right']) {
  for (const fontScale of [0.75, 1, 1.5, 2]) {
    for (const count of [0, 5, 20, 100, 1000]) {
      test(`${position}, font ${fontScale}, ${count} apps: fit, proportions and hit targets`, () => {
        for (const drop of ['', 'app', 'folder']) {
          const l = layout({ position, fontScale, count, width: 1280, height: 672, drop });
          const length = l.vertical ? l.body.height : l.body.width;
          assert.ok(length <= l.availableLength + 1e-8);
          assert.ok(l.layoutScale > 0 && l.layoutScale <= 1);
          assert.ok(Math.abs(l.appsIconSize / l.iconSize - 56 / l.baseIconSize) < 1e-8);
          assert.ok(l.iconInset >= 0);
          assert.ok(l.runningIndicatorY + l.runningIndicatorHeight <= l.slotSize + 1e-8);
          assert.ok(l.appsIconSize <= l.slotSize);
          const growth = position === 'top' ? .15 : l.vertical ? .075 : 0;
          assert.ok(l.runningIndicatorY > l.iconInset + l.iconSize * (1 + growth));
          // First, middle and last slots remain clickable at fractional sizes.
          for (const i of new Set([0, Math.floor(count / 2), count - 1])) {
            if (i < 0 || i >= count) continue;
            const along = l.slotStart(i) + l.slotSize / 2;
            const across = l.dockPadding + l.slotSize / 2;
            const point = l.vertical ? { x: across, y: along } : { x: along, y: across };
            assert.strictEqual(l.slotItemAt(point.x, point.y), l.workspaceItems[i]);
            assert.equal(l.slotIndexAt(point), i + 1);
          }
        }
      });
    }
  }
}

test('roomy monitors preserve the current icon and drawer sizes', () => {
  const l = layout({ count: 5 });
  assert.equal(l.layoutScale, 1);
  assert.equal(l.iconSize, 44);
  assert.equal(l.appsIconSize, 56);
});

test('each monitor sizes independently, in logical pixels with reserved space excluded', () => {
  const small = layout({ position: 'left', height: 720 - 48, count: 20 });
  const large = layout({ position: 'left', height: 2160 - 48, count: 20 });
  assert.equal(small.availableLength, 666);
  assert.ok(small.layoutScale < large.layoutScale);
  assert.equal(large.layoutScale, 1);
  // Changing only the cross-axis size cannot feed back into fitting.
  const narrow = layout({ position: 'left', width: 320, height: 2160 - 48, count: 20 });
  assert.equal(narrow.layoutScale, large.layoutScale);
});

test('adding/removing a drop slot or an app recomputes fit without overflow', () => {
  const normal = layout({ width: 800, count: 20 });
  const appDrop = layout({ width: 800, count: 20, drop: 'app' });
  const folderDrop = layout({ width: 800, count: 20, drop: 'folder' });
  const added = layout({ width: 800, count: 21 });
  assert.ok(appDrop.layoutScale < normal.layoutScale);
  assert.equal(appDrop.layoutScale, folderDrop.layoutScale);
  assert.equal(appDrop.layoutScale, added.layoutScale);
  assert.equal(layout({ width: 800, count: 20 }).layoutScale, normal.layoutScale);
});

test('popup anchors follow fractional slots without shrinking the menus', () => {
  for (const position of ['top', 'bottom', 'left', 'right']) {
    const l = layout({ position, width: 800, height: 600, count: 100 });
    l.contentItem = {};
    const popup = { width: 240, height: 180 };
    const slot = {
      width: l.slotSize, height: l.slotSize,
      mapToItem: (_, x, y) => ({ x: 400 + x, y: 300 + y }),
    };
    const x = l.popupX(slot, popup), y = l.popupY(slot, popup);
    assert.ok(Number.isFinite(x) && Number.isFinite(y));
    assert.equal(popup.width, 240);
    assert.equal(popup.height, 180);
    if (!l.vertical) assert.ok(x >= l.gap && x + popup.width <= l.width - l.gap);
    else assert.ok(y >= l.gap && y + popup.height <= l.height - l.gap);
  }
});
