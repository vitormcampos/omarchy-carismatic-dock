import { assert, test } from 'vitest';
import fs from 'node:fs';
import vm from 'node:vm';

const source = fs.readFileSync(new URL('../../src/DockWindow.qml', import.meta.url), 'utf8');

function binding(name) {
  const expression = source.match(new RegExp(
    '^  (?:readonly property \\w+ )?' + name + ': (.*(?:\\n    [^\\n]*)*)', 'm',
  ));
  assert.ok(expression, name);
  return expression[1];
}

test('opening and dismissing folder menus never resizes the dock layer surface', () => {
  for (const position of ['top', 'bottom', 'left', 'right']) {
    const context = {
      vertical: position === 'left' || position === 'right',
      stackItem: null, slotSize: 68, dockPadding: 3, gap: 3,
      Style: { spacing: { popupRowHeight: 30, sm: 4 }, normalBorderWidth: 1 },
    };
    context.window = context;
    vm.createContext(context);
    for (const name of ['popupRows', 'popupRoom']) {
      Object.defineProperty(context, name, { get: () => vm.runInContext(binding(name), context) });
    }
    const dimensions = () => ['implicitWidth', 'implicitHeight']
      .map(name => vm.runInContext(binding(name), context));
    const initial = dimensions();
    assert.equal(context.popupRows, 10);
    for (let i = 0; i < 5; i++) {
      context.stackItem = { type: 'folder', path: '/home/user' };
      assert.deepEqual(dimensions(), initial);
      context.stackItem = null;
      assert.deepEqual(dimensions(), initial);
    }
  }
});

test('menu animations arm after initial geometry and cancel on dismissal', () => {
  const deferred = [];
  const context = {
    visible: true, stack: true, resizeReady: false,
    Qt: { callLater: callback => deferred.push(callback) },
  };
  vm.createContext(context);
  for (const name of ['prepareResize', 'armResize']) {
    const start = source.indexOf('    function ' + name + '(');
    assert.ok(start >= 0, name);
    const end = source.indexOf('\n    }', start);
    vm.runInContext(source.slice(start, end + 6), context);
  }
  context.prepareResize();
  assert.equal(context.resizeReady, false);
  deferred.shift()();
  assert.equal(context.resizeReady, true);

  context.visible = false;
  context.prepareResize();
  assert.equal(context.resizeReady, false);
  assert.equal(deferred.length, 0);

  // A scheduled callback must not re-enable animation after a rapid close.
  context.visible = true;
  context.prepareResize();
  context.visible = false;
  deferred.shift()();
  assert.equal(context.resizeReady, false);

  // App menus get the same animation as folders.
  context.visible = true;
  context.stack = false;
  context.prepareResize();
  assert.equal(context.resizeReady, false);
  deferred.shift()();
  assert.equal(context.resizeReady, true);
  assert.equal(deferred.length, 0);

  // Updating a visible menu rearms the same dimensional transition.
  context.prepareResize();
  assert.equal(context.resizeReady, false);
  deferred.shift()();
  assert.equal(context.resizeReady, true);
});

test('resize and content fade use shell motion settings and clip folder overflow', () => {
  const menu = source.slice(source.indexOf('    id: menu\n'), source.indexOf('  component MenuRow:'));
  for (const property of ['width', 'height']) {
    const behavior = menu.match(new RegExp('Behavior on ' + property + ' \\{([\\s\\S]*?)\\n    \\}'));
    assert.ok(behavior, property);
    assert.ok(behavior[1].includes('enabled: menu.resizeReady && menu.visible'));
    assert.ok(behavior[1].includes('duration: Style.duration(menu.stack ? 180 : 240)'));
    assert.ok(behavior[1].includes('easing.type: Easing.OutCubic'));
  }
  assert.ok(menu.includes('clip: true'));
  assert.ok(menu.includes('opacity: window.stackLoading ? 0 : 1'));
  assert.ok(menu.includes('duration: Style.duration(120)'));
});

test('menus use dimensional resizing without a whole-panel fade or scale', () => {
  const menu = source.slice(source.indexOf('    id: menu\n'), source.indexOf('  component MenuRow:'));
  const panel = menu.slice(0, menu.indexOf('    Column {'));
  assert.ok(!panel.includes('Behavior on opacity'));
  assert.ok(!panel.includes('Behavior on scale'));
  assert.ok(!panel.includes('openingReady'));
  assert.ok(panel.includes('onVisibleChanged: prepareResize()'));
});

test('ordinary menus animate from a compact height while folders retain their loading expansion', () => {
  const menu = source.slice(source.indexOf('    id: menu\n'), source.indexOf('  component MenuRow:'));
  const height = menu.match(/^    height: (.*(?:\n      [^\n]*)*)/m);
  assert.ok(height);
  const context = {
    stack: false, resizeReady: false, targetHeight: 128, padding: 4,
    Style: { spacing: { popupRowHeight: 30 } },
  };
  vm.createContext(context);
  const evaluate = () => vm.runInContext('(' + height[1] + ')', context);
  assert.equal(evaluate(), 26);
  context.resizeReady = true;
  assert.equal(evaluate(), 128);
  // Even a one-action app menu has a visible opening expansion.
  context.targetHeight = 38;
  context.resizeReady = false;
  assert.ok(evaluate() < context.targetHeight);
  context.stack = true;
  assert.equal(evaluate(), 38);
  context.targetHeight = 308;
  assert.equal(evaluate(), 308);
});

test('animated menu dimensions keep the dock-facing edge fixed in every orientation', () => {
  for (const position of ['top', 'bottom', 'left', 'right']) {
    const context = {
      position, width: 1280, height: 800, gap: 3, contentItem: {},
      body: { x: 500, y: 350, width: 200, height: 74 },
    };
    context.window = context;
    vm.createContext(context);
    for (const name of ['popupX', 'popupY']) {
      const start = source.indexOf('  function ' + name + '(');
      const end = source.indexOf('\n  }', start);
      vm.runInContext(source.slice(start, end + 4), context);
    }
    const slot = { width: 68, height: 68, mapToItem: (_, x, y) => ({ x: 600 + x, y: 400 + y }) };
    const edges = [0, .25, .5, .75, 1].map(progress => {
      const popup = { width: 160 + 180 * progress, height: 60 + 240 * progress };
      const x = context.popupX(slot, popup), y = context.popupY(slot, popup);
      if (position === 'bottom') return y + popup.height;
      if (position === 'top') return y;
      if (position === 'right') return x + popup.width;
      return x;
    });
    assert.ok(edges.every(edge => edge === edges[0]), position);
  }
});
