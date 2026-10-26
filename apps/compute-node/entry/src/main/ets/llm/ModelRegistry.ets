import { fileIo } from '@kit.CoreFileKit';
import { CAPABILITY_TAGS } from '../protocol/ChatProtocol';

/**
 * 模型目录登记表：filesDir/models 下所有就绪模型的发现、能力声明与按需选择。
 * 能力来自每个目录的 manifest.json（如 {"capabilities":["text","vision"]}）；
 * 强度档位也来自 manifest.json（"tier": 1-2：1 弱、2 强；缺省/越界按 2 强处理）。
 * 请求类型来自 api_config.json 的 name/type。model-selection.json 保存手动选择；
 * 自动模式合并全部就绪模型的能力，手动模式只上报并执行选定模型。
 * 私有 VL SDK 当前只支持带图请求，因此不会将其上报为文字能力。
 *
 * 档位是质量偏好（fail open）：声明缺失/损坏/越界一律按 2 处理，绝不因此排除
 * 目录或设备。设备级档位取启用目录的最高档——自动模式文本强/视觉弱的设备，重视觉
 * 任务可能被路由过来再本机降档到弱 VL 目录（LocalChat 有 local tier fallback
 * 日志兜底），v1 接受这一不精确。
 */

export interface ModelManifest {
  capabilities?: string[];
  tier?: number;
}

interface ApiConfig {
  name?: string;
  type?: string;
}

const DEFAULT_CAPABILITIES: string[] = ['text'];
/** 文本 GEWU 部署的权重文件集（api_config/params/tokenizer）。 */
const MODEL_FILES: string[] = ['api_config.json', 'params', 'tokenizer.json'];
/** VL 引擎（Qwen2.5-VL-3B-NPU）部署的权重文件集：vl_params + tokenizer.json。 */
const VL_MODEL_FILES: string[] = ['vl_params', 'tokenizer.json'];
/** VL 布局标记文件：存在即按多模态目录处理。 */
const VL_MARK_FILE: string = 'vl_params';
const SCAN_CACHE_MS: number = 1500;

class ScanCache {
  at: number = 0;
  filesDir: string = '';
  dirs: string[] = [];
}

const scanCache: ScanCache = new ScanCache();

export interface ModelSelection {
  model: string;
}

const SELECTION_FILE: string = '/model-selection.json';

/** Empty values keep automatic selection. A missing pinned model never falls back silently. */
export function modelSelection(filesDir: string): ModelSelection {
  try {
    const saved = JSON.parse(fileIo.readTextSync(filesDir + SELECTION_FILE)) as ModelSelection;
    return {
      model: typeof saved.model === 'string' ? saved.model : ''
    };
  } catch (_) { return { model: '' }; }
}

/** Validate before atomically replacing the saved selection. */
export function saveModelSelection(filesDir: string, selection: ModelSelection): string {
  if (selection.model !== '' && readyModelDirs(filesDir).indexOf(selection.model) < 0) {
    return '所选模型不可用，请重新选择。';
  }
  try {
    const temp = filesDir + SELECTION_FILE + '.tmp';
    const file = fileIo.openSync(temp, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
    try { fileIo.writeSync(file.fd, JSON.stringify(selection)); }
    finally { fileIo.closeSync(file); }
    fileIo.renameSync(temp, filesDir + SELECTION_FILE);
    return '';
  } catch (_) { return '模型设置保存失败，请重试。'; }
}

/** Active directories drive execution, telemetry and scheduling through the same selection. */
export function activeModelDirs(filesDir: string): string[] {
  const selection = modelSelection(filesDir);
  return readyModelDirs(filesDir).filter((dir: string): boolean =>
    selection.model === '' || selection.model === dir);
}

/** 目录是否为 VL 布局：存在 vl_params 标记文件即按多模态目录处理。 */
export function isVlLayout(modelDir: string): boolean {
  try {
    const f = fileIo.openSync(modelDir + '/' + VL_MARK_FILE, fileIo.OpenMode.READ_ONLY);
    fileIo.closeSync(f);
    return true;
  } catch (_) { return false; }
}

/** 就绪检查：目录内关键文件均可读且非空；通过返回空串。文件集按布局区分。 */
export function readinessOf(modelDir: string): string {
  const files = isVlLayout(modelDir) ? VL_MODEL_FILES : MODEL_FILES;
  for (const name of files) {
    try {
      const file = fileIo.openSync(modelDir + '/' + name, fileIo.OpenMode.READ_ONLY);
      try {
        if (fileIo.readSync(file.fd, new ArrayBuffer(1)) !== 1) return '模型文件为空：' + name;
      } finally {
        fileIo.closeSync(file);
      }
    } catch (_) { return '模型文件缺失或无法读取：' + name; }
  }
  return '';
}

/**
 * filesDir/models 下所有就绪目录，按名称排序保证确定性。设备信息每 2 秒轮询一次，
 * 结果按 filesDir 短缓存，避免重复探测多个模型目录的文件句柄。
 */
export function readyModelDirs(filesDir: string): string[] {
  if (filesDir.length === 0) return [];
  const now = Date.now();
  if (scanCache.at > 0 && now - scanCache.at < SCAN_CACHE_MS && scanCache.filesDir === filesDir) {
    return scanCache.dirs.slice();
  }
  const dirs: string[] = [];
  try {
    const names = fileIo.listFileSync(filesDir + '/models') as string[];
    for (const name of names) {
      if (typeof name !== 'string' || name.length === 0 || name === '.' || name === '..') continue;
      if (readinessOf(filesDir + '/models/' + name) === '') dirs.push(name);
    }
  } catch (_) {
    return [];
  }
  dirs.sort();
  scanCache.at = now;
  scanCache.filesDir = filesDir;
  scanCache.dirs = dirs.slice();
  return dirs;
}

/** 单个就绪目录声明的能力：清单缺失/损坏 → 缺省（文本布局 ['text']；VL 布局 ['text','vision']，vl_params 本身就是多模态权重标志）；未知标签丢弃、去重。 */
export function manifestCapabilities(filesDir: string, modelDir: string): string[] {
  try {
    const manifest = JSON.parse(fileIo.readTextSync(filesDir + '/models/' + modelDir + '/manifest.json')) as ModelManifest;
    const declared: string[] = manifest.capabilities === undefined ? [] : manifest.capabilities;
    const caps: string[] = [];
    for (const tag of declared) {
      if (typeof tag === 'string' && CAPABILITY_TAGS.indexOf(tag) >= 0 && caps.indexOf(tag) < 0) caps.push(tag);
    }
    return caps.length > 0 ? caps : DEFAULT_CAPABILITIES.slice();
  } catch (_) {
    return isVlLayout(filesDir + '/models/' + modelDir) ? ['text', 'vision'] : DEFAULT_CAPABILITIES.slice();
  }
}

/** 设备级能力只包括启用模型及当前执行通道真正支持的输入类型。 */
export function deviceCapabilities(filesDir: string): string[] {
  const caps: string[] = [];
  for (const dir of activeModelDirs(filesDir)) {
    const vl = isVlLayout(filesDir + '/models/' + dir);
    for (const tag of manifestCapabilities(filesDir, dir)) {
      // The private VL SDK requires an image even though its manifest also declares text.
      if (vl && tag === 'text') continue;
      if (caps.indexOf(tag) < 0) caps.push(tag);
    }
  }
  return caps;
}

/** 单个就绪目录声明的强度档位（1-2）；缺失/损坏/越界 → 2 强档（fail open）。 */
export function manifestTier(filesDir: string, modelDir: string): number {
  try {
    const manifest = JSON.parse(fileIo.readTextSync(filesDir + '/models/' + modelDir + '/manifest.json')) as ModelManifest;
    const tier = manifest.tier;
    return typeof tier === 'number' && Number.isInteger(tier) && tier >= 1 && tier <= 2 ? tier : 2;
  } catch (_) {
    return 2;
  }
}

/** 设备级档位：启用目录的最高档；无启用模型 → 0（上报侧据此省略字段）。 */
export function deviceTier(filesDir: string): number {
  let best = 0;
  for (const dir of activeModelDirs(filesDir)) {
    const tier = manifestTier(filesDir, dir);
    if (tier > best) best = tier;
  }
  return best;
}

function covers(caps: string[], needs: string[]): boolean {
  for (const need of needs) {
    if (caps.indexOf(need) < 0) return false;
  }
  return true;
}

/**
 * 为单次请求选择模型目录：能力覆盖 needs 的就绪目录里按档位贴近选（贴近平手 →
 * 档位就高；仍平手 → 排序首位，保留"首个最优"的旧行为）；needs 为空在非 VL 目录
 * 集里选（VL 目录只服务带图请求，纯文本交给 GEWU probe，绝不发到 VL 权重目录）；
 * 有需求却没有目录能满足时返回空串（fail closed，绝不把请求交给不具备能力的模型）。
 * taskTier = 0（未分类）时取候选目录排序首位；VL 不作为文字引擎兜底。
 */
export function selectModelDir(filesDir: string, needs: string[], taskTier: number = 0): string {
  const dirs = activeModelDirs(filesDir);
  if (dirs.length === 0) return '';
  if (needs.length === 0) {
    const textDirs: string[] = [];
    for (const dir of dirs) {
      if (!isVlLayout(filesDir + '/models/' + dir)) textDirs.push(dir);
    }
    if (textDirs.length === 0) return '';
    return pickTieredDir(filesDir, textDirs, taskTier);
  }
  const capable: string[] = [];
  for (const dir of dirs) {
    if (covers(manifestCapabilities(filesDir, dir), needs)) capable.push(dir);
  }
  if (capable.length === 0) return '';
  return pickTieredDir(filesDir, capable, taskTier);
}

/** 候选目录里选档位最贴近任务的；贴近平手就高不就低，仍平手保留排序首位。 */
function pickTieredDir(filesDir: string, dirs: string[], taskTier: number): string {
  if (taskTier < 1) return dirs[0];
  let best = dirs[0];
  let bestTier = manifestTier(filesDir, best);
  for (let index = 1; index < dirs.length; index++) {
    const tier = manifestTier(filesDir, dirs[index]);
    if (Math.abs(tier - taskTier) < Math.abs(bestTier - taskTier) ||
      (Math.abs(tier - taskTier) === Math.abs(bestTier - taskTier) && tier > bestTier)) {
      best = dirs[index];
      bestTier = tier;
    }
  }
  return best;
}

/** 请求类型：api_config.json 的 name（缺省 type）；读不到回落 'qwen2'。 */
export function modelRequestType(filesDir: string, modelDir: string): string {
  try {
    const config = JSON.parse(fileIo.readTextSync(filesDir + '/models/' + modelDir + '/api_config.json')) as ApiConfig;
    const name = config.name !== undefined ? config.name : config.type;
    return typeof name === 'string' && name.length > 0 ? name : 'qwen2';
  } catch (_) {
    return 'qwen2';
  }
}
