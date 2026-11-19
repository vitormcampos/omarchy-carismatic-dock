import { assert, test } from 'vitest';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import vm from 'node:vm';
import { execFileSync } from 'node:child_process';

const source = fs.readFileSync(new URL('../../src/LocalAppLibrary.qml', import.meta.url), 'utf8');

function library(themedIcons = {}) {
  const context = vm.createContext({
    iconIndex: Object.create(null),
    pendingIconIndex: Object.create(null),
    Quickshell: { iconPath: name => themedIcons[name] || '' },
    Util: { fileUrl: file => 'file://' + file },
    iconIndexDebounce: { restart() { context.refreshes++; } },
    refreshes: 0,
  });
  context.root = context;
  for (const name of ['iconSource', 'indexIconLine', 'iconIndexScanCommand', 'refreshIcons']) {
    const start = source.indexOf('  function ' + name + '(');
    const end = source.indexOf('\n  }', start);
    assert.ok(start >= 0 && end > start);
    vm.runInContext(source.slice(start, end + 4), context);
  }
  return context;
}

test('new icons resolve after an index swap even when the Qt cache stays empty', () => {
  const lib = library({ 'application-x-executable': 'image://generic' });
  assert.equal(lib.iconSource('herdr-app'), 'image://generic');

  lib.indexIconLine('/usr/share/icons/hicolor/scalable/apps/herdr-app.svg');
  lib.iconIndex = lib.pendingIconIndex;

  assert.equal(lib.iconSource('herdr-app'), 'file:///usr/share/icons/hicolor/scalable/apps/herdr-app.svg');
});

test('theme icons and explicit URLs retain their original resolution', () => {
  const lib = library({ app: 'image://theme/app' });
  lib.iconIndex.app = '/fallback/app.svg';
  assert.equal(lib.iconSource('app'), 'image://theme/app');
  for (const value of ['file:///icons/app.svg', 'image://icon/app'])
    assert.equal(lib.iconSource(value), value);
  assert.equal(lib.iconSource('/icons/app.svg'), 'file:///icons/app.svg');
});

test('index keeps the first candidate and supports prototype-shaped icon names', () => {
  const lib = library();
  lib.indexIconLine('/icons/apps/app.svg');
  lib.indexIconLine('/icons/apps/app.png');
  lib.indexIconLine('/icons/apps/__proto__.svg');
  lib.indexIconLine('not an absolute path');
  assert.equal(lib.pendingIconIndex.app, '/icons/apps/app.svg');
  assert.equal(lib.pendingIconIndex.__proto__, '/icons/apps/__proto__.svg');
});

test('refresh requests schedule a scan', () => {
  const lib = library();
  lib.refreshIcons();
  assert.equal(lib.refreshes, 1);
});

test('a refresh during a scan is retried instead of discarded', () => {
  const lib = library();
  lib.iconIndexScan = { running: true };
  lib.retries = 0;
  lib.restart = () => { lib.retries++; };
  const handler = source.match(/onTriggered: \{([\s\S]*?)\n    \}/)[1];

  vm.runInContext(handler, lib);
  assert.equal(lib.retries, 1);
  assert.equal(lib.iconIndexScan.running, true);

  lib.iconIndexScan.running = false;
  vm.runInContext(handler, lib);
  assert.equal(lib.iconIndexScan.running, true);
  assert.equal(lib.retries, 1);
});

test('startup and catalog changes request icon refreshes', () => {
  assert.match(source, /Component\.onCompleted: root\.refreshIcons\(\)/);
  const lib = library();
  lib.appsChanged = () => {};
  const handler = source.match(/function onValuesChanged\(\) \{([\s\S]*?)\n    \}/)[1];
  vm.runInContext(handler, lib);
  assert.equal(lib.refreshes, 1);
});

test('scanner discovers new icons in XDG directories containing spaces', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dock-icons-'));
  try {
    const dataHome = path.join(dir, 'user data');
    const dataDir = path.join(dir, 'system data');
    const svg = path.join(dataHome, 'icons/hicolor/scalable/apps/new-app.svg');
    const png = path.join(dataHome, 'icons/hicolor/48x48/apps/new-app.png');
    const device = path.join(dataDir, 'icons/hicolor/scalable/devices/new-device.svg');
    for (const file of [svg, png, device]) {
      fs.mkdirSync(path.dirname(file), { recursive: true });
      fs.writeFileSync(file, '');
    }
    const lib = library();
    const output = execFileSync('bash', ['-c', lib.iconIndexScanCommand()], {
      encoding: 'utf8',
      env: { ...process.env, HOME: dir, XDG_DATA_HOME: dataHome, XDG_DATA_DIRS: dataDir },
    });
    for (const line of output.split('\n')) lib.indexIconLine(line);
    assert.equal(lib.pendingIconIndex['new-app'], svg);
    assert.equal(lib.pendingIconIndex['new-device'], device);

    fs.unlinkSync(svg);
    fs.unlinkSync(png);
    lib.pendingIconIndex = Object.create(null);
    const next = execFileSync('bash', ['-c', lib.iconIndexScanCommand()], {
      encoding: 'utf8',
      env: { ...process.env, HOME: dir, XDG_DATA_HOME: dataHome, XDG_DATA_DIRS: dataDir },
    });
    for (const line of next.split('\n')) lib.indexIconLine(line);
    assert.equal(lib.pendingIconIndex['new-app'], undefined);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
