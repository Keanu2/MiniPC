/*
 * QwenVlManager —— Qwen2.5-VL-3B-NPU 多模态推理管理器（单例）。
 *
 * 由旧版（provide_QwenVL 分支）的 QwenVlCpuManager 移植而来：
 *   - 引擎链路不变：libqwenvl_engine.so（napi_engine.cpp）+ NPU 版 libqwen2vl_sdk.so
 *     + 22 库 libai_runtime 闭包（KirinNPU KNPU 后端），模型目录
 *     filesDir/models/<VL 目录>/ 需含 vl_params + tokenizer.json（VL 布局）；
 *   - 模型发现改用新版 ModelRegistry：vl_params 布局目录即为 VL 模型，
 *     与 ModelConfig（旧版静态表）解耦，能力上报走 manifest/vl_params 缺省；
 *   - 与新版 LocalChat 同契约：start → 80ms 轮询 takeEvents → delta/done 事件流；
 *     cancel 停止；release 卸载引擎释放约 5.3GB 权重。
 */
import engine from 'libqwenvl_engine.so';
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { activeModelDirs, isVlLayout, readinessOf } from './ModelRegistry';

const TAG: string = 'QwenVlManager';
const DOMAIN: number = 0x0004;

/**
 * 本构建是否编入了真 VL 引擎。
 *
 * `libqwenvl_engine.so` 有两条构建分支（真引擎 / 空实现），模块名与导出面完全一致，
 * 所以静态 import 永远成立；靠这个标志把「引擎未编入」和「模型未部署」区分开，
 * 否则私有库缺失时会报出误导性的「引擎启动失败」。
 */
const ENGINE_AVAILABLE: boolean = engine.available === true;

/** 事件轮询周期（ms） */
const POLL_INTERVAL_MS: number = 80;

/** 推理更新回调 */
export interface QwenVlUpdate {
  /** 流式增量文本（Native 已拼齐 UTF-8 字符） */
  delta?: string;
  /** 完整回复文本（生成结束时一次性给出） */
  done?: string;
  /** 错误文案 */
  error?: string;
  /** 结束原因：stop 正常结束 / cancelled 用户停止 / error 引擎错误 */
  finishReason?: string;
  /** 模型加载阶段提示（首次调用加载约 5.3GB 权重，耗时数十秒） */
  loading?: boolean;
}

/** native 事件结构 {"event":"...","payload":"..."} */
class NativeEvent {
  event: string = '';
  payload: string = '';
}

export class QwenVlManager {
  private static instance: QwenVlManager | null = null;

  /** 引擎里是否可能驻留着约 5.3GB 的 VL 权重（start 成功后置 true，release 后置 false）。 */
  private weightsMayBeLoaded: boolean = false;

  private filesDir: string = '';
  /** 已部署 VL 模型目录名（init 时从 ModelRegistry 扫描一次并缓存）；空串=未部署 */
  private vlModelDir: string = '';
  private timer: number = -1;
  private busy: boolean = false;
  private closed: boolean = false;
  private cancelled: boolean = false;
  private answer: string = '';
  private rawAnswer: string = '';
  private emittedLength: number = 0;
  private failure: string = '';
  private finishReason: string = '';
  private callback: ((update: QwenVlUpdate) => void) | null = null;
  /** 本次请求开始时间（看门狗/耗时日志用） */
  private busySince: number = 0;
  /** 上次“忙碌且无事件”日志时间（节流） */
  private lastSilentLog: number = 0;
  /** 本次请求图片路径 / prompt（空输出自动重试用） */
  private lastImagePath: string = '';
  private lastPrompt: string = '';
  /** 空输出自动重试计数（每次 start 清零） */
  private retryCount: number = 0;
  /** 首轮权重加载看门狗上限（ms）：5.3GB 全量读入在低端存储上可能需数分钟 */
  private static readonly LOAD_WATCHDOG_MS: number = 600000;

  private constructor() {
  }

  public static getInstance(): QwenVlManager {
    if (!QwenVlManager.instance) {
      QwenVlManager.instance = new QwenVlManager();
    }
    return QwenVlManager.instance;
  }

  /** 是否有推理正在进行 */
  public isBusy(): boolean {
    return this.busy;
  }

  /** 应用启动时注入沙箱目录（模型部署在 filesDir/models/<VL 目录>/ 下） */
  public init(filesDir: string): void {
    this.filesDir = filesDir;
    this.closed = false;
    this.vlModelDir = this.scanVlModelDir();
    hilog.info(DOMAIN, TAG, 'init, filesDir=%{public}s, vlModel=%{public}s', filesDir,
      this.vlModelDir === '' ? 'NA' : this.vlModelDir);
  }

  /**
   * 门控判定：VL 模型权重已部署且就绪（vl_params + tokenizer.json 可读）。
   * 只有在 true 时 start() 才会真正启动引擎。
   */
  public isModelEnabled(): boolean {
    return this.vlModelDir !== '' && this.readinessError() === '';
  }

  /** 获取已部署 VL 模型目录名（init 时缓存的扫描结果；''=未部署） */
  public getDeployedModelName(): string {
    return this.vlModelDir;
  }

  /** VL 引擎模型目录完整路径（filesDir/models/<vlDir>） */
  public modelPath(): string {
    return this.filesDir + '/models/' + this.vlModelDir;
  }

  /** 就绪检查：返回错误文案，空串=可推理（权重可读） */
  public readinessError(): string {
    if (!ENGINE_AVAILABLE) {
      return '本构建未编入 VL 引擎（私有预编译库未放置，CMake 编的是空实现）';
    }
    if (this.closed || this.filesDir === '') {
      return '模型服务未初始化';
    }
    if (this.vlModelDir === '') {
      return '当前未启用图片模型，请在模型选择中选择已部署的 VL 模型。';
    }
    const missing = readinessOf(this.modelPath());
    if (missing !== '') {
      return `权重文件缺失或不可读：${missing}`;
    }
    return '';
  }

  /** 扫描 VL 模型目录：filesDir/models/ 下就绪且为 VL 布局（vl_params）的目录 */
  private scanVlModelDir(): string {
    if (this.filesDir === '') {
      return '';
    }
    try {
      for (const dir of activeModelDirs(this.filesDir)) {
        const full = this.filesDir + '/models/' + dir;
        if (isVlLayout(full) && readinessOf(full) === '') {
          return dir;
        }
      }
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : 'scan failed';
      hilog.warn(DOMAIN, TAG, 'scanVlModelDir failed: %{public}s', msg);
    }
    return '';
  }

  /**
   * 发起一次 VL 推理（图片 + 文字）。
   * @param imagePath 图片绝对路径（当前 SDK 要求非空且为可读取的图片）
   * @param prompt    用户文字（空时自动补默认描述提示词）
   * @param callback  流式回调（delta/done/error/loading）
   */
  public start(imagePath: string, prompt: string, callback: (update: QwenVlUpdate) => void): boolean {
    if (this.busy) {
      callback({ done: '模型正在处理上一条请求，请稍候重试', error: '模型正在处理上一条请求，请稍候重试' });
      return false;
    }
    // 纯图片（无文字）自动补默认提示词
    if (prompt === '') {
      prompt = '请描述这张图片的内容';
    }
    // 门控：VL 权重未部署/未就绪就不启动引擎
    const gateError = this.readinessError();
    if (gateError !== '') {
      callback({ done: gateError, error: gateError });
      return false;
    }
    let startRet = false;
    try {
      startRet = engine.start(this.modelPath(), imagePath, prompt);
    } catch (e) {
      const emsg: string = e instanceof Error ? (e.message || e.name) : 'engine start error';
      hilog.error(DOMAIN, TAG, 'engine.start threw: %{public}s', emsg);
      callback({ done: '引擎启动异常: ' + emsg, error: '引擎启动异常' });
      return false;
    }
    if (!startRet) {
      callback({ done: '引擎启动失败（可能正在处理上一条请求）', error: '引擎启动失败（可能正在处理上一条请求）' });
      return false;
    }
    this.busy = true;
    this.weightsMayBeLoaded = true;
    this.cancelled = false;
    this.answer = '';
    this.rawAnswer = '';
    this.emittedLength = 0;
    this.failure = '';
    this.finishReason = '';
    this.callback = callback;
    this.lastImagePath = imagePath;
    this.lastPrompt = prompt;
    this.retryCount = 0;
    this.emit({ loading: true });
    this.busySince = Date.now();
    this.lastSilentLog = 0;
    this.startPolling();
    return true;
  }

  /** 停止生成（下个 token 边界生效） */
  public cancel(): void {
    if (!this.busy) {
      return;
    }
    this.cancelled = true;
    engine.cancel();
  }

  /** 卸载引擎，释放约 5.3GB 权重内存；后续 start() 会重新加载 */
  public release(): void {
    engine.complete();
    engine.release();
    this.busy = false;
    this.weightsMayBeLoaded = false;
    this.cleanupTimer();
    this.callback = null;
  }

  /**
   * 任务从「带图」切到「纯文本」前调用：把驻留的 VL 权重（约 5.3GB）卸载掉。
   *
   * 不卸载会与本机文本模型（`Qwen2.5-7B-Instruct-Q4_N_0/params` 约 5.8GB）叠加：
   * 本设备 MemTotal 15.8GB，两者合计约 11.1GB，GEWU 再加载文本模型会触发系统低内存
   * 杀手，应用进程被直接杀掉（真机实测 `LOW_MEMORY_KILL` / `killReason is StabilityCheckKill`）。
   *
   * 反方向（纯文本 → 带图）不需要处理：GEWU 每个任务结束都会 `OH_QoS_GewuDestroySession`
   * 并释放文本模型，真机实测内存回落到 36% 后再加载 VL 引擎正常。
   *
   * 推理进行中（busy）不卸载，避免打断在途请求；从未加载过则不产生调用与日志。
   */
  public unloadIfIdle(): void {
    if (!this.weightsMayBeLoaded || this.busy) {
      return;
    }
    hilog.info(DOMAIN, TAG, 'unload VL weights before a text task (frees ~5.3GB)');
    this.release();
  }

  private startPolling(): void {
    this.cleanupTimer();
    this.timer = setInterval(() => {
      if (!this.busy) {
        this.cleanupTimer();
        return;
      }
      const events: string[] = engine.takeEvents();
      for (const raw of events) {
        this.handleEvent(raw);
      }
      // 忙碌但无事件：首轮 5.3GB 权重加载可能耗时数分钟，节流打印耗时并设看门狗
      if (events.length === 0) {
        const elapsed = Date.now() - this.busySince;
        if (elapsed > QwenVlManager.LOAD_WATCHDOG_MS) {
          hilog.error(DOMAIN, TAG, 'LOAD WATCHDOG: %{public}d s no events, aborting', Math.floor(elapsed / 1000));
          this.failNow(`权重加载超时（${Math.floor(elapsed / 1000)}s），请重启应用后重试`);
          return;
        }
        if (elapsed - this.lastSilentLog > 10000) {
          this.lastSilentLog = elapsed;
          hilog.info(DOMAIN, TAG, 'busy %{public}d s, no events (loading weights...)', Math.floor(elapsed / 1000));
        }
      }
    }, POLL_INTERVAL_MS);
  }

  private handleEvent(raw: string): void {
    if (!this.busy) return;
    let ev: NativeEvent;
    try {
      ev = JSON.parse(raw) as NativeEvent;
    } catch (e) {
      return;
    }
    switch (ev.event) {
      case 'load':
        this.emit({ loading: true });
        break;
      case 'response':
        this.appendAnswer(ev.payload);
        break;
      case 'error':
        this.failNow(ev.payload);
        break;
      case 'end':
        this.finishReason = ev.payload;
        this.finish();
        break;
      default:
        break;
    }
  }

  private emit(update: QwenVlUpdate): void {
    if (this.callback) {
      this.callback(update);
    }
  }

  /** 折叠连续重复片段：native repeat-cut 前 UI 已见最多 7 次重复，
   *  这里把 tail 的连续相同重复 >=3 次折叠为 1 次 + "…（已截断）"。 */
  private collapseTailRepeat(text: string): string {
    if (text.length < 6) {
      return text;
    }
    for (let unit = 1; unit <= 4; unit++) {
      if (text.length < unit * 3) {
        continue;
      }
      const tail = text.substring(text.length - unit);
      let count = 0;
      let pos = text.length;
      while (pos >= unit && text.substring(pos - unit, pos) === tail) {
        count++;
        pos -= unit;
      }
      if (count >= 3) {
        return text.substring(0, pos + unit) + '…（重复内容已自动截断）';
      }
    }
    return text;
  }

  /** Hold a suspect prefix until it can no longer enter the short-output retry.
   * Recompute from raw text so special tokens split across callbacks stay hidden. */
  private appendAnswer(payload: string): void {
    this.rawAnswer += payload;
    this.answer = QwenVlManager.stripSpecialTokens(this.rawAnswer).replace(/\uFFFD/g, '');
    this.publishAnswer(false);
  }

  private publishAnswer(final: boolean): void {
    if ((!final && this.answer.trim().length < 2)) return;
    const delta = this.answer.substring(this.emittedLength);
    if (delta.length === 0) return;
    this.emittedLength = this.answer.length;
    this.emit({ delta: delta });
  }

  /** Incomplete special-token suffixes must wait for the next callback. */
  private static stripSpecialTokens(text: string, final: boolean = false): string {
    let out = text;
    for (;;) {
      const start = out.indexOf('<|');
      if (start < 0) {
        return !final && out.endsWith('<') ? out.substring(0, out.length - 1) : out;
      }
      const end = out.indexOf('|>', start);
      if (end < 0) return out.substring(0, start);
      out = out.substring(0, start) + out.substring(end + 2);
    }
  }

  private finish(): void {
    this.answer = QwenVlManager.stripSpecialTokens(this.rawAnswer, true).replace(/\uFFFD/g, '');
    const empty = this.answer.trim().length === 0;
    const invalidEncoding = this.rawAnswer.length > 0 && this.answer.trim().length === 0 && this.rawAnswer.indexOf('\uFFFD') >= 0;
    // Retry only a normally ended attempt with no published text. A consumer
    // cannot retract deltas already sent over the inference protocol.
    if (!this.failure && !this.cancelled && this.finishReason === 'stop' &&
      (empty || invalidEncoding || this.answer.trim().length < 2) && this.emittedLength === 0 &&
      this.retryCount < 1 && this.lastImagePath !== '' && this.lastPrompt !== '') {
      this.retryCount++;
      hilog.warn(DOMAIN, TAG, 'invalid or short output, auto-retry #%{public}d', this.retryCount);
      this.answer = '';
      this.rawAnswer = '';
      this.finishReason = '';
      try {
        if (engine.start(this.modelPath(), this.lastImagePath, this.lastPrompt) === true) {
          this.busySince = Date.now();
          this.lastSilentLog = 0;
          return;
        }
      } catch (_) {
        // Settle the request below even when the native restart throws.
      }
      this.failure = '模型重新推理失败，请重试';
    }
    if (!this.failure && !this.cancelled) {
      if (!this.finishReason) this.failure = '模型会话已结束，但没有收到结束标记';
      else if (this.finishReason === 'error') this.failure = '模型推理失败，请重试';
      else if (invalidEncoding) this.failure = '模型返回了无效编码，请重试';
      else if (empty) this.failure = '模型没有返回内容，请重试';
    }
    if (!this.failure) this.publishAnswer(true);
    const doneRaw = this.failure || (this.cancelled ?
      (this.answer ? this.answer + '\n\n已停止生成' : '已停止生成') : this.answer);
    const done = this.failure !== '' && this.failure === doneRaw ? doneRaw : this.collapseTailRepeat(doneRaw);
    this.emit({
      done: done,
      error: this.failure !== '' ? this.failure : undefined,
      finishReason: this.cancelled ? 'cancelled' : this.finishReason,
      loading: false
    });
    engine.complete();
    this.callback = null;
    this.busy = false;
    this.cleanupTimer();
  }

  /** 引擎/推理错误：立即以 done+error 结束本次请求 */
  private failNow(message: string): void {
    this.failure = message;
    this.emit({ done: message, error: message });
    try { engine.cancel(); } catch (_) { /* nothing running */ }
    engine.complete();
    this.callback = null;
    this.busy = false;
    this.cleanupTimer();
  }

  private cleanupTimer(): void {
    if (this.timer !== -1) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }
}
