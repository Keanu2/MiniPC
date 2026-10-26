import { fileIo } from '@kit.CoreFileKit';

export interface OutputSettings { streaming: boolean; }
const SETTINGS_FILE = '/inference-output.json';

/** Per-device preference, independent of the selected model. Missing/old settings stream by default. */
export function outputSettings(filesDir: string): OutputSettings {
  try {
    const saved = JSON.parse(fileIo.readTextSync(filesDir + SETTINGS_FILE)) as OutputSettings;
    return { streaming: typeof saved.streaming === 'boolean' ? saved.streaming : true };
  } catch (_) { return { streaming: true }; }
}

export function saveOutputSettings(filesDir: string, settings: OutputSettings): string {
  if (typeof settings.streaming !== 'boolean') return '请选择有效的输出方式。';
  try {
    const temp = filesDir + SETTINGS_FILE + '.tmp';
    const file = fileIo.openSync(temp, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
    try { fileIo.writeSync(file.fd, JSON.stringify({ streaming: settings.streaming })); }
    finally { fileIo.closeSync(file); }
    fileIo.renameSync(temp, filesDir + SETTINGS_FILE);
    return '';
  } catch (_) { return '输出方式保存失败，请重试。'; }
}
