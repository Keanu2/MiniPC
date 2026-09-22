/** 稳定身份键排序工具；算力初选按可用内存，聊天编号由中心按安装 UID 分配。 */

export class RankMember {
  key: string = '';
  memAvail: number = -1;
}

export function freezeComputeRank(previous: string[], members: RankMember[]): string[] {
  const ranked = rankComputes(members);
  if (ranked.length === 0) return previous.slice();
  if (previous.length === ranked.length) {
    let same = true;
    for (const key of previous) {
      if (ranked.indexOf(key) < 0) {
        same = false;
        break;
      }
    }
    if (same) return previous.slice();
  }
  let known = 0;
  for (const item of members) {
    if (item.key.length > 0 && item.memAvail >= 0) known++;
  }
  if (ranked.length > 1 && known < ranked.length) {
    const kept: string[] = [];
    for (const key of previous) {
      if (ranked.indexOf(key) >= 0) kept.push(key);
    }
    return kept.length > 0 ? kept : previous.slice();
  }
  return ranked;
}

export function rankComputes(members: RankMember[]): string[] {
  const copy: RankMember[] = [];
  for (const item of members) {
    if (item.key.length === 0) continue;
    let exists = false;
    for (const seen of copy) {
      if (seen.key === item.key) {
        exists = true;
        if (item.memAvail > seen.memAvail) seen.memAvail = item.memAvail;
        break;
      }
    }
    if (!exists) {
      const next = new RankMember();
      next.key = item.key;
      next.memAvail = item.memAvail;
      copy.push(next);
    }
  }
  copy.sort((left: RankMember, right: RankMember) => {
    const leftMem = left.memAvail < 0 ? -1 : left.memAvail;
    const rightMem = right.memAvail < 0 ? -1 : right.memAvail;
    if (leftMem !== rightMem) return rightMem - leftMem;
    if (left.key < right.key) return -1;
    if (left.key > right.key) return 1;
    return 0;
  });
  const keys: string[] = [];
  for (const item of copy) keys.push(item.key);
  return keys;
}

export function freezeNameRank(previous: string[], names: string[]): string[] {
  const ranked = rankNames(names);
  const kept: string[] = [];
  for (const key of previous) {
    if (ranked.indexOf(key) >= 0 && kept.indexOf(key) < 0) kept.push(key);
  }
  for (const key of ranked) {
    if (kept.indexOf(key) < 0) kept.push(key);
  }
  return kept;
}

export function rankNames(names: string[]): string[] {
  const keys: string[] = [];
  for (const name of names) {
    const trimmed = name.trim();
    if (trimmed.length === 0) continue;
    if (keys.indexOf(trimmed) < 0) keys.push(trimmed);
  }
  keys.sort();
  return keys;
}

export function slotOf(keys: string[], key: string): number {
  if (key.length === 0) return 0;
  const index = keys.indexOf(key);
  return index < 0 ? 0 : index + 1;
}
