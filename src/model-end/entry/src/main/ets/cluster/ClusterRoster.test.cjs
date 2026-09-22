const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const { transpile } = require('../../../../../../tests/harness.cjs');
const box = { exports: {}, Error, Map, Math, Number };
vm.runInNewContext(transpile(__dirname + '/ClusterRoster.ets'), box);
const { RankMember, rankComputes, freezeComputeRank, freezeNameRank, rankNames, slotOf } = box.exports;
function mem(key, memAvail) {
  const item = new RankMember();
  item.key = key;
  item.memAvail = memAvail;
  return item;
}
assert.equal(rankComputes([mem('70', 2000), mem('80', 8000)]).join(','), '80,70');
assert.equal(slotOf(rankComputes([mem('70', 2000), mem('80', 8000)]), '80'), 1);
assert.equal(slotOf(rankComputes([mem('70', 2000), mem('80', 8000)]), '70'), 2);
assert.equal(rankComputes([mem('70', 1000), mem('80', 1000)]).join(','), '70,80', 'same memory uses name');
assert.equal(rankComputes([mem('70', -1), mem('80', 500)]).join(','), '80,70', 'unknown memory ranks last');
assert.equal(rankNames(['周石润的Mate 70 Pro', '周石润的Mate 60 Pro']).join(','),
  '周石润的Mate 60 Pro,周石润的Mate 70 Pro');
assert.equal(slotOf(rankNames(['B', 'A']), 'A'), 1);
assert.equal(slotOf(rankNames(['B', 'A']), 'B'), 2);
assert.equal(freezeNameRank(['B'], ['A', 'B']).join(','), 'B,A', 'first chat keeps 1 when a second joins');
assert.equal(freezeNameRank(['B', 'A'], ['A']).join(','), 'A', 'dropped chat is removed');
assert.equal(freezeComputeRank(['80', '70'], [mem('80', 100), mem('70', 9000)]).join(','),
  '80,70', 'same members keep the first election');
assert.equal(freezeComputeRank([], [mem('70', 2000), mem('80', 8000)]).join(','), '80,70');
assert.equal(freezeComputeRank(['70'], [mem('70', 2000), mem('80', -1)]).join(','),
  '70', 'unknown peer memory does not reshuffle');
assert.equal(freezeComputeRank([], [mem('70', 2000), mem('80', -1)]).join(','),
  '', 'wait until every compute reports memory');
assert.equal(freezeComputeRank(['70'], []).join(','), '70', 'empty sample does not wipe an elected rank');
assert.equal(freezeComputeRank(['70'], [mem('70', 2000), mem('80', 8000)]).join(','),
  '80,70', 'membership complete elects by memory once');
assert.equal(freezeComputeRank(['80', '70'], [mem('80', 8000)]).join(','), '80', 'leaving peer is dropped');
console.log('PASS: compute rank by free memory, chat rank by name');
