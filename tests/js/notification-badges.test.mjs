import { assert, test } from 'vitest';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const badges = require('../../src/NotificationBadges.js');
const index = badges.appIndex([
  { id: 'firefox', name: 'Firefox' },
  { id: 'org.telegram.desktop', name: 'Telegram Desktop' },
  { id: 'editor-one', name: 'Editor' },
  { id: 'editor-two', name: 'Editor' },
]);
const row = (key, ts, app, appIcon = '') => ({ key, ts: ts / 1000, app, appIcon });
const ingest = (state, now, ...rows) => badges.ingest(state, JSON.stringify(rows), index, now);

test('app attribution uses an exact ID or unique name, not a fuzzy match', () => {
  const state = badges.session(1000);
  ingest(state, 3000, row('a', 2000, ' FIREFOX '), row('b', 2100, 'Telegram Desktop'),
    row('c', 2200, '', 'firefox.desktop'), row('d', 2300, 'Editor'),
    row('e', 2400, 'Firefox Beta'), row('f', 2500, '<img src="not-an-app">'),
    row('g', 2600, '', 'org.telegram.desktop.desktop'));
  assert.deepEqual({ ...state.counts }, { firefox: 2, 'org.telegram.desktop': 2 });
});

test('pre-existing rows, replacements and live-to-history duplicates are not new notifications', () => {
  const state = badges.session(1000);
  assert.isFalse(ingest(state, 1500, row('old', 500, 'Firefox')));
  assert.isTrue(ingest(state, 2000, row('current', 1900, 'Firefox')));
  assert.isFalse(ingest(state, 2200, row('old', 2100, 'Firefox'), row('current', 2200, 'Firefox')));
  assert.isFalse(ingest(state, 3000, { ...row('current', 2200, 'Firefox'), closed_ts: 3 }));
  assert.equal(state.counts.firefox, 1);
});

test('focus clears just that app and ignores arrivals delayed from its focus interval', () => {
  const state = badges.session(1000);
  ingest(state, 1500, row('a', 1200, 'Firefox'), row('b', 1300, 'Telegram Desktop'));
  assert.isTrue(badges.focus(state, 'firefox', 2000));
  assert.isFalse(ingest(state, 2400, row('focused', 2200, 'Firefox')));
  assert.isFalse(badges.focus(state, '', 2500));
  assert.isFalse(ingest(state, 3000, row('delayed', 2300, 'Firefox'), row('a', 2700, 'Firefox')));
  assert.isTrue(ingest(state, 3200, row('new', 3100, 'Firefox')));
  assert.deepEqual({ ...state.counts }, { firefox: 1, 'org.telegram.desktop': 1 });
});

test('malformed snapshots and unrelated payload fields do not reach the badge', () => {
  assert.deepEqual(badges.arrivals('{broken'), []);
  assert.deepEqual(badges.arrivals('x'.repeat(2 * 1024 * 1024 + 1)), []);
  assert.deepEqual(badges.arrivals(JSON.stringify([
    { ...row('valid', 1000, 'Firefox'), body: 'private', execArgv: 'untrusted' },
    row('<bad>', 1100, 'Firefox'), { key: 'bad', ts: '1' },
  ])), [{ key: 'valid', ts: 1000, app: 'firefox', icon: '' }]);
});
