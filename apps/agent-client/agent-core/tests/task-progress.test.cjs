const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const test = require('node:test');
const ts = require(process.env.TYPESCRIPT_PATH || 'typescript');
const root = path.resolve(__dirname, '../../entry/src/main/ets');
const model = { exports: {} };
vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(root, 'model/TaskProgress.ets'), 'utf8'), {
  compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }
}).outputText, model);
const { formatTaskElapsed, taskProgressActive, taskProgressLabel } = model.exports;

test('elapsed time handles seconds, minute and hour boundaries, and clock rollback', () => {
  for (const [ms, expected] of [[-1000, '00:00'], [0, '00:00'], [999, '00:00'],
    [59000, '00:59'], [60000, '01:00'], [3599000, '59:59'], [3600000, '01:00:00'], [3661000, '01:01:01']]) {
    assert.equal(formatTaskElapsed(10000, 10000 + ms), expected);
  }
});

test('only preparation and execution keep the timer active', () => {
  for (const phase of ['preparing', 'running', 'done', 'partial', 'failed', 'cancelled']) {
    assert.equal(taskProgressActive(phase), ['preparing', 'running'].includes(phase));
    assert.ok(taskProgressLabel(phase).length > 0);
  }
});

// Execute the native component's actual lifecycle methods with a controlled clock.
function cardHarness() {
  const source = fs.readFileSync(path.join(root, 'ui/TaskProgressCard.ets'), 'utf8');
  const lines = source.split(/\r?\n/);
  const names = ['aboutToAppear', 'aboutToDisappear', 'clearTimer', 'updateElapsed', 'syncTimer'];
  const methods = names.map(name => {
    const start = lines.findIndex(line => line.startsWith('  ' + name + '(') || line.startsWith('  private ' + name + '('));
    assert.ok(start >= 0);
    let end = start + 1;
    while (end < lines.length && lines[end] !== '  }') end++;
    assert.ok(end < lines.length, 'Missing method terminator: ' + name);
    return lines.slice(start, end + 1).join('\n');
  });
  let now = 10000, nextId = 0;
  const intervals = new Map();
  const box = { exports: {}, formatTaskElapsed, taskProgressActive, Date: { now: () => now },
    setInterval: fn => { const id = nextId++; intervals.set(id, fn); return id; },
    clearInterval: id => intervals.delete(id) };
  vm.runInNewContext(ts.transpileModule('class Card {\n' + methods.join('\n') + '\n} exports.Card = Card;', {
    compilerOptions: { target: ts.ScriptTarget.ES2020 }
  }).outputText, box);
  const card = new box.exports.Card();
  Object.assign(card, { progress: { kind: '文本', phase: 'preparing', startedAt: now, endedAt: 0 },
    timerId: -1, visible: false, elapsed: '00:00' });
  return { card, intervals, advance(ms) { now += ms; for (const fn of intervals.values()) fn(); }, now: () => now };
}

test('live timer catches up from wall time and freezes on every terminal state', () => {
  for (const phase of ['done', 'partial', 'failed', 'cancelled']) {
    const h = cardHarness(); h.card.aboutToAppear();
    assert.equal(h.intervals.size, 1);
    h.advance(12500); assert.equal(h.card.elapsed, '00:12');
    h.card.progress = { ...h.card.progress, phase, endedAt: h.now() }; h.card.syncTimer();
    assert.equal(h.intervals.size, 0); h.advance(20000); assert.equal(h.card.elapsed, '00:12');
  }
});

test('disappear clears timers and remount resumes without resetting elapsed time', () => {
  const h = cardHarness(); h.card.aboutToAppear(); h.advance(1000); h.card.syncTimer();
  assert.equal(h.intervals.size, 1);
  h.card.aboutToDisappear(); assert.equal(h.intervals.size, 0);
  h.advance(9000); h.card.aboutToAppear(); assert.equal(h.card.elapsed, '00:10');
  h.card.aboutToDisappear(); assert.equal(h.intervals.size, 0);
});
