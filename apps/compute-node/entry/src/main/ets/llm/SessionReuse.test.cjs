// node SessionReuse.test.cjs
const assert = require('node:assert/strict');
const vm = require('node:vm');
const { transpile } = require('../../../../../../../tests/ets-harness.cjs');
const exp = {};
vm.runInNewContext(transpile(__dirname + '/SessionReuse.ets'), { exports: exp, Date });
const { SessionReuse, taskHead, stableSystem } = exp;

const system = (stamp, extra = '') => 'You are Loop.\nCurrent device local datetime: ' + stamp + '\nTools:\n- weather\n' + extra;
const round1 = (task) => [{ role: 'developer', content: system('10:00:01') },
  { role: 'user', content: 'User task:\n' + task + '\nControl: Current user request:\n' + task + '\nControl: Return Action. Stop after Action.' }];
const round2 = (task, stamp = '10:00:20') => [{ role: 'developer', content: system(stamp) },
  { role: 'user', content: 'User task:\n' + task + '\nAction: weather[{"q":"x"}]\nObservation: 晴 20度\nControl: Current user request:\n' + task + '\nControl: Use Final.' }];

assert.equal(taskHead('User task:\n查天气\nControl: x'), 'User task:\n查天气');
assert.equal(taskHead('User task:\n查天气\nAction: a\nObservation: b'), 'User task:\n查天气');
assert.equal(taskHead('User task:\n查天气'), 'User task:\n查天气');
assert.equal(taskHead('User task:\n查天气\n\n\nControl: x'), taskHead('User task:\n查天气\n\nCall c1 tool=t status=ok\nObservation: y'));
assert.equal(stableSystem('a\nCurrent device local datetime: X Y Z\nb'), 'a\nb');

const closed = [];
let reuse = new SessionReuse((key) => closed.push(key), 3);

// First round is sent in full under a fresh key.
const p1 = reuse.plan(round1('查天气'));
assert.equal(p1.reused, false);
assert.equal(p1.messages.length, 2);
assert(p1.key.length > 0);
// The next round of the same run continues it, even though the datetime line changed.
reuse.finish(p1, true);
const p2 = reuse.plan(round2('查天气'));
assert.equal(p2.reused, true);
assert.equal(p2.key, p1.key);
assert.equal(p2.messages.length, 1);
assert.equal(p2.messages[0].role, 'user');
assert(p2.messages[0].content.includes('Observation: 晴 20度'));
assert(!p2.messages[0].content.startsWith('User task:'), 'the task section is not re-sent');
assert(!p2.messages[0].content.includes('You are Loop'), 'the system part is not re-sent');
reuse.finish(p2, true);
assert.deepEqual(closed, []);

// A different task never continues that session.
const other = reuse.plan(round1('讲个笑话'));
assert.equal(other.reused, false);
assert.notEqual(other.key, p1.key);
reuse.finish(other, true);

// A changed system part (for example less history) forces a full request.
const changed = reuse.plan([{ role: 'developer', content: system('10:01', 'extra history\n') }, round2('查天气')[1]]);
assert.equal(changed.reused, false);
assert.equal(changed.messages.length, 2);
reuse.finish(changed, true);

// Failure or cancel discards the session so a later round starts clean.
const fresh = new SessionReuse((key) => closed.push(key), 3);
const a = fresh.plan(round1('任务A'));
fresh.finish(a, true);
const b = fresh.plan(round2('任务A'));
assert.equal(b.reused, true);
closed.length = 0;
fresh.finish(b, false);
assert.deepEqual(closed, [a.key]);
const again = fresh.plan(round2('任务A'));
assert.equal(again.reused, false, 'after a failure the next request is sent in full');
assert.equal(again.messages.length, 2);
fresh.finish(again, true);

// The identical prompt again (a retry) restarts instead of appending a duplicate turn.
closed.length = 0;
const retryStart = fresh.plan(round1('任务A'));
fresh.finish(retryStart, true);
const retry = fresh.plan(round1('任务A'));
assert.equal(retry.reused, false);
assert.equal(retry.messages.length, 2);
assert(closed.includes(retryStart.key));
fresh.finish(retry, true);

// Two requests of one run never use one session at once.
const busy = new SessionReuse(() => {}, 3);
const first = busy.plan(round1('并发'));
const second = busy.plan(round2('并发'));
assert.equal(second.reused, false);
assert.equal(second.key, '');
busy.finish(first, true);

// At most `limit` sessions are kept; the least recently used idle one is closed.
const dropped = [];
let tick = 0;
const small = new SessionReuse((key) => dropped.push(key), 2, () => ++tick);
const keys = [];
for (const task of ['t1', 't2', 't3']) {
  const plan = small.plan(round1(task));
  keys.push(plan.key);
  small.finish(plan, true);
}
assert.equal(small.size(), 2);
assert.deepEqual(dropped, [keys[0]]);
small.closeAll();
assert.equal(small.size(), 0);

// Anything that is not the developer+user pair is passed through without a key.
const odd = new SessionReuse(() => {}, 3).plan([{ role: 'user', content: 'hi' }]);
assert.equal(odd.key, '');
assert.equal(odd.reused, false);
assert.equal(odd.messages.length, 1);
console.log('PASS session reuse: continues only an identical system part and task, discards on failure, bounds the cache');
