import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

export interface TabletPreferences {
  quickInputs: string[];
  sidebarCollapsed: boolean;
  sidebarWidth: number;
}
const STORE = 'loop_tablet_settings';
export const DEFAULT_QUICK_INPUTS: string[] = ['总结一下当前结果', '列出下一步计划', '帮我分析这个问题'];
export function normalizeTabletPreferences(value: TabletPreferences): TabletPreferences {
  const inputs: string[] = [];
  for (let i = 0; i < 3; i++) {
    inputs.push(Array.isArray(value.quickInputs) && typeof value.quickInputs[i] === 'string' ?
      value.quickInputs[i].substring(0, 4000) : DEFAULT_QUICK_INPUTS[i]);
  }
  return { quickInputs: inputs, sidebarCollapsed: value.sidebarCollapsed === true,
    sidebarWidth: Number.isFinite(value.sidebarWidth) ? Math.max(160, Math.min(300, value.sidebarWidth)) : 200 };
}
export function loadTabletPreferences(context: common.Context): TabletPreferences {
  try {
    const store = preferences.getPreferencesSync(context, { name: STORE });
    return normalizeTabletPreferences(JSON.parse(store.getSync('layout', '{}') as string) as TabletPreferences);
  } catch (_error) { return normalizeTabletPreferences({ quickInputs: DEFAULT_QUICK_INPUTS, sidebarCollapsed: false, sidebarWidth: 200 }); }
}
export async function saveTabletPreferences(context: common.Context, value: TabletPreferences): Promise<void> {
  const store = preferences.getPreferencesSync(context, { name: STORE });
  store.putSync('layout', JSON.stringify(normalizeTabletPreferences(value)));
  await store.flush();
}
