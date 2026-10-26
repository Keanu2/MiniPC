import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

const CHAT_SETTINGS = 'loop_chat_settings';
const AGENT_ENABLED = 'agent_enabled';
const CHAT_MODE = 'chat_mode';

export type ChatMode = 'chat' | 'agent' | 'agent_split';

// Ordinary chat until the user picks an Agent mode. A saved Agent switch from
// the two-mode build maps to the existing split Agent.
export function loadChatMode(context: common.Context): ChatMode {
  try {
    const store = preferences.getPreferencesSync(context, { name: CHAT_SETTINGS });
    const saved = store.getSync(CHAT_MODE, '') as string;
    if (saved === 'chat' || saved === 'agent' || saved === 'agent_split') {
      return saved;
    }
    return store.getSync(AGENT_ENABLED, false) === true ? 'agent_split' : 'chat';
  } catch (_error) {
    return 'chat';
  }
}

export async function saveChatMode(context: common.Context, mode: ChatMode): Promise<void> {
  const store = preferences.getPreferencesSync(context, { name: CHAT_SETTINGS });
  store.putSync(CHAT_MODE, mode);
  store.putSync(AGENT_ENABLED, mode !== 'chat');
  await store.flush();
}

export function loadAgentEnabled(context: common.Context): boolean {
  return loadChatMode(context) !== 'chat';
}

export async function saveAgentEnabled(context: common.Context, enabled: boolean): Promise<void> {
  await saveChatMode(context, enabled ? 'agent_split' : 'chat');
}
