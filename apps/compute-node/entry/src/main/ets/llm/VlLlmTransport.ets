/*
 * VlLlmTransport —— LlmTransport 实现：本地 Qwen2.5-VL-3B-NPU 多模态引擎。
 *
 * 由旧版 CpuVlLlmTransport 移植，适配新版管线差异：
 *   - 图片入参：新版协议/UI 在管线内全程传裸 base64（无 data: 前缀），
 *     本层统一处理三种形态：裸 base64 / data:image 前缀的 dataUrl / 绝对路径；
 *   - 模型目录与就绪门控来自 QwenVlManager（底层挂 ModelRegistry 的 VL 发现），
 *     不再依赖旧版 ModelConfig 静态表；
 *   - 纯文本对话不进入本通道（新版纯文本仍走 GEWU 文本引擎）；
 *     带图请求（含远端转发到本机的）在这里解码落地后交给 VL 引擎。
 *
 * 说明：qwen2vl_sdk 底层为 KirinNPU KNPU 后端（libai_runtime 链 22 库闭包随 HAP
 * 打包），溯源标签据此标注。
 */
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ChatMessage, ChatUpdate } from './LocalChat';
import { LlmTransport } from './LlmTransport';
import { QwenVlManager, QwenVlUpdate } from './QwenVlManager';
import { outputSettings } from './OutputSettings';

const TAG: string = 'VlLlmTransport';
const DOMAIN: number = 0x0005;

/** done 文本溯源标注（可设 '' 关闭） */
const SOURCE_TAG: string = '本机·Qwen2.5-VL-3B-NPU(NPU)';

/** 裸 base64 判定：与协议 image 校验一致（仅 base64 字母表 + 尾部 padding） */
const BASE64_RE = /^[A-Za-z0-9+/]+={0,2}$/;

/**
 * 把上行 user 段清洗成 VL 引擎能直接用的提问。
 *
 * 两条上行的 user 段格式不同：
 *   - nearby-chat `request`：就是用户原话（可能以「（附图）」开头）；
 *   - infer `infer.request`：聊天端发的是 **ReAct 分段**，user 段形如
 *     `User task:\n（附图）<问题>\n\n\nControl: Current`（带脚手架）。
 *
 * 残留 `User task:` / `Control:` 会让 3B 模型试图按该框架"续写"，输出
 * `Action: {乱码}<|im_end|>`、`2<|im_end|>` 这类垃圾，而引擎仍报 rc=0
 * （真机实测：P3 之后 4 次带图请求 1 次侥幸正常、3 次垃圾）。
 * 本函数对没有这些标记的输入是 no-op，因此对旧通路完全向后兼容。
 */
export function cleanVlPrompt(raw: string): string {
  let text = raw;
  const task = text.indexOf('User task:');
  if (task >= 0) {
    text = text.substring(task + 'User task:'.length);
  }
  const control = controlLineAt(text);
  if (control >= 0) {
    text = text.substring(0, control);
  }
  text = text.trim();
  if (text.startsWith('（附图）')) {
    text = text.substring(4).trim();
  }
  return text;
}

/**
 * 找 **独占一行** 的 `Control:`（行首或字符串开头）。
 *
 * 不能直接 `indexOf('Control:')`：用户问题里出现该词时会被误截断
 * （例如「这个 Control: 是什么意思」）。ReAct 的 Control 组永远行首独占一行。
 */
function controlLineAt(text: string): number {
  let from = 0;
  for (;;) {
    const at = text.indexOf('Control:', from);
    if (at < 0) {
      return -1;
    }
    if (at === 0 || text.charAt(at - 1) === '\n') {
      return at;
    }
    from = at + 1;
  }
}

export class VlLlmTransport implements LlmTransport {
  private streaming: boolean = true;
  private cacheDir: string;
  private filesDir: string;
  private vlm: QwenVlManager;
  private callback: ((update: ChatUpdate) => void) | null = null;

  constructor(cacheDir: string, filesDir: string) {
    this.cacheDir = cacheDir;
    this.filesDir = filesDir;
    this.vlm = QwenVlManager.getInstance();
  }

  readinessError(): string {
    return this.vlm.readinessError();
  }

  isBusy(): boolean {
    return this.vlm.isBusy();
  }

  start(messages: ChatMessage[], callback: (update: ChatUpdate) => void, _requestId?: string,
    image?: string): string {
    const error = this.vlm.readinessError();
    if (error !== '') {
      return error;
    }
    const prompt = this.buildPrompt(messages);
    const imagePath = this.resolveImagePath(image);
    this.diagLine(`resolve: imgArgLen=${image === undefined ? -1 : image.length} ` +
      `head=${image === undefined ? '(none)' : image.substring(0, 40)} -> path=${imagePath}`);
    if (imagePath === '') {
      return '图片写入缓存失败，请重试。';
    }
    this.callback = callback;
    this.streaming = outputSettings(this.filesDir).streaming;
    const ok = this.vlm.start(imagePath, prompt, (u: QwenVlUpdate) => this.toChatUpdate(u));
    if (!ok) {
      this.callback = null;
      return '引擎启动失败（可能正在处理上一条请求）';
    }
    return '';
  }

  cancel(_requestId?: string): void {
    this.vlm.cancel();
  }

  /** 解析图片入参：dataUrl / 裸 base64 → 临时文件；绝对路径直接使用（测试/内部调用）。
   *  注意：JPEG 裸 base64 以 "/9j/..." 开头（含 '/'），绝不能误判为路径，
   *  因此"像路径"判断必须在 base64 判定之后。 */
  private resolveImagePath(image: string | undefined): string {
    if (image === undefined || image.length === 0) {
      return '';
    }
    if (image.startsWith('data:image/')) {
      const written = this.dataUrlToFile(image);
      if (written !== '') {
        return written;
      }
      hilog.error(DOMAIN, TAG, 'dataUrl decode failed');
      return '';
    }
    if (this.isBareBase64(image)) {
      // 裸 base64（新版管线）：包成 dataUrl 再走解码落盘
      const written = this.dataUrlToFile('data:image/jpeg;base64,' + image);
      if (written !== '') {
        return written;
      }
      hilog.error(DOMAIN, TAG, 'raw base64 decode failed');
      return '';
    }
    return image; // 绝对路径直接使用（测试/内部调用）
  }

  /** 裸 base64 判定：整串匹配 base64 字母表，且不含 '.' 与 ':'（真实文件路径必含其一：
   *  扩展名/目录点段 .、或 storage 前缀冒号）。因此 "/9j/4AAQ...（JPEG base64）" 归为
   *  base64，而 "/data/storage/.../qwenvl_1.jpg" 归为绝对路径。 */
  private isBareBase64(image: string): boolean {
    return image.indexOf('.') < 0 && image.indexOf(':') < 0 && BASE64_RE.test(image);
  }

  /** 追加诊断到独立 ETS diag 文件（bundle cache，可直接 adb cat；不碰 native preflight） */
  private diagLine(line: string): void {
    const fixed: string = '/data/storage/el2/base/cache';
    const path = `${fixed}/qwenvl_ets.txt`;
    try {
      let prev = '';
      try {
        const r = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
        try {
          const buf = new ArrayBuffer(4096);
          const rn = fileIo.readSync(r.fd, buf);
          prev = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(buf, 0, rn)).slice(-3000);
        } finally {
          fileIo.closeSync(r);
        }
      } catch (e) {
        // 文件不存在，从空开始
      }
      const w = fileIo.openSync(path, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      try {
        const bytes = util.TextEncoder.create('utf-8').encodeInto(`${prev}[ETS] ${line}\n`);
        fileIo.writeSync(w.fd, bytes.buffer);
      } finally {
        fileIo.closeSync(w);
      }
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'diagLine failed: %{public}s cacheDir=%{public}s', line, this.cacheDir);
    }
  }

  /** 解码 base64 dataUrl 写临时 jpg，返回路径；失败返回 ''。
   *  注意：落盘目录固定用 `/data/storage/el2/base/cache`（与 native preflight 相同）：
   *  实测部分机型 `context.cacheDir`（haps/entry/cache）不可写，推入的图片会全部
   *  落盘失败导致引擎拿到空路径卡死（线上 "stbi_load failed"/"一直正在生成" 根因之二）。 */
  private dataUrlToFile(dataUrl: string): string {
    try {
      const comma = dataUrl.indexOf(',');
      if (comma < 0) {
        this.diagLine('dataUrlToFile: no comma');
        return '';
      }
      const base64 = dataUrl.substring(comma + 1);
      const bytes = new util.Base64Helper().decodeSync(base64);
      this.diagLine(`dataUrlToFile: decoded ${bytes.byteLength} B`);
      const dir = '/data/storage/el2/base/cache';
      try {
        fileIo.mkdirSync(dir, true);
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'mkdir cache failed: %{public}s',
          e instanceof Error ? e.message : 'unknown');
      }
      const path = `${dir}/qwenvl_${Date.now()}.jpg`;
      const file = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE
        | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(file.fd, bytes.buffer);
      } finally {
        fileIo.closeSync(file);
      }
      hilog.info(DOMAIN, TAG, 'image written to %{public}s (%{public}d B)', path, bytes.byteLength);
      this.diagLine(`dataUrlToFile: wrote ${path} (${bytes.byteLength} B)`);
      return path;
    } catch (e) {
      const emsg = e instanceof Error ? e.message : 'unknown';
      hilog.error(DOMAIN, TAG, 'dataUrlToFile failed: %{public}s', emsg);
      this.diagLine(`dataUrlToFile FAILED: ${emsg}`);
      return '';
    }
  }

  /** prompt 取最后一条 user 消息，并剥掉推理链路的脚手架（见 cleanVlPrompt）。 */
  private buildPrompt(messages: ChatMessage[]): string {
    for (let i = messages.length - 1; i >= 0; i--) {
      if (messages[i].role === 'user') {
        return cleanVlPrompt(messages[i].content || '');
      }
    }
    return '';
  }

  /** QwenVlUpdate → ChatUpdate */
  private toChatUpdate(u: QwenVlUpdate): void {
    if (u.loading) {
      // 加载提示：无 loading 事件，忽略（web UI 侧 busy 态已覆盖）
      return;
    }
    const cb = this.callback;
    if (cb === null) {
      return;
    }
    if (u.delta !== undefined) {
      if (this.streaming) cb({ kind: 'delta', text: u.delta, metrics: { streaming: true } });
      return;
    }
    if (u.done !== undefined) {
      if (!this.streaming && !u.error && u.done.length > 0) {
        cb({ kind: 'delta', text: u.done, metrics: { streaming: false } });
      }
      const text = u.error !== undefined && u.error.length > 0 ? u.done :
        (u.done + (SOURCE_TAG.length > 0 && u.done.length > 0 ? `\n\n${SOURCE_TAG}` : ''));
      const update: ChatUpdate = { kind: 'done', text: text, metrics: { streaming: this.streaming } };
      if (u.error !== undefined) {
        update.error = u.error;
      }
      update.finishReason = u.finishReason;
      this.callback = null;
      cb(update);
    }
  }
}
