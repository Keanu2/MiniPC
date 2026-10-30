/**
 * 路由算法选择的持久化（照 OutputSettings.ets 的模式）：filesDir 下
 * /router-algorithm.json，读时容错归一（缺文件/损坏/非法名字 → least_load），
 * 写时 temp + rename 原子落盘。路由算法本体零依赖，持久化只在本文件触碰
 * 文件系统（@kit.CoreFileKit 是 router/ 目录内唯一的 kit import）。
 */
import { fileIo } from '@kit.CoreFileKit';
import { knownRouterNames } from './RouterRegistry';

export interface RouterSettings { algorithm: string; }
const SETTINGS_FILE = '/router-algorithm.json';
const DEFAULT_ALGORITHM = 'least_load';

/** Per-device preference; missing/old settings route the least-load algorithm. */
export function routerSettings(filesDir: string): RouterSettings {
  try {
    const saved = JSON.parse(fileIo.readTextSync(filesDir + SETTINGS_FILE)) as RouterSettings;
    const name = typeof saved.algorithm === 'string' ? saved.algorithm : '';
    return { algorithm: knownRouterNames().indexOf(name) >= 0 ? name : DEFAULT_ALGORITHM };
  } catch (_) { return { algorithm: DEFAULT_ALGORITHM }; }
}

export function saveRouterSettings(filesDir: string, settings: RouterSettings): string {
  if (knownRouterNames().indexOf(settings.algorithm) < 0) return '请选择有效的路由算法。';
  try {
    const temp = filesDir + SETTINGS_FILE + '.tmp';
    const file = fileIo.openSync(temp, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
    try { fileIo.writeSync(file.fd, JSON.stringify({ algorithm: settings.algorithm })); }
    finally { fileIo.closeSync(file); }
    fileIo.renameSync(temp, filesDir + SETTINGS_FILE);
    return '';
  } catch (_) { return '路由算法保存失败，请重试。'; }
}
