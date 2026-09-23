# Demo 代码问题记录（2026-09-21 静态审查）

这是当时的审查底稿，不是现行说明。文内 8 条都已修好，行号对的是审查时的源码。现在的连接、编号和清单规则以仓库 README、[CHANGELOG.md](../CHANGELOG.md) 和 [2026-09-23 多算力审查](multi-compute-membership-review-2026-09-23.md) 为准。

- 日期：2026-09-21（审查）、2026-09-22（修复）
- 范围：`src/chat-end`、`src/model-end` 的 `ets/` 源码与 `peer-chat.html`
- 状态：**8 条全部已修**，见第 12 节「修复记录」；本文前 11 节保留审查当时的原文，行号未回填
- 方法：通读两端源码，与当时的 9 个 `*.test.cjs` 行为断言对照；对可疑路径另写一次性探针脚本复现

> 修复后两端新增/修改的回归测试共 10 个文件全部通过，两端 `assembleHap` 均 BUILD SUCCESSFUL。
> 第 12 节记录每条的实际改法和所加的测试；审查原文里对第 1 条的归因有一处需要更正，也写在那一节。

## 0. 结论摘要

按影响排序，前 4 条值得修；第 5、6 条是明确的缺陷但影响有限；第 7 条是潜伏问题；第 8 条纯属清理。

| # | 问题 | 位置 | 严重度 |
|---|---|---|---|
| 1 | 没有具名设备时，回退连接「任意可信广播」而不是编号1，结果是连上就被踢 | 模型端 `Index.ets:181-185`、两端 `connectToAdvertisers` | 高 |
| 2 | 聊天端 `scanHits` 不取消上一次扫描、也没有 settled 标记，重试三次会互相拆台 | 聊天端 `LinkEnhanceChannel.ets:621-680` | 高 |
| 3 | BLE 广播两次启动都失败后不再重试，且 `refreshAdvertisedSlot` 的前置条件把它永久锁死 | 模型端 `LinkEnhanceChannel.ets:603-635`、`1095-1101` | 中 |
| 4 | 算力端聊天链路断开后没有任何重连调度，只靠 7 秒的组网轮询兜底（而那套逻辑覆盖不到聊天链路） | 模型端 `Index.ets:396-410`、`777-783` | 中 |
| 5 | 聊天端「聊天设备N」的变更通知走的是死分支，编号变化后标题不再更新 | 模型端 `LinkEnhanceChannel.ets:1203-1208`、聊天端 `:787-791` 与 `:796` | 中 |
| 6 | 状态推送与 `deviceInfoSync` 的保护不一致：清单在推理期间停了，状态推送没停 | 模型端 `Index.ets:286-294` 对比 `:841-842` | 低 |
| 7 | 两端 `advComputeKey` 的边界判断用 `>=`，长度顶满时指纹会被判为不存在 | 两端 `LinkEnhanceChannel.ets` 同名函数 | 低（潜伏） |
| 8 | 遗留死代码 / 死配置 | 见第 8 节 | 低 |

另有一条**已排除**的疑点记录在第 9 节，避免后人重复怀疑。

---

## 1. 没有具名设备时，回退路径会连到「非编号1」的算力

**位置**：`src/model-end/entry/src/main/ets/pages/Index.ets:181-185`、`src/model-end/entry/src/main/ets/nearby/LinkEnhanceChannel.ets:671-691`

**代码路径**

```ts
// Index.ets:181-185
if (devices.length === 0) {
  if (!this.channel.hasComputeHits()) throw new Error('未发现算力设备。请打开模型手机并保持近场开启后重试。');
  await this.channel.connectToAdvertisers(operation);   // ← 回退
}
```

回退到的 `connectToAdvertisers` 走 `trustedAdvertiserMacs()`：

```ts
private trustedAdvertiserMacs(): string[] {
  const macs: string[] = [];
  for (const mac of this.advertiserMacs('')) {          // 所有可信广播
    const hit = this.lastHits.find((item: BleHit) => item.mac === mac);
    const name = hit !== undefined ? this.hitName(hit) : '';
    if (this.isTrustedPeer(mac, name)) macs.push(mac);
  }
  return macs;
}
```

`advertiserMacs` 按 rssi 从强到弱排序，**全程没有 `slot === 1` 的过滤**。同一文件里的另一条路径 `computeDevices()`（`:560-597`）同样只做 `namesMatch` 名字匹配，编号2的算力一样会被返回。真正做 hub 过滤的是聊天端才有的 `connectComputes()`，模型端根本没有这个函数。

**触发条件**：`getAvailableDeviceListSync()` 返回的设备里没有任何 `networkId` 非空的条目（超级终端尚未同步、刚重启、蓝牙名未解析）。此时 BLE 扫描仍能看到广播，于是 `hasComputeHits()` 为真、`devices` 为空，直接走回退分支。

**后果**：聊天机连上编号2后，对端的 hello 分支（`LinkEnhanceChannel.ets:1294-1297`）会立刻断开：

```ts
if (IS_SERVER && role === 'chat' && this.selfComputeSlot !== 1) {
  this.drop(peer, '请连接算力设备1。');
  return;
}
```

用户看到的是「连上就被踢」，接着进入 `scheduleReconnect` 的五轮退避，最后提示「连接已中断，请点击"连接"重试」。这与 README「聊天机只连接可信的算力设备1……不会改去连算力设备2」的承诺不符。

**测试覆盖**：`LinkEnhanceChannel.test.cjs` 里没有任何 `connectToAdvertisers` 的断言，这条回退完全没有回归保护。

**修复方向**：让模型端的回退也按 `slot === 1` 过滤（把 `connectComputes()` 那套判断搬过来），或者给 `connectToAdvertisers` 加一个 `requireHub: boolean` 参数。

---

## 2. 聊天端 `scanHits` 不取消上一次扫描，也没有 settled 标记

**位置**：`src/chat-end/entry/src/main/ets/nearby/LinkEnhanceChannel.ets:621-680`

**对比**：算力端同名函数（`LinkEnhanceChannel.ets:836-911`）开头就调 `this.cancelScan()`，并用 `settled` 保证清理只执行一次，注释写明了原因：

> BLEDeviceFind and stopBLEScan are process-global. Finish an older discovery before installing a new listener, especially across a rapid stop/start.

聊天端这两样都没有：

```ts
private scanHits(timeoutMs: number, computeOnly: boolean): Promise<BleHit[]> {
  return new Promise<BleHit[]>((resolve) => {
    const hits: BleHit[] = [];
    ...
    ble.on('BLEDeviceFind', collect);              // 直接覆盖全局监听
    ble.startBLEScan([{ manufactureId: COMPUTE_MANUFACTURE_ID }], options);
    setTimeout(() => {
      try { ble.stopBLEScan(); } catch (_) {}
      try { ble.off('BLEDeviceFind', collect); } catch (_) { ... }
      resolve(computeOnly ? hits.filter((item: BleHit) => item.compute) : hits);
    }, timeoutMs);
  });
}
```

**触发条件**：`prepareCollaboration` 的重试循环（`Index.ets:125-143`）最多调用 3 次 `computeDevices()`，每次内部都会 `await this.scanHits(COMPUTE_SCAN_MS, true)`，也就是 4.5 秒一轮。第一轮的 `setTimeout` 到点后会执行 `stopBLEScan()` 和 `ble.off('BLEDeviceFind', collect)`——而 `ble.off` 拆的是**全局**监听，会把正在进行中的第二轮扫描一起拆掉；第二轮的 `ble.on` 又覆盖了第一轮的注册，两者互相干扰。

**后果**：重试轮次越靠后，拿到的 `hits` 越可能为空，`advertisedComputes()` 返回空，最终抛「算力设备1尚未确定或不可用」。用户看到的是三次重试全部失败，但 BLE 里其实一直有广播在发。

**修复方向**：把算力端的 `scanCancel` + `settled` 逻辑原样搬到聊天端。这两个函数本来就该保持一致，目前已经漂移了。

---

## 3. BLE 广播启动失败后不再重试，且被 `refreshAdvertisedSlot` 永久锁死

**位置**：`src/model-end/entry/src/main/ets/nearby/LinkEnhanceChannel.ets:603-635`、`1095-1101`

```ts
private advertise(): void {
  if (this.advertising) return;
  try { ble.stopAdvertising(); } catch (_) {}
  ...
  try {
    ble.startAdvertising(setting, adv, response);   // 带名字
    this.advertising = true;
    this.lastAdvertisedSlot = this.selfComputeSlot;
  } catch (first) {
    try {
      ble.startAdvertising(setting, adv);           // 去掉名字的兜底
      this.advertising = true;
      this.lastAdvertisedSlot = this.selfComputeSlot;
    } catch (error) {
      hilog.warn(0, 'NearbyChat', 'le-adv failed code=%{public}s', String((error as BusinessError).code));
      // ← 两次都失败：不重试、不置 advertising、不通知上层
    }
  }
}
```

看似有自愈机会，`refreshAdvertisedSlot()` 会在编号变化时重新进入 `advertise()`：

```ts
private refreshAdvertisedSlot(): void {
  if (!IS_SERVER || this.server === null || !this.advertising || this.activeJobs > 0 ||
    this.lastAdvertisedSlot === this.selfComputeSlot) return;
```

但前置条件里的 `!this.advertising` 会在失败后直接 return——**广播失败意味着 `advertising` 永远为 false，这个函数从此再也进不去**。唯一的调用者是 `applyComputeSlots`、`scheduleAdvertise` 和 `setActiveJobs(0)`，三条路径都被同一个条件挡住。

顺带一提，`lastAdvertisedSlot` 只在成功分支赋值，所以它还停留在旧值（`disconnect()` 里重置为 `-1`，其余时刻是上一次成功广播的编号）。

**触发条件**：开机瞬间第一次 `startAdvertising` 撞上系统蓝牙未就绪或被其他应用占用，两次都抛。

**后果**：这台算力机既不广播也不重试，聊天端永远扫不到它，两端界面都没有任何提示，只能从 hilog 的 `le-adv failed` 看出来。属于「静默失效」。

**修复方向**：失败时按 `SERVER_RESTART_DELAYS` 那种退避重试，或至少把失败状态回传给页面并显示。

---

## 4. 算力端聊天链路断开后没有任何重连调度

**位置**：`src/model-end/entry/src/main/ets/pages/Index.ets:396-410`、`777-783`

```ts
private connectionChanged(connected: boolean, epoch: number): void {
  hilog.info(0, 'NearbyChat', 'connection=...');
  if (this.channel.isConnected()) this.connectionError = '';
  if (!IS_SERVER && !connected) this.serviceReady = false;
  if (IS_SERVER) {
    const dropped = !this.channel.hasEpoch(epoch);
    this.cancelDroppedPeers();
    if (dropped || connected) this.pollDeviceInfo();
  }
  else if (!connected && this.activeId) {
    this.finish(this.answer + (this.answer ? '\n\n' : '') + '连接已中断，请连接后重新发送。', true);
  }
  this.showConnection();
}
```

聊天端在同一位置有 `scheduleReconnect()`（`Index.ets:174-192`），带 `reconnectAttempt` 上限和最终文案。算力端这个分支只做状态清理，**没有重连调度**。

唯一可能兜底的是 `startMeshRetry()`：

```ts
private startMeshRetry(): void {
  if (this.meshTimer !== -1) return;
  this.meshTimer = setInterval(() => {
    if (!this.serviceReady) return;
    this.channel.connectOtherComputes(this.channel.operation()).catch(() => {});
  }, 7000);
}
```

但 `connectOtherComputes` 开头就有多个 early return：

```ts
if (!IS_SERVER || this.meshBusy || this.activeJobs > 0 ||
  this.peers.some((peer: Peer) => peer.ready && peer.role === 'chat')) return;
if (this.selfComputeSlot > 1 && this.peers.some((peer: Peer) =>
  peer.ready && peer.role === 'compute' && peer.computeSlot === 1)) return;
```

这是**算力节点互连**的发现逻辑，面向的是广播里带编号的同类节点。聊天机不广播、地址又是随机的，算力端手里没有任何可拨的句柄，所以这段代码在结构上就不可能恢复聊天链路。

**结论**：这一条严格说是「缺失能力」而不是算错，但值得明确写下来——因为界面上「停用近场 / 启用近场」的开关暗示了算力端能主动恢复，而实际恢复能力完全在聊天端的五轮退避上。配合第 1 条会叠乘：聊天端退避耗尽后提示手动点「连接」，此时若设备列表恰好为空，又会走进第 1 条的错误回退。

**修复方向**：要么在算力端给出可见的等待文案与倒计时，要么在 README 里明确「聊天链路只能由聊天端发起」。

---

## 5. 聊天端「聊天设备N」的变更通知走的是死分支

**位置**：模型端 `LinkEnhanceChannel.ets:1203-1208`（发送方）与聊天端 `:765-796`（接收判断）

算力端在聊天编号变化时会补发一条 `hello_ack`：

```ts
private pushChatSlot(peer: Peer): void {
  if (!this.holds(peer) || peer.role !== 'chat' || peer.slot < 1) return;
  this.write(peer, {
    type: 'hello_ack', peerRole: 'compute', name: this.localName(), slot: peer.slot, deviceUid: this.localUid()
  });
}
```

调用点在 `refreshChatSlots()`（`:1196-1199`），条件是 `if (peer.ready) this.pushChatSlot(peer)`——**只对已就绪的 peer 发**。

聊天端的 `receive()` 结构如下（`:765-796`）：

```ts
if (!peer.ready) {
  if (IS_SERVER && message.type === 'hello' && !peer.hello) { ... }
  else if (!IS_SERVER && message.type === 'hello_ack' && peer.opened) { ... }  // 分支 A，要求 !ready
  else { this.drop(peer, '对端不是兼容的聊天应用。'); }
  return;
}
if (!IS_SERVER && message.type === 'hello_ack') {                              // 分支 B
  if (typeof message.slot === 'number' && message.slot >= 1) this.selfSlot = Math.floor(message.slot);
  this.onConnection?.(true, peer.epoch);
  return;
}
...
const allowed = IS_SERVER ? [...] : ['delta', 'done', 'error', 'deviceInfo', 'deviceInfoSync'];  // :796
if (!allowed.includes(message.type) || this.onMessage === null) { ... return; }
```

- 从算力端发来的补发通知，到达时 `peer.ready` 已经为真，分支 A 不会走；接着**分支 B 虽然存在，但被它后面的 `allowed` 白名单拦住**——`hello_ack` 不在名单里。两段代码的顺序说明分支 B 是后来加的，白名单没跟着更新。
- `selfSlot` 的二次更新因此永远不执行，`selfLabel()` 返回的仍是旧编号。

**后果**：聊天设备编号变化（比如另一台聊天机加入、或一台退出导致重排）后，聊天端标题会停留在旧编号，直到用户手动断开重连。属于显示问题，不影响消息路由。

**附**：模型端 `LinkEnhanceChannel` 自己的 `selfSlot`（`:227`）只在 `!IS_SERVER` 时被写（`:1311`），而模型端 `IS_SERVER === true`，所以 `selfLabel()`（`:317-323`）里的聊天分支是纯粹的死代码。

---

## 6. 清单同步停了，状态推送没停

**位置**：`src/model-end/entry/src/main/ets/pages/Index.ets:286-294`，对比 `:841-842`

`pollDeviceInfo` 里对清单有一道明确的保护：

```ts
// 836-843
for (const peer of peers) {
  if (!peer.ready) continue;
  if (peer.role !== 'compute') continue;
  // Streaming inference has priority over background topology refresh.
  if (this.jobs.length > 0) continue;
```

但同样在推理期间触发的状态推送没有这道保护：

```ts
// 285-294
const runningNow = this.jobs.filter((job: ActiveJob) => job.workerEpoch === 0).length;
if (this.serviceReady && runningNow !== this.lastPublishedRunning) {
  const previousRunning = this.lastPublishedRunning;
  this.lastPublishedRunning = runningNow;
  const status = toDeviceInfoReply('status-' + String(Date.now()), this.clusterSelfEntry());
  for (const peer of this.channel.peerInfos()) {
    if (peer.ready && peer.role === 'compute') this.channel.send(status, peer.epoch);
  }
```

peer 过滤（`role === 'compute'`）是正确的，**问题只在时机**：`emitDashboard()` 在每次流式 delta 上都会跑，而 `runningNow` 在任务开始和结束时各变一次，所以实际只在两个瞬间发送，频率可控。单帧包也很小。

**为什么仍然记下来**：文档第 13 节确立的规则是「推理期间暂停后台同步，降低无线争用」，而这里留了一个没对齐的口子。要么补上 `this.jobs.length > 0` 的判断，要么把「推理期间允许发状态、不允许发清单」的原因写进设计说明——现状是规则不明确，后人很难判断这是疏漏还是有意为之。

---

## 7. `advComputeKey` 的边界判断差一个 `=`（两端一致，一起错）

**位置**：聊天端 `LinkEnhanceChannel.ets:121-133`、模型端 `LinkEnhanceChannel.ets:148-160`

两处实现**逐字节相同**：

```ts
function advComputeKey(data: ArrayBuffer): string {
  const at = advComputeOffset(data);
  if (at < 0) return '';
  const bytes = new Uint8Array(data);
  if (at + 1 + COMPUTE_ADV_KEY_BYTES >= bytes.length) return '';   // ← 用 >=
  ...
}
```

`at` 指向 payload 起始（type 字节），密钥从 `at + 2` 开始读 `KEY_BYTES` 个字节，所以最后一个有效下标是 `at + 1 + KEY_BYTES`，用 `>=` 会把它排除掉——**密钥正好顶到包尾的广播会被判为「没有指纹」**。

当前 `computeManufacture`（`:97-107`）生成的 payload 是 2 + 4 = 6 字节，而 `advComputeOffset` 返回的位置之后通常还有别的 AD 结构，所以现阶段不会命中这个边界。

**后果**：一旦 `COMPUTE_ADV_KEY_BYTES` 调大，或者将来在制造商数据后面不再追加别的字段，两台设备就会对同一个包得到不同的解析结果，退化成按随机 MAC 去重——也就是文档第 1 节记录过的「同一台设备显示两遍」。

**修复方向**：改成 `>`，或写成 `at + 2 + COMPUTE_ADV_KEY_BYTES > bytes.length` 让意图更直白。两端要一起改。

---

## 8. 遗留死代码 / 死配置

都不是功能错误，但会误导后续维护：

| 项 | 位置 | 说明 |
|---|---|---|
| `ComputeRouter.dropOrigin` | `cluster/ComputeRouter.ets:179-192` | 无任何调用方。清理 peer 用的是 `dropWorker`。 |
| `ComputeRouter.dropWorkerIds` | `cluster/ComputeRouter.ets:172-177` | 无任何调用方。 |
| `CHAT_MESH_WAIT_MS` | 聊天端 `nearby/NearbyConfig.ets:9` | 定义后从未使用；README 里「最多等约 8 秒」的实现在别处。 |
| `advMarksCompute` | 两端 `LinkEnhanceChannel.ets:109` | 无调用方。 |
| `NearbyChannel.ets` 残留 | 根 README 仍写着「`NearbyChannel` 还留着，已经不走它传数据」 | 工作区已删除这两个文件（`git status` 显示 `D`），文档未同步。 |
| `DEVICE_INFO_POLL_MS: 3000` | 两端 `IndexFocus.test.cjs` 的 mock | 真实值是 5000，测试替身没跟上。 |
| `emit({ kind: 'remote-start', text: ... })` | 模型端 `Index.ets:582` | HTML 只对 `remote-start` 调 `updateButton()`（`peer-chat.html:293`），`event.text` 从未被使用。 |
| `formatComputeStatus` / `deployedModelName` | 两端 `cluster/DeviceInfo.ets` | 未见真实调用方（仅出现在测试 mock 里）。 |

---

## 9. 已排除的疑点（不要重复怀疑）

**分片把多字节字符切成两半，会不会损坏文本？**

`encodeMessage` 按 480 **字节**切片（`protocol/ChatProtocol.ets:140-147`），中间片的末尾可能是某个 UTF-8 字符的前几个字节。怀疑点是：这样切出来的 base64 各自解码后是不是能在对端正确还原。

实测结论：**不会**。切片是在**编码后的字节序列**上做的，`MessageAssembler.receive` 把所有片收齐后拼回 `Uint8Array`，最后才整体做一次 `TextDecoder(fatal)` 解码（`:202-208`）。用「477 个 ASCII 字符 + `你好世界`」构造跨界用例，重组字节与原始 JSON **逐字节相等**，解码不抛错，还原文本与输入完全一致。

两端 `ChatProtocol.ets` 用 `diff` 比对无差异，不存在「一端按字符、一端按字节」的错配。

**顺带确认**：`encodeMessage` 的 `count = Math.ceil(bytes.length / CHUNK_BYTES)` 在空消息时得 0，但 `validMessage` 早已拦住空 `messages`，不会产生零片消息。

---

## 10. 验证方式

- 两端共 9 个 `*.test.cjs` 全部通过（`node <file>`，TypeScript 由 `src/tests/harness.cjs` 自动定位到 `D:\command-line-tools\hvigor\hvigor\node_modules\typescript\lib\typescript.js`）。
- 第 1、2、4 条通过阅读两份 `LinkEnhanceChannel.ets` / `Index.ets` 的对应函数并做文本级比对确认；第 9 条通过一次性探针脚本（编解码往返 + 逐字节比对）确认排除。
- 第 3、5、6、7 条为源码直接定位，报告中的行号均已用 `sed -n` 复核。
- 未构造运行时复现的条目，都在正文里注明了「触发条件」，便于在真机上定向验证。

## 11. 本次审查没有覆盖的地方

- 真机行为：BLE 广播时长、`linkEnhance` 的实际断开原因码、系统蓝牙栈行为，只能在设备上复现。
- `cpp/` 下的 `gewu_probe` 原生实现，本次只看了 ArkTS 侧的调用约定。
- 两端 `EntryAbility` 的生命周期与窗口尺寸设置。
- `module.json5` 的权限声明与 `supportWindowMode` 组合。

---

## 12. 修复记录（2026-09-22）

8 条全部处理。验证：10 个 `*.test.cjs` 全部通过，两端 `assembleHap` 均 `BUILD SUCCESSFUL`（模型端为 `clean` 全量构建，聊天端为增量构建）。

### 先更正第 1 条的归因

原文说「模型端的回退会连到编号2」。**模型端那一侧其实永远不会走这条路**：`connectToAdvertisers()` 开头就是 `if (IS_SERVER || this.peers.length > 0) return`，而模型端 `IS_SERVER === true`，所以在算力端它是一段死代码。

真正会执行的是**聊天端**的同名方法——聊天端 `pages/Index.ets` 只在 `computeDevices()` 返回空、`hasComputeHits()` 为真的分支里调它。也就是说，这个「连上就被踢」的路径确实存在，只是触发端写反了。两端的 `connectToAdvertisers()` 现在用同一套 hub 过滤。

### 逐条改法

| # | 改法 | 位置 |
|---|---|---|
| 1 | 新增 `connectComputes()`（模型端）/ `hubAdvertiserMacs()`（聊天端）作为**唯一**的拨号候选来源，按 `slot === 1` 过滤；两端 `connectToAdvertisers()` 改用它，失败文案改成「算力设备1尚未确定或不可用」 | 两端 `nearby/LinkEnhanceChannel.ets` |
| 2 | 聊天端 `scanHits` 补上 `cancelScan()` + `settled` 标记 + 失败路径走 `finish()`，与模型端逐行对齐；`disconnect()` 里也 `cancelScan()` | `src/chat-end/.../nearby/LinkEnhanceChannel.ets` |
| 3 | 新增 `ADVERTISE_RETRY_DELAYS` 退避重试（1/3/8/20/30 秒）与 `scheduleAdvertiseRetry()`；`startServer()` 在服务器就绪后补一次调度；`disconnect()` 取消定时器并清零计数。重试只碰广播，不动服务器和在途链路 | `src/model-end/.../nearby/LinkEnhanceChannel.ets` |
| 4 | 断开聊天链路且本机已无对端时，把提示写进 `connectionError`：「聊天手机已断开，等待它自动重连…」，说明恢复责任在聊天端 | `src/model-end/.../pages/Index.ets` |
| 5 | 聊天端 `receive()` 的 `hello_ack` 分支移到 `!peer.ready` 判断之外（本来就在），并修正它被 `allowed` 白名单挡住的问题——该分支在首页白名单检查之前返回，现在只有 `slot` 真的变化才打日志、固定回调 `onConnection` | `src/chat-end/.../nearby/LinkEnhanceChannel.ets` |
| 6 | 状态推送加上与清单相同的 `this.jobs.length === 0` 条件；`lastPublishedRunning` 保持「上次真正发布的值」，任务结束后的下一次 `emitDashboard` 自然补发 | `src/model-end/.../pages/Index.ets` |
| 7 | 两端 `advComputeKey` 的边界判断改为 `at + 2 + KEY_BYTES > bytes.length`，并写明最后一个 key 字节的下标 | 两端 `nearby/LinkEnhanceChannel.ets` |
| 8 | 删除 `ComputeRouter.dropOrigin` / `dropWorkerIds`、两端 `advMarksCompute`、聊天端 `CHAT_MESH_WAIT_MS`、聊天端无人调用的 `trustedAdvertiserMacs`；`README.md` 删掉「`NearbyChannel` 还留着」；模型端 `IndexFocus.test.cjs` 的 `DEVICE_INFO_POLL_MS` 替身从 3000 改成 5000 | 多处 |

### 顺手修掉的相邻问题

修复第 8 条时发现模型端任务栏有个真问题：`emit({ kind: 'text' })` **带着 `requestId` 发出去，但 HTML 没有处理 `text` 分支**，任务卡只能靠 5 秒一次的 dashboard 轮询刷新，流式回复看起来是跳着走的。现在：

- `peer-chat.html` 新增 `patchJob(requestId, text, isError, finished)`，`text` 事件即时改写对应卡片，`done` 事件把卡片置为已完成；对不在板上的 requestId 不做任何事。
- 模型端 `Index.ets` 新增 `webActiveId`：每张卡片只在自己是「当前流」时收到 `text` 事件，多个聊天机并发时不会互相串文本。

### 新增/加强的测试

- **`src/chat-end/.../nearby/LinkEnhanceChannel.test.cjs`（新增文件）**：聊天端此前**没有**通道测试，这正是扫描窗口能悄悄漂移的原因。现在覆盖两件事——
  - 重叠扫描：radio 替身按真实语义「同一时刻只接受一次扫描」，第二轮的 `computeDevices()` 必须仍然看得到广播。**已验证**：把 `this.cancelScan()` 删掉，这条会失败（`0 !== 1`）。
  - 在线改号：链路 ready 之后收到 `hello_ack {slot:3}`，`selfLabel()` 必须变成「聊天设备3」。**已验证**：把该分支短路掉，这条会失败。
- **模型端 `LinkEnhanceChannel.test.cjs`**：新增 hub 候选过滤（编号2 信号更强时仍只选编号1）、广播被拒后的退避重试、以及 key 正好顶到包尾时仍能读出指纹 / 少一个字节则读不出。
- **模型端 `IndexFocus.test.cjs`**：新增「推理期间不发状态推送、结束后补发」与「聊天链路断开时提示由聊天端重连」；HTML 部分新增流式 `text`/`done` 即时改写卡片、以及未知 requestId 不污染面板。
- 全部 10 个测试文件通过。

### 仍然没有覆盖的

- 上面所有验证都是离线替身。**真机仍需要复测**：仲裁窗口内的接管、编号2 被拨号、广播失败后的自动恢复、以及五秒状态推送是否真的不再和流式回复抢无线。
- 修复第 5 条时确认：聊天端编号变化的显示依赖 `hello_ack`，而算力端只在 `refreshChatSlots()` 里对**已就绪**的 peer 补发。这条路径现在通了，但没有真机验证「第二台聊天机加入导致重排」的实际表现。
