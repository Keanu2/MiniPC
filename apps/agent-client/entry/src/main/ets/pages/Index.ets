import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import fs from '@ohos.file.fs';
import window from '@ohos.window';
import {
  AgentEvent,
  AgentEventKind,
  buildLocalCollaborationInfo,
  buildLocalSessionAttributes,
  clearStoredConversation,
  ClusterSize,
  ConversationContext,
  ConversationRole,
  createConfiguredLoopToolRegistry,
  createLoopModelInfo,
  createSkillSnapshot,
  ensureBundledWorkspaceFiles,
  ensureSandboxWorkspace,
  loadConversation,
  LlmProvider,
  LocalModel,
  LoopModelInfo,
  PARTIAL_FINAL_STATUS,
  ParallelDeps,
  ParallelObserver,
  ParallelTaskSnapshot,
  ParallelTaskRunner,
  ReActAgentRunner,
  saveConversation,
  sandboxWorkspacePath,
  SkillSnapshot,
  SubtaskModelHooks,
  SubtaskView,
  ToolRegistry,
  SessionBackedModel
} from '@loop/agent-core';
import { getLocalLlmBinding } from '../llm/LocalLlmBinding';
import { nearbyChannel } from '../nearby/LinkEnhanceChannel';
import { inferenceClient, INFERENCE_STOPPED } from '../model/InferenceClient';
import { TaskChildSnapshot, TaskSnapshot } from '../protocol/ChatProtocol';
import { TaskReporter } from '../model/TaskReporter';
import { TaskProgress, TaskProgressPhase, taskProgressActive } from '../model/TaskProgress';
import { TaskProgressCard } from '../ui/TaskProgressCard';
import { RemoteComputeModel } from '../model/RemoteComputeModel';
import { ChatMode, loadChatMode, saveChatMode } from '../model/ChatModeStore';
import { buildPlainChatPrompt } from '../model/PlainChat';
import { pickAttachment, readTextExcerpt, SavedAttachment } from '../media/ChatAttach';
import { encodeLocalImageBase64 } from '../media/ImageEncode';
import {
  CollaborationController,
  CollaborationStatus
} from '../llm/CollaborationController';

const MAX_STEPS = 10;
const LIVE_PLACEHOLDER = '正在生成…';
const LIVE_TOOL_PREFIX = '正在调用工具：';
const LIVE_COMPOSING = '正在整理工具结果…';

/**
 * 算力端请求阶段 → 直播气泡文案（见 InferHooks.onPhase）。
 * 加载权重与生成使用同一句，避免直播气泡在「正在加载模型」和「正在生成」之间切换。
 */
function remotePhaseText(state: string): string {
  if (state === 'queued') { return '排队中…'; }
  if (state === 'prefill') { return '正在理解问题…'; }
  return LIVE_PLACEHOLDER;
}
// Remote prompts carry recent turns only; the full transcript stays in the UI/store.
const REMOTE_HISTORY_TURNS = 6;
const REMOTE_HISTORY_MAX_CHARS = 4000;
const PARTIAL_HISTORY_NOTE = '（上一轮未得到完整回答）';
const LOG_DOMAIN = 0x0000;
const LOG_TAG = 'LoopyInference';
// Gewu's cross-device prefill path can hit its receive timeout when a short
// request also carries the entire persisted transcript. Keep one compact pair
// for follow-up semantics while the full conversation remains in the UI/store.
const COLLABORATION_HISTORY_TURNS = 2;
const COLLABORATION_HISTORY_MAX_CHARS = 160;
const MOBILE_PREFILL_OPTIONS_PREFIX = '@@LOOPY_MOBILE_PREFILL_V1:';
const SANDBOX_PREVIEW_MAX_BYTES = 512 * 1024;

interface SandboxBrowserEntry {
  name: string;
  relativePath: string;
  isDirectory: boolean;
  size: number;
}

interface MobilePrefillRequest {
  prompt: string;
  maxTokens: number;
  temperature: number;
}

interface InferenceUsageEnvelope {
  finish_reason?: string | null;
  usage?: InferenceUsagePayload;
}

interface InferenceUsagePayload {
  prompt_tokens?: number;
  completion_tokens?: number;
  prefill_latency?: number;
  decode_latency?: number;
  device_num?: number;
}

enum InferenceMetricsPageKind {
  CALL = 'call',
  SUMMARY = 'summary'
}

interface InferenceMetricsPage {
  kind: InferenceMetricsPageKind;
  deviceCount: string;
  promptLength: string;
  decodeLength: string;
  prefillSpeed: string;
  decodeSpeed: string;
  prefillDuration: string;
  decodeDuration: string;
  taskDuration: string;
  callCount: string;
}

function parseMobilePrefillRequest(task: string): MobilePrefillRequest | null {
  if (!task.startsWith(MOBILE_PREFILL_OPTIONS_PREFIX)) {
    return null;
  }
  const lineEnd = task.indexOf('\n');
  if (lineEnd < 0) {
    return null;
  }
  const header = task.substring(MOBILE_PREFILL_OPTIONS_PREFIX.length, lineEnd);
  if (!header.endsWith('@@')) {
    return null;
  }
  const values = header.substring(0, header.length - 2).split(':');
  if (values.length !== 2) {
    return null;
  }
  const maxTokens = Number(values[0]);
  const temperature = Number(values[1]);
  if (!Number.isFinite(maxTokens) || maxTokens < 1 || !Number.isFinite(temperature)) {
    return null;
  }
  return {
    prompt: task.substring(lineEnd + 1),
    maxTokens: Math.floor(maxTokens),
    temperature: temperature
  };
}

enum BubbleKind {
  USER,
  LOOP,
  SKILL,
  TOOL,
  OBSERVATION,
  ERROR,
  PROCESS,
  TASK
}

interface ChatBubble {
  id: number;
  speaker: string;
  text: string;
  kind: BubbleKind;
  imagePath: string;
  collapsible: boolean;
  expanded: boolean;
  revision: number;
  taskProgress?: TaskProgress;
}

function bubbleBackground(kind: BubbleKind): string {
  switch (kind) {
    case BubbleKind.USER: return '#1A176B87';
    case BubbleKind.LOOP: return '#1A0E8C45';
    case BubbleKind.SKILL: return '#1A7C3AED';
    case BubbleKind.TOOL: return '#1AF59E0B';
    case BubbleKind.OBSERVATION: return '#1A64748B';
    case BubbleKind.ERROR: return '#1ADC2626';
    default: return '#1A64748B';
  }
}

function bubbleBorder(kind: BubbleKind): string {
  switch (kind) {
    case BubbleKind.USER: return '#33176B87';
    case BubbleKind.LOOP: return '#330E8C45';
    case BubbleKind.SKILL: return '#337C3AED';
    case BubbleKind.TOOL: return '#33F59E0B';
    case BubbleKind.OBSERVATION: return '#3364748B';
    case BubbleKind.ERROR: return '#33DC2626';
    default: return '#3364748B';
  }
}

function bubbleLabelColor(kind: BubbleKind): string {
  switch (kind) {
    case BubbleKind.USER: return '#176B87';
    case BubbleKind.LOOP: return '#0E8C45';
    case BubbleKind.SKILL: return '#7C3AED';
    case BubbleKind.TOOL: return '#D97706';
    case BubbleKind.OBSERVATION: return '#64748B';
    case BubbleKind.ERROR: return '#DC2626';
    default: return '#64748B';
  }
}

@Component
struct InferenceMetricCellView {
  @Prop label: string = '';
  @Prop value: string = '';

  build() {
    Column() {
      Text(this.label)
        .fontSize(11)
        .fontColor($r('app.color.text_primary'))
        .opacity(0.6)
      Text(this.value)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .margin({ top: 2 })
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
  }
}

@Entry
@Component
struct Index {
  @State messages: ChatBubble[] = [];
  @State message: string = '';
  @State sending: boolean = false;
  @State agentEnabled: boolean = false;
  @State chatMode: ChatMode = 'chat';
  @State settingsVisible: boolean = false;
  @State modelStatus: string = '远程算力';
  @State titleText: string = '聊天';
  @State statusText: string = '正在寻找算力设备…';
  @State statusTone: string = 'wait';
  @State connectLabel: string = '连接';
  @State linkBusy: boolean = false;
  @State pendingKind: string = '';
  @State pendingName: string = '';
  @State pendingPath: string = '';
  @State pendingLocal: string = '';
  @State attachError: string = '';
  @State collaborationVisible: boolean = false;
  @State collaborationStatus: CollaborationStatus = 'disabled';
  @State collaborationStatusText: string = '协同未启用';
  @State collaborationIsMaster: boolean = true;
  @State sandboxBrowserVisible: boolean = false;
  @State sandboxBrowserPath: string = '';
  @State sandboxBrowserEntries: SandboxBrowserEntry[] = [];
  @State sandboxBrowserError: string = '';
  @State sandboxPreviewPath: string = '';
  @State sandboxPreviewContent: string = '';
  @State inferenceMetricsVisible: boolean = false;
  @State inferenceMetricsPages: InferenceMetricsPage[] = [];
  @State inferenceMetricsPageIndex: number = 0;
  @State inferenceMetricsSummaryPage: boolean = false;
  @State inferenceDeviceCount: string = '';
  @State inferencePromptLength: string = '';
  @State inferenceDecodeLength: string = '';
  @State inferencePrefillSpeed: string = '';
  @State inferenceDecodeSpeed: string = '';
  @State inferencePrefillDuration: string = '';
  @State inferenceDecodeDuration: string = '';
  @State inferenceTaskDuration: string = '';
  @State inferenceCallCount: string = '';

  private scroller: Scroller = new Scroller();
  private conversation: ConversationContext = new ConversationContext();
  private skillSnapshot: SkillSnapshot | null = null;
  private toolRegistryPromise: Promise<ToolRegistry> | null = null;
  private toolRegistryIncludesSkills: boolean = false;
  private collabController: CollaborationController | null = null;
  private singleDeviceModel: SessionBackedModel | null = null;
  private singleDeviceSessionPromise: Promise<SessionBackedModel | null> | null = null;
  private singleDeviceSessionGeneration: number = 0;
  private inferenceMetricsRunId: number = 0;
  private inferenceMetricsTotalPrefillLatencyMs: number = 0;
  private inferenceMetricsTotalDecodeLatencyMs: number = 0;
  private inferenceMetricsRunActive: boolean = false;
  private inferenceMetricsDismissed: boolean = false;
  private inferenceMetricsActiveRequestIds: Set<number> = new Set<number>();
  private inferenceMetricsRecordedRequestIds: Set<number> = new Set<number>();
  private nextChatBubbleId: number = 1;
  private liveReplyId: number = -1;
  private liveReplyPending: boolean = false;
  private processId: number = -1;
  private activeRunner: ReActAgentRunner | null = null;
  private activeParallel: ParallelTaskRunner | null = null;
  private activeTaskReporter: TaskReporter | null = null;
  private activeTaskProgressId: number = -1;
  private parallelHeader: string = '';
  private parallelViews: SubtaskView[] = [];
  private stopRequested: boolean = false;
  private remoteRunGeneration: number = 0;
  private pageActive: boolean = false;
  private chatBubbleTextWidthVp: number = 280;
  private collaborationKeepsScreenOn: boolean = false;

  private getAbilityContext(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  aboutToAppear(): void {
    this.pageActive = true;
    this.stopRequested = false;
    const context = this.getAbilityContext();
    this.chatMode = loadChatMode(context);
    this.agentEnabled = this.chatMode !== 'chat';
    this.restoreConversation();
    ensureBundledWorkspaceFiles(context).catch((_error: Error): void => {});
    nearbyChannel.initialize(context);
    inferenceClient.bind();
    inferenceClient.setLinkListener((): void => {
      if (this.pageActive) { this.refreshLinkChrome(); }
    });
    this.modelStatus = '远程算力';
    this.refreshLinkChrome();
    this.ensureRemoteReady(this.remoteRunGeneration).catch((_error: Error): void => {});
  }

  aboutToDisappear(): void {
    this.updateTaskProgress('cancelled');
    this.pageActive = false;
    this.remoteRunGeneration++;
    this.stopRequested = true;
    this.activeRunner?.requestStop();
    this.activeRunner = null;
    this.activeParallel?.requestStop();
    this.activeTaskReporter?.finish('cancelled');
    this.activeTaskReporter = null;
    this.activeParallel = null;
    inferenceClient.setLinkListener(null);
    this.dropLivePlaceholder();
    this.sending = false;
    const tools = this.toolRegistryPromise;
    this.toolRegistryPromise = null;
    this.toolRegistryIncludesSkills = false;
    tools?.then(async (registry: ToolRegistry): Promise<void> => registry.close()).catch((_error: Error): void => {});
    const controller = this.collabController;
    this.collabController = null;
    controller?.dispose().catch((_error: Error): void => {});
    inferenceClient.reset();
    nearbyChannel.disconnect();
    this.disposeSingleDeviceSession();
    this.setCollaborationKeepScreenOn(false);
  }

  build() {
    if (this.settingsVisible) {
      this.settingsPage();
    } else {
      this.chatPage();
    }
  }

  @Builder
  settingsPage() {
    Column() {
      Row() {
        Button('返回')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor('#0F8A74')
          .backgroundColor(Color.White)
          .borderRadius(16)
          .height(36)
          .padding({ left: 12, right: 12 })
          .onClick(() => {
            this.settingsVisible = false;
          })
        Text('设置')
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor('#16332C')
          .margin({ left: 12 })
          .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Text('对话模式')
        .fontSize(13)
        .fontColor('#6B7F79')
        .width('100%')
        .margin({ top: 18, bottom: 8 })

      this.modeOption('chat', '普通聊天', '算力直接回答，不调用工具')
      this.modeOption('agent', 'Agent（不拆分）', '调用工具，不拆分任务')
      this.modeOption('agent_split', 'Agent（拆分任务）', '自动规划任务并调用工具')

      if (this.sending) {
        Text('生成期间需先停止再切换模式。')
          .fontSize(12)
          .fontColor('#6B7F79')
          .width('100%')
          .margin({ top: 8 })
      }
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 16, right: 16, top: 14, bottom: 16 })
    .backgroundColor('#EEF6F3')
  }

  @Builder
  modeOption(mode: ChatMode, title: string, detail: string) {
    Row() {
      Column() {
        Text(title)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor('#16332C')
        Text(detail)
          .fontSize(12)
          .fontColor('#6B7F79')
          .margin({ top: 2 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Text(this.chatMode === mode ? '当前' : '')
        .fontSize(12)
        .fontColor('#0F8A74')
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 12, bottom: 12 })
    .margin({ bottom: 8 })
    .backgroundColor(Color.White)
    .borderRadius(16)
    .border({ width: this.chatMode === mode ? 1 : 0, color: '#0F8A74' })
    .enabled(!this.sending)
    .onClick(() => {
      this.changeChatMode(mode);
    })
  }

  @Builder
  chatPage() {
    Column() {
      Row() {
        Image($r('app.media.icon'))
          .width(36)
          .height(36)
          .borderRadius(12)
          .objectFit(ImageFit.Cover)

        Column() {
          Text(this.titleText)
            .fontSize(17)
            .fontWeight(FontWeight.Bold)
            .fontColor('#16332C')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })

          Row() {
            Circle()
              .width(7)
              .height(7)
              .fill(this.statusColor())
            Text(this.statusText)
              .fontSize(12)
              .fontColor(this.statusColor())
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .margin({ left: 6 })
              .layoutWeight(1)
          }
          .padding({ left: 6, right: 8, top: 2, bottom: 2 })
          .borderRadius(999)
          .backgroundColor(this.statusFill())
          .margin({ top: 3 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        .margin({ left: 10 })

        Button('⚙')
          .fontSize(18)
          .fontColor('#0F8A74')
          .backgroundColor(Color.White)
          .borderRadius(18)
          .width(36)
          .height(36)
          .padding(0)
          .margin({ right: 8 })
          .accessibilityText('设置')
          .onClick(() => {
            this.settingsVisible = true;
          })

        Button('清除')
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor('#C4473A')
          .backgroundColor(Color.White)
          .borderRadius(16)
          .height(36)
          .padding({ left: 12, right: 12 })
          .margin({ right: 8 })
          .enabled(this.messages.length > 0 && !this.sending)
          .onClick(() => {
            this.clearConversation();
          })

        Button(this.connectLabel)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor('#0F8A74')
          .backgroundColor(Color.White)
          .borderRadius(16)
          .height(36)
          .padding({ left: 12, right: 12 })
          .enabled(!this.linkBusy)
          .onClick(() => {
            this.toggleLink();
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Scroll(this.scroller) {
        Column() {
          if (this.messages.length === 0) {
            Column() {
              Text('向附近的算力提问')
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor('#16332C')
              Text('连上后可以直接发文字、图片或文档')
                .fontSize(14)
                .fontColor('#6B7F79')
                .margin({ top: 4 })
            }
            .width('100%')
            .justifyContent(FlexAlign.Center)
          }

          ForEach(this.messages, (bubble: ChatBubble) => {
            Row() {
              if (bubble.kind === BubbleKind.TASK && bubble.taskProgress !== undefined) {
                Column() {
                  TaskProgressCard({ progress: bubble.taskProgress })
                }
                .width('100%')
                .constraintSize({ maxWidth: 440 })
                .alignItems(HorizontalAlign.Start)
              } else if (bubble.kind === BubbleKind.PROCESS) {
                Column() {
                  Text(bubble.expanded ? '▾ 思考和行动' : '▸ 思考和行动')
                    .fontSize(14)
                    .fontColor('#6B7F79')
                    .onClick(() => {
                      this.toggleBubbleExpansion(bubble.id);
                    })
                  if (bubble.expanded && bubble.text.length > 0) {
                    Text(bubble.text)
                      .fontSize(13)
                      .lineHeight(20)
                      .fontColor('#6B7F79')
                      .margin({ top: 8 })
                      .copyOption(CopyOptions.LocalDevice)
                  }
                }
                .constraintSize({ maxWidth: '82%' })
                .padding({ left: 14, right: 14, top: 10, bottom: 10 })
                .backgroundColor('#F7FBFA')
                .borderRadius({ topLeft: 18, topRight: 18, bottomLeft: 6, bottomRight: 18 })
              } else {
                Column() {
                  if (bubble.imagePath.length > 0) {
                    // ArkUI 的 Image 必须以 file:// 识别沙箱文件；直接传 /data/storage/... 会被
                    // 当作网络地址处理，加载失败且不抛异常，只表现为空白。
                    Image('file://' + bubble.imagePath)
                      .width(168)
                      .height(126)
                      .borderRadius(12)
                      .objectFit(ImageFit.Cover)
                      .margin({ bottom: bubble.text.length > 0 ? 8 : 0 })
                  }
                  if (bubble.text.length > 0) {
                    Text(bubble.text)
                      .fontSize(16)
                      .lineHeight(24)
                      .fontColor(bubble.kind === BubbleKind.ERROR ? '#C4473A' :
                        (bubble.kind === BubbleKind.TOOL || bubble.kind === BubbleKind.OBSERVATION ||
                          bubble.kind === BubbleKind.SKILL ? '#6B7F79' : '#16332C'))
                      .copyOption(CopyOptions.LocalDevice)
                  }
                }
                .constraintSize({ maxWidth: '82%' })
                .padding({ left: 14, right: 14, top: 12, bottom: 12 })
                .backgroundColor(bubble.kind === BubbleKind.USER ? '#D8F3EA' : Color.White)
                .borderRadius(bubble.kind === BubbleKind.USER ?
                  { topLeft: 18, topRight: 18, bottomLeft: 18, bottomRight: 6 } :
                  { topLeft: 18, topRight: 18, bottomLeft: 6, bottomRight: 18 })
                .shadow({ radius: 20, color: '#0D10322A', offsetX: 0, offsetY: 8 })
              }
            }
            .width('100%')
            .justifyContent(bubble.kind === BubbleKind.USER ? FlexAlign.End : FlexAlign.Start)
            .margin({ bottom: 10 })
            // The task card already represents waiting; keep detailed parallel progress visible.
            .visibility(bubble.id === this.liveReplyId && this.liveReplyPending && this.parallelHeader.length === 0 ?
              Visibility.None : Visibility.Visible)
          }, (bubble: ChatBubble) => `${bubble.id}-${bubble.revision}`)
        }
        .width('100%')
        .constraintSize({ minHeight: '100%' })
        .justifyContent(this.messages.length === 0 ? FlexAlign.Center : FlexAlign.End)
      }
      .layoutWeight(1)
      .width('100%')
      .align(Alignment.Bottom)
      .scrollBar(BarState.Off)

      Column() {
        if (this.pendingPath.length > 0) {
          Row() {
            if (this.pendingKind === 'image' && this.pendingLocal.length > 0) {
              // 同上：沙箱路径必须带 file:// 前缀，否则预览是空白。
              Image('file://' + this.pendingLocal)
                .width(36)
                .height(36)
                .borderRadius(8)
                .objectFit(ImageFit.Cover)
            }
            if (this.pendingKind !== 'image') {
              Text(this.pendingName)
                .fontSize(13)
                .fontColor('#16332C')
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
                .margin({ left: 8 })
            } else {
              // 图片不显示文件名：用户只需要看到缩略图，文件名对其没有意义。
              // Blank 占住剩余空间，把 × 保持在右侧，行布局与文档附件一致。
              Blank()
            }
            Button('×')
              .width(28)
              .height(28)
              .fontSize(16)
              .fontColor('#6B7F79')
              .backgroundColor('#EEF6F3')
              .borderRadius(14)
              .padding(0)
              .onClick(() => {
                this.clearAttachment();
              })
          }
          .width('100%')
          .padding({ left: 8, right: 6, top: 4, bottom: 4 })
          .margin({ bottom: 6 })
        }

        if (this.attachError.length > 0) {
          Text(this.attachError)
            .fontSize(12)
            .fontColor('#C4473A')
            .margin({ left: 8, bottom: 4 })
        }

        Row() {
          Button('附件')
            .height(36)
            .fontSize(13)
            .fontColor('#0F8A74')
            .backgroundColor('#E7F6F2')
            .borderRadius(18)
            .padding({ left: 12, right: 12 })
            .enabled(!this.sending)
            .onClick(() => {
              this.chooseAttachment();
            })
          TextInput({ text: this.message, placeholder: '输入问题…' })
            .layoutWeight(1)
            .height(44)
            .fontSize(16)
            .fontColor('#16332C')
            .placeholderColor('#8AA39C')
            .backgroundColor(Color.Transparent)
            .padding({ left: 8, right: 4 })
            .margin({ left: 4 })
            .copyOption(CopyOptions.LocalDevice)
            .enabled(!this.sending)
            .onChange((value: string) => {
              this.message = value;
            })
            .onSubmit(() => {
              this.runAgent();
            })

          Button() {
            Text(this.sending ? '■' : '➤')
              .fontSize(this.sending ? 14 : 18)
              .fontColor(Color.White)
          }
          .width(44)
          .height(44)
          .borderRadius(22)
          .backgroundColor(this.sendEnabled() ? '#0F8A74' : '#C9D4D0')
          .enabled(this.sendEnabled())
          .onClick(() => {
            if (this.sending) {
              this.stopGeneration();
            } else {
              this.runAgent();
            }
          })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }
      .width('100%')
      .padding(6)
      .borderRadius(24)
      .backgroundColor(Color.White)
      .shadow({ radius: 28, color: '#1410322A', offsetX: 0, offsetY: 10 })
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16, top: 14, bottom: 16 })
    .backgroundColor('#EEF6F3')
  }

  @Builder
  inferenceMetricsCard() {
    Column() {
      if (!this.inferenceMetricsSummaryPage) {
        Row() {
          InferenceMetricCellView({ label: '设备数量', value: this.inferenceDeviceCount })
          InferenceMetricCellView({ label: 'Prompt长度', value: this.inferencePromptLength })

          Button('×')
            .width(38)
            .height(38)
            .margin({ left: 6 })
            .padding(0)
            .fontSize(24)
            .fontWeight(FontWeight.Medium)
            .borderRadius(19)
            .backgroundColor('#14000000')
            .fontColor('#B3261E')
            .onClick(() => {
              this.dismissInferenceMetricsCard();
            })
        }
        .width('100%')

        Row() {
          InferenceMetricCellView({ label: 'Decode长度', value: this.inferenceDecodeLength })
          InferenceMetricCellView({ label: 'Prefill速度', value: this.inferencePrefillSpeed })
        }
        .width('100%')
        .margin({ top: 8 })

        Row() {
          InferenceMetricCellView({ label: 'Decode速度', value: this.inferenceDecodeSpeed })
          InferenceMetricCellView({ label: 'Prefill耗时', value: this.inferencePrefillDuration })
        }
        .width('100%')
        .margin({ top: 8 })

        Row() {
          InferenceMetricCellView({ label: 'Decode耗时', value: this.inferenceDecodeDuration })
        }
        .width('100%')
        .margin({ top: 8 })
      } else {
        Row() {
          InferenceMetricCellView({ label: '任务总耗时', value: this.inferenceTaskDuration })
          InferenceMetricCellView({ label: 'LLM调用次数', value: this.inferenceCallCount })

          Button('×')
            .width(38)
            .height(38)
            .margin({ left: 6 })
            .padding(0)
            .fontSize(24)
            .fontWeight(FontWeight.Medium)
            .borderRadius(19)
            .backgroundColor('#14000000')
            .fontColor('#B3261E')
            .onClick(() => {
              this.dismissInferenceMetricsCard();
            })
        }
        .width('100%')

        Row() {
          InferenceMetricCellView({ label: 'Prefill总耗时', value: this.inferencePrefillDuration })
          InferenceMetricCellView({ label: 'Decode总耗时', value: this.inferenceDecodeDuration })
        }
        .width('100%')
        .margin({ top: 8 })
      }

      Row() {
        Button('‹')
          .width(44)
          .height(34)
          .padding(0)
          .fontSize(24)
          .borderRadius(17)
          .backgroundColor('#14000000')
          .fontColor($r('app.color.send_button'))
          .enabled(this.inferenceMetricsPageIndex > 0)
          .onClick(() => {
            if (this.inferenceMetricsPageIndex > 0) {
              this.selectInferenceMetricsPage(this.inferenceMetricsPageIndex - 1);
            }
          })

        Text(this.inferenceMetricsPageLabel())
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
          .fontSize(12)
          .fontColor($r('app.color.text_primary'))
          .opacity(0.68)

        Button('›')
          .width(44)
          .height(34)
          .padding(0)
          .fontSize(24)
          .borderRadius(17)
          .backgroundColor('#14000000')
          .fontColor($r('app.color.send_button'))
          .enabled(this.inferenceMetricsPageIndex < this.inferenceMetricsPages.length - 1)
          .onClick(() => {
            if (this.inferenceMetricsPageIndex < this.inferenceMetricsPages.length - 1) {
              this.selectInferenceMetricsPage(this.inferenceMetricsPageIndex + 1);
            }
          })
      }
      .width('100%')
      .margin({ top: 10 })
    }
    .width('100%')
    .padding(12)
    .margin({ bottom: 8 })
    .borderRadius(12)
    .backgroundColor(Color.White)
    .border({ width: 1, color: $r('app.color.input_stroke') })
    .shadow({ radius: 8, color: '#1A000000', offsetX: 0, offsetY: 2 })
  }

  @Builder
  sandboxBrowserView() {
    Column() {
      Row() {
        Button('‹')
          .width(44)
          .height(40)
          .fontSize(26)
          .backgroundColor(Color.Transparent)
          .fontColor($r('app.color.send_button'))
          .onClick(() => {
            this.navigateSandboxBrowserBack();
          })

        Column() {
          Text(this.sandboxPreviewPath.length > 0 ? '文件预览' : '文件空间')
            .fontSize(20)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
          Text(this.sandboxBrowserLocationLabel())
            .fontSize(12)
            .fontColor($r('app.color.text_primary'))
            .opacity(0.6)
            .margin({ top: 2 })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Text('只读')
          .fontSize(12)
          .fontColor($r('app.color.send_button'))
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .borderRadius(10)
          .backgroundColor('#120066CC')
      }
      .width('100%')
      .margin({ bottom: 12 })

      if (this.sandboxBrowserError.length > 0) {
        Text(this.sandboxBrowserError)
          .width('100%')
          .fontSize(13)
          .fontColor('#B3261E')
          .padding(10)
          .margin({ bottom: 8 })
          .borderRadius(10)
          .backgroundColor('#12B3261E')
      }

      if (this.sandboxPreviewPath.length > 0) {
        Scroll() {
          Text(this.sandboxPreviewContent)
            .width('100%')
            .fontSize(14)
            .lineHeight(21)
            .fontColor($r('app.color.text_primary'))
            .textAlign(TextAlign.Start)
        }
        .width('100%')
        .layoutWeight(1)
        .padding(12)
        .borderRadius(12)
        .backgroundColor(Color.White)
        .border({ width: 1, color: $r('app.color.input_stroke') })
      } else if (this.sandboxBrowserEntries.length === 0) {
        Column() {
          Text('此文件夹为空')
            .fontSize(16)
            .fontColor($r('app.color.text_primary'))
            .opacity(0.6)
        }
        .layoutWeight(1)
        .width('100%')
        .justifyContent(FlexAlign.Center)
      } else {
        List({ space: 8 }) {
          ForEach(this.sandboxBrowserEntries, (entry: SandboxBrowserEntry) => {
            ListItem() {
              Row() {
                Text(entry.isDirectory ? '📁' : '📄')
                  .fontSize(22)
                  .margin({ right: 10 })

                Column() {
                  Text(entry.name)
                    .fontSize(15)
                    .fontColor($r('app.color.text_primary'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(entry.isDirectory ? '文件夹' : this.formatSandboxFileSize(entry.size))
                    .fontSize(12)
                    .fontColor($r('app.color.text_primary'))
                    .opacity(0.55)
                    .margin({ top: 3 })
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)

                Text('›')
                  .fontSize(24)
                  .fontColor($r('app.color.text_primary'))
                  .opacity(0.35)
              }
              .width('100%')
              .padding(12)
              .borderRadius(12)
              .backgroundColor(Color.White)
              .border({ width: 1, color: $r('app.color.input_stroke') })
              .onClick(() => {
                this.openSandboxBrowserEntry(entry);
              })
            }
          }, (entry: SandboxBrowserEntry) => entry.relativePath)
        }
        .width('100%')
        .layoutWeight(1)
      }
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Start)
  }

  private openSandboxBrowser(): void {
    const context = this.getAbilityContext();
    try {
      ensureSandboxWorkspace();
    } catch (_error) {
    }
    this.sandboxBrowserVisible = true;
    this.sandboxPreviewPath = '';
    this.sandboxPreviewContent = '';
    this.loadSandboxBrowserDirectory('');
    ensureBundledWorkspaceFiles(context).then((): void => {
      if (this.sandboxBrowserVisible) {
        this.loadSandboxBrowserDirectory(this.sandboxBrowserPath);
      }
    }).catch((error: Error): void => {
      if (this.sandboxBrowserVisible) {
        this.sandboxBrowserError = error.message;
      }
    });
    createSkillSnapshot(context).then((snapshot: SkillSnapshot): void => {
      this.skillSnapshot = snapshot;
      if (this.sandboxBrowserVisible) {
        this.loadSandboxBrowserDirectory(this.sandboxBrowserPath);
      }
    }).catch((_error: Error): void => {});
  }

  private closeSandboxBrowser(): void {
    this.sandboxBrowserVisible = false;
    this.sandboxBrowserError = '';
    this.sandboxPreviewPath = '';
    this.sandboxPreviewContent = '';
  }

  private navigateSandboxBrowserBack(): void {
    if (this.sandboxPreviewPath.length > 0) {
      this.sandboxPreviewPath = '';
      this.sandboxPreviewContent = '';
      this.sandboxBrowserError = '';
      return;
    }
    if (this.sandboxBrowserPath.length === 0) {
      this.closeSandboxBrowser();
      return;
    }
    const slash = this.sandboxBrowserPath.lastIndexOf('/');
    this.loadSandboxBrowserDirectory(slash < 0 ? '' : this.sandboxBrowserPath.substring(0, slash));
  }

  private openSandboxBrowserEntry(entry: SandboxBrowserEntry): void {
    if (entry.isDirectory) {
      this.loadSandboxBrowserDirectory(entry.relativePath);
      return;
    }
    this.previewSandboxFile(entry);
  }

  private loadSandboxBrowserDirectory(relativePath: string): void {
    this.sandboxBrowserError = '';
    this.sandboxPreviewPath = '';
    this.sandboxPreviewContent = '';
    if (relativePath.length > 0 && !this.isAllowedSandboxBrowserPath(relativePath)) {
      this.sandboxBrowserError = '该路径不属于文件空间。';
      return;
    }

    const absolutePath = sandboxWorkspacePath(relativePath);
    try {
      const names = fs.listFileSync(absolutePath);
      const entries: SandboxBrowserEntry[] = [];
      for (const name of names) {
        const childRelativePath = relativePath.length > 0 ? `${relativePath}/${name}` : name;
        if (!this.isAllowedSandboxBrowserPath(childRelativePath)) {
          continue;
        }
        const stat = fs.statSync(sandboxWorkspacePath(childRelativePath));
        entries.push({
          name: name,
          relativePath: childRelativePath,
          isDirectory: stat.isDirectory(),
          size: stat.size
        });
      }
      entries.sort((left: SandboxBrowserEntry, right: SandboxBrowserEntry): number => {
        if (left.isDirectory !== right.isDirectory) {
          return left.isDirectory ? -1 : 1;
        }
        return left.name.localeCompare(right.name);
      });
      this.sandboxBrowserPath = relativePath;
      this.sandboxBrowserEntries = entries;
    } catch (error) {
      this.sandboxBrowserPath = relativePath;
      this.sandboxBrowserEntries = [];
      this.sandboxBrowserError = error instanceof Error ? error.message : `${error}`;
    }
  }

  private previewSandboxFile(entry: SandboxBrowserEntry): void {
    this.sandboxBrowserError = '';
    this.sandboxPreviewPath = entry.relativePath;
    if (!this.isSandboxTextFile(entry.name)) {
      this.sandboxPreviewContent = '当前只支持预览 CSV、TXT、MD 和 JSON 文本文件。';
      return;
    }
    if (entry.size > SANDBOX_PREVIEW_MAX_BYTES) {
      this.sandboxPreviewContent = `文件大小为 ${this.formatSandboxFileSize(entry.size)}，超过 512 KB 预览限制。`;
      return;
    }
    try {
      const absolutePath = sandboxWorkspacePath(entry.relativePath);
      this.sandboxPreviewContent = fs.readTextSync(absolutePath, { encoding: 'utf-8' });
    } catch (error) {
      this.sandboxPreviewContent = '';
      this.sandboxBrowserError = error instanceof Error ? error.message : `${error}`;
    }
  }

  private isAllowedSandboxBrowserPath(relativePath: string): boolean {
    if (relativePath.length === 0 || relativePath.startsWith('/') || relativePath.indexOf(':') >= 0 ||
      relativePath.indexOf('\\') >= 0) {
      return false;
    }
    const parts = relativePath.split('/');
    for (const part of parts) {
      if (part.length === 0 || part === '.' || part === '..') {
        return false;
      }
    }
    return true;
  }

  private isSandboxTextFile(name: string): boolean {
    const lower = name.toLowerCase();
    return lower.endsWith('.csv') || lower.endsWith('.txt') || lower.endsWith('.md') || lower.endsWith('.json');
  }

  private sandboxBrowserLocationLabel(): string {
    if (this.sandboxPreviewPath.length > 0) {
      return this.sandboxPreviewPath;
    }
    return this.sandboxBrowserPath.length > 0 ? this.sandboxBrowserPath : 'workspace /';
  }

  private formatSandboxFileSize(bytes: number): string {
    if (bytes < 1024) {
      return `${bytes} B`;
    }
    if (bytes < 1024 * 1024) {
      return `${(bytes / 1024).toFixed(1)} KB`;
    }
    return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
  }

  private remoteStatus: string = '正在连接算力';

  private refreshLinkChrome(): void {
    const connected = nearbyChannel.isConnected();
    this.titleText = connected ? nearbyChannel.selfLabel() : '聊天';
    this.connectLabel = connected ? '断开' : '连接';
    if (this.linkBusy) {
      this.statusText = '连接中';
      this.statusTone = 'wait';
      return;
    }
    if (connected && !nearbyChannel.inferenceReady()) {
      this.statusText = '算力端版本不支持';
      this.statusTone = 'err';
      return;
    }
    if (connected && !inferenceClient.isReady()) {
      this.statusText = inferenceClient.statusText();
      this.statusTone = inferenceClient.failed() ? 'err' : 'wait';
      return;
    }
    if (connected) {
      this.statusText = '已就绪';
      this.statusTone = 'ok';
      return;
    }
    if (!connected) {
      const text = this.remoteStatus;
      const failed = text.indexOf('失败') >= 0 || text.indexOf('未发现') >= 0 || text.indexOf('无法') >= 0 ||
        text.indexOf('错误') >= 0 || text.indexOf('中断') >= 0 || text.indexOf('尚未') >= 0;
      this.statusText = text.length > 0 && text !== '正在连接算力' && text !== '算力已连接' ? text : '正在寻找算力设备…';
      this.statusTone = failed ? 'err' : 'wait';
    }
  }

  private toggleLink(): void {
    if (this.linkBusy) {
      return;
    }
    if (nearbyChannel.isConnected()) {
      inferenceClient.reset();
      nearbyChannel.disconnect();
      this.remoteStatus = '未连接';
      this.refreshLinkChrome();
      return;
    }
    this.remoteStatus = '正在连接算力';
    this.ensureRemoteReady(this.remoteRunGeneration).catch((_error: Error): void => {});
  }

  private statusColor(): string {
    if (this.statusTone === 'ok') {
      return '#1A9B6A';
    }
    if (this.statusTone === 'err') {
      return '#C4473A';
    }
    return '#C98412';
  }

  private statusFill(): string {
    if (this.statusTone === 'ok') {
      return '#1A1A9B6A';
    }
    if (this.statusTone === 'err') {
      return '#1AC4473A';
    }
    return '#1EC98412';
  }

  private async ensureRemoteReady(generation: number = this.remoteRunGeneration): Promise<boolean> {
    if (!this.isCurrentRemoteRun(generation)) { return false; }
    nearbyChannel.initialize(this.getAbilityContext());
    nearbyChannel.resume();
    this.linkBusy = true;
    this.refreshLinkChrome();
    try {
      if (!nearbyChannel.isConnected()) {
        await nearbyChannel.prepare();
        if (!this.isCurrentRemoteRun(generation)) { return false; }
        await nearbyChannel.computeDevices();
        if (!this.isCurrentRemoteRun(generation)) { return false; }
        let ads = nearbyChannel.advertisedComputes();
        if (ads.length === 0) {
          this.remoteStatus = nearbyChannel.hasComputeHits()
            ? '附近的算力还没组网。请用同一华为账号在超级终端中连接后再试。'
            : '未发现算力设备。请打开算力手机并保持近场开启后重试。';
          return false;
        }
        ads = nearbyChannel.connectComputes();
        if (ads.length === 0) {
          this.remoteStatus = '算力设备1尚未确定或不可用，请等待算力设备组网后重试。';
          return false;
        }
        const operation = nearbyChannel.operation();
        await nearbyChannel.connectAdvertiser(ads[0].mac, operation);
        if (!this.isCurrentRemoteRun(generation)) { return false; }
        const connected = await nearbyChannel.waitUntilConnected();
        if (!this.isCurrentRemoteRun(generation)) { return false; }
        if (!connected) {
          this.remoteStatus = nearbyChannel.getStatus();
          return false;
        }
        const serviceError = await nearbyChannel.checkService();
        if (!this.isCurrentRemoteRun(generation)) { return false; }
        if (serviceError.length > 0) {
          this.remoteStatus = serviceError;
          return false;
        }
      }
      // A ready link is not yet a ready model. Negotiate on connection as well as
      // first send; ensureReady coalesces callers and reuses the current profile.
      const negotiate = await inferenceClient.ensureReady();
      if (!this.isCurrentRemoteRun(generation)) { return false; }
      if (negotiate.length > 0) {
        this.remoteStatus = negotiate;
        return false;
      }
      if (!nearbyChannel.isConnected()) {
        this.remoteStatus = '连接已中断，请重新连接。';
        return false;
      }
      this.remoteStatus = '算力已连接';
      this.modelStatus = '远程算力';
      return true;
    } catch (error) {
      if (this.isCurrentRemoteRun(generation)) {
        this.remoteStatus = error instanceof Error ? error.message : '连接算力失败';
      }
      return false;
    } finally {
      if (this.isCurrentRemoteRun(generation)) {
        this.linkBusy = false;
        this.refreshLinkChrome();
      }
    }
  }

  private isCurrentRemoteRun(generation: number): boolean {
    return this.pageActive && generation === this.remoteRunGeneration && !this.stopRequested;
  }

  private changeAgentMode(enabled: boolean): void {
    this.changeChatMode(enabled ? 'agent_split' : 'chat');
  }

  private changeChatMode(mode: ChatMode): void {
    if (this.sending || mode === this.chatMode) { return; }
    const leavingAgent = this.agentEnabled && mode === 'chat';
    this.chatMode = mode;
    this.agentEnabled = mode !== 'chat';
    if (leavingAgent) {
      const tools = this.toolRegistryPromise;
      this.toolRegistryPromise = null;
      this.toolRegistryIncludesSkills = false;
      tools?.then(async (registry: ToolRegistry): Promise<void> => registry.close()).catch((_error: Error): void => {});
    }
    saveChatMode(this.getAbilityContext(), mode).catch((_error: Error): void => {
      if (this.pageActive) {
        this.appendLine('Error', '模式已切换，但未能保存设置，重启后请重新选择。', BubbleKind.ERROR);
      }
    });
  }

  private async runRemoteAgent(task: string, display: string, imagePath: string,
    imagePayload: string = ''): Promise<void> {
    if (!this.pageActive || this.sending) { return; }
    const mode: ChatMode = this.chatMode === 'agent' || this.chatMode === 'chat' ? this.chatMode : 'agent_split';
    const useAgent = mode !== 'chat';
    const generation = ++this.remoteRunGeneration;
    this.stopRequested = false;
    this.message = '';
    this.sending = true;
    this.setCollaborationKeepScreenOn(true);
    let finalAnswer: string | null = null;
    let finalPartial = false;
    let failureText = '';
    const startedAt = Date.now();
    this.appendUserMessage(display, imagePath);
    this.beginTaskProgress(imagePath.length > 0 || imagePayload.length > 0 ? '图像' : '文本', startedAt);
    let reporter: TaskReporter | null = null;
    try {
      const ready = await this.ensureRemoteReady(generation);
      if (!this.isCurrentRemoteRun(generation)) { return; }
      if (!ready) {
        this.appendLine('Error', this.remoteStatus, BubbleKind.ERROR);
        return;
      }
      if (!nearbyChannel.inferenceReady()) {
        this.appendLine('Error', '算力端版本不支持', BubbleKind.ERROR);
        return;
      }
      const negotiate = await inferenceClient.ensureReady();
      if (!this.isCurrentRemoteRun(generation)) { return; }
      this.refreshLinkChrome();
      if (negotiate.length > 0) {
        this.appendLine('Error', negotiate, BubbleKind.ERROR);
        return;
      }
      reporter = new TaskReporter('t' + startedAt.toString(36) + '_' + generation.toString(36) + '_' +
        Math.floor(Math.random() * 1679616).toString(36), task, startedAt,
        (snapshot: TaskSnapshot): void => inferenceClient.publishTask(snapshot));
      this.activeTaskReporter = reporter;
      this.updateTaskProgress('running');
      if (!useAgent) {
        const prompt = buildPlainChatPrompt(task, inferenceClient.promptBudgetBytes());
        const answer = await inferenceClient.complete(prompt, {
          label: '普通聊天', taskId: reporter.id, subtaskId: 'main',
          onPhase: (state: string): void => {
            if (this.isCurrentRemoteRun(generation)) { this.setLivePhase(remotePhaseText(state)); }
          },
          onStart: (): void => {
            if (this.isCurrentRemoteRun(generation)) { this.beginLiveReply(); }
          },
          onDelta: (text: string): void => {
            if (this.isCurrentRemoteRun(generation)) { this.commitLiveAnswer(text); }
          }
        }, null, imagePayload);
        if (!this.isCurrentRemoteRun(generation)) { return; }
        if (answer.trim().length === 0) { throw new Error('算力未返回回答，请重试'); }
        finalAnswer = answer;
        this.commitLiveAnswer(answer);
        return;
      }
      const context = this.getAbilityContext();
      const skillSnapshot = this.skillSnapshot ?? await createSkillSnapshot(context);
      if (!this.isCurrentRemoteRun(generation)) { return; }
      this.skillSnapshot = skillSnapshot;
      if (!this.toolRegistryIncludesSkills) {
        const oldTools = this.toolRegistryPromise;
        oldTools?.then(async (registry: ToolRegistry): Promise<void> => registry.close()).catch((_error: Error): void => {});
        this.toolRegistryPromise = createConfiguredLoopToolRegistry(context, skillSnapshot);
        this.toolRegistryIncludesSkills = true;
      }
      const pendingTools = this.toolRegistryPromise;
      if (pendingTools === null) {
        this.appendLine('Error', '工具尚未就绪', BubbleKind.ERROR);
        return;
      }
      const tools = await pendingTools;
      if (!this.isCurrentRemoteRun(generation)) { return; }
      // Hooks belong to this run's model only, so a superseded run can never
      // drive the next run's placeholder.
      const model = new RemoteComputeModel({
        taskId: reporter.id, subtaskId: 'main',
        onStart: (): void => {
          if (!this.isCurrentRemoteRun(generation)) { return; }
          this.beginLiveReply();
          this.setLivePhase(LIVE_PLACEHOLDER);
        },
        onDelta: (text: string): void => {
          if (this.isCurrentRemoteRun(generation)) { this.showLiveReply(text); }
        },
        onPhase: (state: string): void => {
          if (this.isCurrentRemoteRun(generation)) { this.setLivePhase(remotePhaseText(state)); }
        }
      });
      // 附图随本轮**第一次**模型调用发出，RemoteComputeModel 用完即清。
      // 只在确有图片时调用：本轮 model 是新建的，本就无需清空，也让不涉及图片的
      // 调用方（含测试替身）不必实现这个 setter。
      if (imagePayload.length > 0) {
        model.setImage(imagePayload);
      }
      const runner = new ReActAgentRunner(
        model, tools, MAX_STEPS, skillSnapshot, true, false, true,
        (): number => inferenceClient.promptBudgetBytes(), false, true);
      this.activeRunner = runner;
      this.processId = -1;
      this.liveReplyId = -1;
      this.liveReplyPending = false;
      const listener = (event: AgentEvent): void => {
        if (!this.isCurrentRemoteRun(generation)) { return; }
        if (event.kind === AgentEventKind.ACTION || event.kind === AgentEventKind.OBSERVATION ||
          event.kind === AgentEventKind.SKILL || event.kind === AgentEventKind.THOUGHT) {
          if (event.kind === AgentEventKind.ACTION || event.kind === AgentEventKind.OBSERVATION) {
            reporter?.record(event.kind, event.text, event.toolName, event.input);
          }
          this.appendProcess(event);
          if (event.kind === AgentEventKind.ACTION) {
            this.setLivePhase(LIVE_TOOL_PREFIX + (event.toolName ?? '工具') + '…');
          } else if (event.kind === AgentEventKind.OBSERVATION) {
            this.setLivePhase(LIVE_COMPOSING);
          }
          return;
        }
        if (event.kind === AgentEventKind.FINAL) {
          finalAnswer = event.text;
          finalPartial = event.status === PARTIAL_FINAL_STATUS;
          this.finishInferenceMetricsTask();
          this.commitLiveAnswer(event.text);
          return;
        }
        if (event.kind === AgentEventKind.ERROR) failureText = event.text;
        if (event.kind === AgentEventKind.ERROR && event.text === INFERENCE_STOPPED) {
          this.dropLivePlaceholder();
          if (this.liveReplyId < 0) {
            this.appendLine('Loop', INFERENCE_STOPPED, BubbleKind.LOOP);
          }
          return;
        }
        if (event.kind === AgentEventKind.ERROR) {
          this.dropLivePlaceholder();
        }
        this.addEvent(event);
      };
      const conversation = this.buildRemoteConversation();
      // 不拆分的 Agent 直接走下面的单模型工具循环。拆分模式才把独立子任务分到空闲算力。
      // 带图请求同样不拆：并行分支会为每个子任务新建 RemoteComputeModel，附图只注入到
      // 上面这一个主模型。
      let handled = false;
      if (imagePayload.length === 0 && mode === 'agent_split') {
        const parallel = this.createParallelRunner(generation, tools, skillSnapshot);
        this.activeParallel = parallel;
        handled = await parallel.tryRun(task, conversation, this.parallelObserver(generation, reporter), listener, startedAt + 300000, reporter.id);
      }
      if (!handled && this.isCurrentRemoteRun(generation)) {
        this.parallelHeader = '';
        this.parallelViews = [];
        this.setLivePhase(LIVE_PLACEHOLDER);
        await runner.run(task, listener, conversation, { namespace: '', goals: [], evidence: [], deadlineAt: startedAt + 300000 });
      }
    } catch (error) {
      if (this.isCurrentRemoteRun(generation)) {
        this.dropLivePlaceholder();
        const message = error instanceof Error ? error.message : '远程推理失败';
        failureText = message;
        this.appendLine('Error', message, BubbleKind.ERROR);
      }
    } finally {
      reporter?.finish(this.isCurrentRemoteRun(generation) ?
        (finalAnswer !== null ? (finalPartial ? 'partial' : 'done') : 'failed') : 'cancelled', finalAnswer ?? failureText);
      if (this.activeTaskReporter === reporter) this.activeTaskReporter = null;
      // A disposed or superseded run must not clear the next run's listeners
      // or persist a late answer. Stop invalidates the generation immediately.
      if (this.pageActive && generation === this.remoteRunGeneration) {
        this.updateTaskProgress(finalAnswer !== null ? (finalPartial ? 'partial' : 'done') : 'failed');
        this.finishInferenceMetricsTask();
        if (!this.stopRequested && finalAnswer !== null) {
          // A partial report keeps the question for follow-ups but is not a
          // resolved answer that later turns may treat as established context.
          this.conversation.addUser(display);
          this.conversation.addAssistant(finalPartial ? PARTIAL_HISTORY_NOTE : finalAnswer);
          saveConversation(this.getAbilityContext(), this.conversation);
        } else {
          this.dropLivePlaceholder();
        }
        this.sending = false;
        this.stopRequested = false;
        this.activeRunner = null;
        this.activeParallel = null;
        this.parallelHeader = '';
        this.parallelViews = [];
        this.liveReplyId = -1;
        this.liveReplyPending = false;
        this.processId = -1;
        this.setCollaborationKeepScreenOn(false);
      }
    }
  }

  private beginTaskProgress(kind: string, startedAt: number): void {
    const bubble = this.createChatBubble('Task', '', BubbleKind.TASK);
    bubble.taskProgress = { kind: kind, phase: 'preparing', startedAt: startedAt, endedAt: 0 };
    this.activeTaskProgressId = bubble.id;
    this.messages = [...this.messages, bubble];
    this.scroller.scrollEdge(Edge.Bottom);
  }

  private updateTaskProgress(phase: TaskProgressPhase): void {
    if (this.activeTaskProgressId < 0) { return; }
    const next: ChatBubble[] = [];
    for (const bubble of this.messages) {
      const progress = bubble.taskProgress;
      if (bubble.id !== this.activeTaskProgressId || progress === undefined || !taskProgressActive(progress.phase)) {
        next.push(bubble);
        continue;
      }
      next.push({
        id: bubble.id, speaker: bubble.speaker, text: bubble.text, kind: bubble.kind,
        imagePath: bubble.imagePath, collapsible: false, expanded: false, revision: bubble.revision + 1,
        taskProgress: {
          kind: progress.kind, phase: phase, startedAt: progress.startedAt,
          endedAt: taskProgressActive(phase) ? 0 : Date.now()
        }
      });
    }
    this.messages = next;
    if (!taskProgressActive(phase)) { this.activeTaskProgressId = -1; }
  }

  private createParallelRunner(generation: number, tools: ToolRegistry, skillSnapshot: SkillSnapshot): ParallelTaskRunner {
    // Owners are per run and per sub-task, so stopping one never cancels another's requests.
    const owner = (name: string): string => 'p' + generation.toString() + ':' + name;
    const deps: ParallelDeps = {
      modelFor: (id: string, hooks: SubtaskModelHooks): LocalModel =>
        new RemoteComputeModel({ owner: owner(id), onAccepted: hooks.onAccepted, label: hooks.label,
          taskId: hooks.taskId, subtaskId: hooks.subtaskId }),
      splitModel: (taskId?: string): LocalModel => new RemoteComputeModel({ owner: owner('split'), label: '任务拆分', taskId: taskId, subtaskId: 'plan' }),
      mergeModel: (taskId?: string): LocalModel => new RemoteComputeModel({ owner: owner('merge'), label: '合并结果', taskId: taskId, subtaskId: 'merge' }),
      tools: tools,
      skills: skillSnapshot,
      maxSteps: MAX_STEPS,
      maxPromptBytes: (): number => inferenceClient.promptBudgetBytes(),
      load: (): ClusterSize => {
        const info = inferenceClient.clusterLoad();
        const size: ClusterSize = { idle: info.idle, total: info.total };
        return size;
      }
    };
    return new ParallelTaskRunner(deps);
  }

  /** Sub-task rows live in the placeholder bubble until the merged answer replaces it. */
  private parallelObserver(generation: number, reporter?: TaskReporter): ParallelObserver {
    const observer: ParallelObserver = {
      onTask: (task: ParallelTaskSnapshot): void => {
        if (!this.isCurrentRemoteRun(generation) && task.phase !== 'cancelled') { return; }
        const subtasks: TaskChildSnapshot[] = [];
        for (const child of task.subtasks) {
          const copy: TaskChildSnapshot = {
            id: child.id, title: child.title, input: child.input, activity: child.activity, device: child.device, phase: child.phase,
            detail: child.detail, result: child.result, resultTruncated: child.resultTruncated,
            startedAt: child.startedAt, endedAt: child.endedAt
          };
          subtasks.push(copy);
        }
        const snapshot: TaskSnapshot = {
          id: task.id, title: task.title, phase: task.phase, revision: task.revision,
          startedAt: task.startedAt, endedAt: task.endedAt, answer: task.answer, answerTruncated: task.answerTruncated, subtasks: subtasks
        };
        if (reporter !== undefined) reporter.update(snapshot);
        else inferenceClient.publishTask(snapshot);
      },
      onPhase: (text: string): void => {
        if (!this.isCurrentRemoteRun(generation)) { return; }
        this.beginLiveReply();
        this.parallelHeader = text;
        this.renderParallel();
      },
      onPlan: (views: SubtaskView[]): void => {
        if (!this.isCurrentRemoteRun(generation)) { return; }
        this.beginLiveReply();
        this.parallelViews = views;
        this.parallelHeader = '已拆分为 ' + views.length.toString() + ' 个独立任务，并行处理：';
        this.renderParallel();
      },
      onProcess: (event: AgentEvent): void => {
        if (!this.isCurrentRemoteRun(generation)) { return; }
        this.appendProcess(event);
      },
      onUpdate: (view: SubtaskView): void => {
        if (!this.isCurrentRemoteRun(generation)) { return; }
        this.parallelViews = this.parallelViews.map((item: SubtaskView): SubtaskView => item.id === view.id ? view : item);
        this.renderParallel();
      }
    };
    return observer;
  }

  private renderParallel(): void {
    let text = this.parallelHeader;
    for (let index = 0; index < this.parallelViews.length; index++) {
      const view = this.parallelViews[index];
      text += '\n' + (index + 1).toString() + '. ' + view.title +
        (view.device.length > 0 ? ' · ' + view.device : '') + ' · ' + view.detail;
    }
    this.setLivePhase(text);
  }

  private sendEnabled(): boolean {
    return this.sending || this.canSend();
  }

  private stopGeneration(): void {
    if (!this.sending) { return; }
    this.updateTaskProgress('cancelled');
    this.stopRequested = true;
    this.remoteRunGeneration++;
    this.activeRunner?.requestStop();
    this.activeRunner = null;
    this.activeParallel?.requestStop();
    this.activeTaskReporter?.finish('cancelled');
    this.activeTaskReporter = null;
    this.activeParallel = null;
    inferenceClient.cancelActive();
    this.dropLivePlaceholder();
    this.finishInferenceMetricsTask();
    this.sending = false;
    this.linkBusy = false;
    this.processId = -1;
    this.setCollaborationKeepScreenOn(false);
    if (this.pageActive) { this.appendLine('Loop', INFERENCE_STOPPED, BubbleKind.LOOP); }
  }

  private beginLiveReply(): void {
    if (this.liveReplyId >= 0) {
      return;
    }
    const bubble = this.createChatBubble('Loop', LIVE_PLACEHOLDER, BubbleKind.LOOP);
    this.liveReplyId = bubble.id;
    this.liveReplyPending = true;
    this.messages = [...this.messages, bubble];
    this.scroller.scrollEdge(Edge.Bottom);
  }

  /** Placeholder text names what the run is waiting on; only FINAL replaces it with an answer. */
  private setLivePhase(text: string): void {
    if (this.liveReplyId < 0 || !this.liveReplyPending) {
      return;
    }
    const next: ChatBubble[] = [];
    for (const current of this.messages) {
      if (current.id !== this.liveReplyId || current.text === text) {
        next.push(current);
        continue;
      }
      next.push({
        id: current.id,
        speaker: current.speaker,
        text: text,
        kind: current.kind,
        imagePath: current.imagePath,
        collapsible: false,
        expanded: false,
        revision: current.revision + 1
      });
    }
    this.messages = next;
  }

  private dropLivePlaceholder(): void {
    if (this.liveReplyId < 0) {
      return;
    }
    const target = this.liveReplyId;
    const next: ChatBubble[] = [];
    for (const current of this.messages) {
      if (current.id !== target) {
        next.push(current);
        continue;
      }
      if (current.text !== LIVE_PLACEHOLDER && !this.liveReplyPending) {
        next.push(current);
      }
    }
    this.messages = next;
    this.liveReplyId = -1;
    this.liveReplyPending = false;
  }

  private commitLiveAnswer(text: string): void {
    const visible = text.trim();
    if (visible.length === 0) {
      return;
    }
    if (this.liveReplyId < 0) {
      const bubble = this.createChatBubble('Loop', visible, BubbleKind.LOOP);
      this.liveReplyId = bubble.id;
      this.liveReplyPending = false;
      this.messages = [...this.messages, bubble];
      this.scroller.scrollEdge(Edge.Bottom);
      return;
    }
    const next: ChatBubble[] = [];
    let found = false;
    for (const current of this.messages) {
      if (current.id !== this.liveReplyId) {
        next.push(current);
        continue;
      }
      found = true;
      next.push({
        id: current.id,
        speaker: current.speaker,
        text: visible,
        kind: current.kind,
        imagePath: current.imagePath,
        collapsible: this.shouldCollapseBubble(visible),
        expanded: false,
        revision: current.revision + 1
      });
    }
    if (!found) {
      const bubble = this.createChatBubble('Loop', visible, BubbleKind.LOOP);
      this.liveReplyId = bubble.id;
      next.push(bubble);
    }
    this.liveReplyPending = false;
    this.messages = next;
    this.scroller.scrollEdge(Edge.Bottom);
  }

  /**
   * Model deltas are protocol text, not verified user-facing answers. Keep the
   * placeholder visible until ReActAgentRunner emits a checked FINAL event.
   */
  private showLiveReply(_text: string): void {
    // Intentionally do not render partial Execution/Action/Final text here.
    // A Final-looking prefix may still be followed by another tool call or a
    // validation retry, so only commitLiveAnswer() may update the answer bubble.
  }

  private appendProcess(event: AgentEvent): void {
    const label = event.kind === AgentEventKind.ACTION ? '行动' :
      (event.kind === AgentEventKind.OBSERVATION ? '观察' :
        (event.kind === AgentEventKind.SKILL ? '技能' : '思考'));
    let body = event.text.trim();
    if (body.startsWith('Observation:')) {
      body = body.substring('Observation:'.length).trim();
    }
    const line = `${label}：${body}`;
    if (this.processId < 0) {
      const bubble = this.createProcessBubble(line);
      this.processId = bubble.id;
      this.insertBeforeAnswer(bubble);
      return;
    }
    const next: ChatBubble[] = [];
    for (const current of this.messages) {
      if (current.id !== this.processId) {
        next.push(current);
        continue;
      }
      next.push({
        id: current.id,
        speaker: current.speaker,
        text: `${current.text}\n${line}`,
        kind: current.kind,
        imagePath: current.imagePath,
        collapsible: true,
        expanded: current.expanded,
        revision: current.revision + 1
      });
    }
    this.messages = next;
  }

  private createProcessBubble(text: string): ChatBubble {
    const bubble: ChatBubble = {
      id: this.nextChatBubbleId,
      speaker: 'Process',
      text: text,
      kind: BubbleKind.PROCESS,
      imagePath: '',
      collapsible: true,
      expanded: false,
      revision: 0
    };
    this.nextChatBubbleId += 1;
    return bubble;
  }

  private insertBeforeAnswer(bubble: ChatBubble): void {
    if (this.liveReplyId < 0) {
      this.messages = [...this.messages, bubble];
      return;
    }
    const next: ChatBubble[] = [];
    let inserted = false;
    for (const current of this.messages) {
      if (!inserted && current.id === this.liveReplyId) {
        next.push(bubble);
        inserted = true;
      }
      next.push(current);
    }
    if (!inserted) {
      next.push(bubble);
    }
    this.messages = next;
  }

  private canSend(): boolean {
    return !this.sending && (this.message.trim().length > 0 || this.pendingPath.length > 0);
  }

  private clearAttachment(): void {
    this.pendingKind = '';
    this.pendingName = '';
    this.pendingPath = '';
    this.pendingLocal = '';
  }

  private async chooseAttachment(): Promise<void> {
    this.attachError = '';
    try {
      const saved: SavedAttachment | null = await pickAttachment();
      if (saved === null) {
        return;
      }
      this.pendingKind = saved.kind;
      this.pendingName = saved.name;
      this.pendingPath = saved.relativePath;
      this.pendingLocal = saved.localPath;
    } catch (error) {
      this.attachError = error instanceof Error ? error.message : '附件选择失败';
    }
  }

  private composeAttachmentTask(text: string): string {
    if (this.pendingKind === 'image') {
      // 图片以裸 base64 随 infer.request 的 image 字段发出（见 ImageEncode / InferenceClient）。
      // 文字只保留「（附图）」前缀 + 用户原话：算力端 VL 通道会剥掉该前缀
      // （VlLlmTransport.buildPrompt）。绝不能再把本地路径当正文发出去 ——
      // 那是聊天机沙盒内的相对路径，算力端读不到，只会让模型答"看不到图片"。
      return text.length > 0 ? `（附图）${text}` : '（附图）请描述这张图片。';
    }
    const lead = text.length > 0 ? text : '请阅读附件。';
    const excerpt = readTextExcerpt(this.pendingPath);
    let body = `${lead}\n附件：${this.pendingName}，路径 ${this.pendingPath}。`;
    if (excerpt.length > 0) {
      body += `\n附件正文：\n${excerpt}`;
    } else {
      body += '\n该附件不是可直接阅读的 txt、md、json 或 csv，当前只能看到文件名。';
    }
    return body;
  }

  private async runAgent(): Promise<void> {
    const text = this.message.trim();
    const hasFile = this.pendingPath.length > 0;
    if ((text.length === 0 && !hasFile) || this.sending) {
      return;
    }
    const task = hasFile ? this.composeAttachmentTask(text) : text;
    const shown = text.length > 0 ? text : (this.pendingKind === 'image' ? '（附图）' : this.pendingName);
    const imagePath = this.pendingKind === 'image' ? this.pendingLocal : '';
    // 先把图片压成协议可承载的裸 base64 再发送；编码失败就不发请求，保留草稿与附件。
    let imagePayload = '';
    if (imagePath.length > 0) {
      try {
        imagePayload = await encodeLocalImageBase64(imagePath);
      } catch (error) {
        this.appendLine('Error', error instanceof Error ? error.message : '图片编码失败', BubbleKind.ERROR);
        return;
      }
      if (imagePayload.length === 0) {
        this.appendLine('Error', '图片编码失败，未发送请求', BubbleKind.ERROR);
        return;
      }
    }
    this.message = '';
    this.clearAttachment();
    await this.runRemoteAgent(task, shown, imagePath, imagePayload);
  }
  /** Most recent whole exchanges within a fixed budget, oldest dropped first. */
  private buildRemoteConversation(): ConversationContext {
    const turns = this.conversation.toChatMessages();
    let start = Math.max(0, turns.length - REMOTE_HISTORY_TURNS);
    while (start < turns.length && turns[start].role !== ConversationRole.USER) {
      start++;
    }
    let characterCount = 0;
    for (let index = start; index < turns.length; index++) {
      characterCount += turns[index].content.length;
    }
    while (start < turns.length && characterCount > REMOTE_HISTORY_MAX_CHARS) {
      characterCount -= turns[start].content.length;
      start++;
      while (start < turns.length && turns[start].role !== ConversationRole.USER) {
        characterCount -= turns[start].content.length;
        start++;
      }
    }
    return ConversationContext.fromMessages(turns.slice(start));
  }

  private buildCollaborationConversation(): ConversationContext {
    const turns = this.conversation.toChatMessages();
    const start = Math.max(0, turns.length - COLLABORATION_HISTORY_TURNS);
    const recentTurns = turns.slice(start);
    let characterCount = 0;
    for (const turn of recentTurns) {
      characterCount += turn.content.length;
    }
    if (characterCount > COLLABORATION_HISTORY_MAX_CHARS) {
      return new ConversationContext();
    }
    return ConversationContext.fromMessages(recentTurns);
  }

  private async initializeModel(context: common.UIAbilityContext): Promise<void> {
    const binding = await getLocalLlmBinding();
    const modelInfo = await createLoopModelInfo(context, undefined, binding ?? undefined);
    this.updateModelStatus(modelInfo.mode, modelInfo.modelName);
    if (binding === null) {
      return;
    }

    const config = await LlmProvider.readLocalLlmConfig(context);
    const collaboration = config.collaboration;
    if (config.enabled && config.benchmarkDirect) {
      this.updateModelStatus('local', collaboration.enabled
        ? 'Qwen2.5-7B-Instruct (Gewu Collaboration) Direct Benchmark'
        : 'Qwen2.5-7B-Instruct (Gewu) Direct Benchmark');
    }
    if (!config.enabled) {
      return;
    }
    this.collaborationIsMaster = collaboration.isMaster;
    this.collaborationVisible = true;
    this.collaborationStatus = 'disabled';
    this.collaborationStatusText = '点击「开始协同」启动';
  }

  private prepareCollaborationSession(): void {
    const controller = this.collabController;
    if (controller !== null) {
      if (controller.isMasterDevice()) {
        controller.prewarmSession();
      }
      return;
    }
    this.ensureSingleDeviceSession().catch((_error: Error): void => {});
  }

  /** Return the page-owned single-device model, creating its native Session exactly once. */
  private async ensureSingleDeviceSession(): Promise<SessionBackedModel | null> {
    if (this.collabController !== null) {
      return null;
    }
    if (this.singleDeviceModel !== null) {
      return this.singleDeviceModel;
    }
    if (this.singleDeviceSessionPromise !== null) {
      return await this.singleDeviceSessionPromise;
    }
    const generation = this.singleDeviceSessionGeneration;
    const pending = this.createSingleDeviceSession(generation);
    this.singleDeviceSessionPromise = pending;
    try {
      return await pending;
    } finally {
      if (this.singleDeviceSessionPromise === pending) {
        this.singleDeviceSessionPromise = null;
      }
    }
  }

  private async createSingleDeviceSession(generation: number): Promise<SessionBackedModel | null> {
    const context = this.getAbilityContext();
    const binding = await getLocalLlmBinding();
    if (binding === null || generation !== this.singleDeviceSessionGeneration || this.collabController !== null) {
      return null;
    }
    const modelInfo = await createLoopModelInfo(context, undefined, binding);
    if (modelInfo.mode !== 'local' || !(modelInfo.model instanceof SessionBackedModel)) {
      return null;
    }
    const model = modelInfo.model as SessionBackedModel;
    model.setResponseListener(this.handleSingleDeviceInferenceResponse);
    if (generation !== this.singleDeviceSessionGeneration || this.collabController !== null) {
      model.dispose();
      return null;
    }
    if (!model.prepareSession()) {
      model.dispose();
      return null;
    }
    if (generation !== this.singleDeviceSessionGeneration || this.collabController !== null) {
      model.dispose();
      return null;
    }
    this.singleDeviceModel = model;
    return model;
  }

  private handleSingleDeviceInferenceResponse = (response: string, requestId: number): void => {
    let formatted = response;
    try {
      const parsed = JSON.parse(response) as Object;
      formatted = JSON.stringify(parsed, null, 2);
    } catch (_error) {
      // Keep the original payload visible if the native callback returns text.
    }
    hilog.info(LOG_DOMAIN, LOG_TAG, 'single-device inference response:\n%{public}s', formatted);
    this.updateInferenceMetrics(response, requestId);
  };

  private handleCollaborationInferenceResponse = (response: string, requestId: number): void => {
    this.updateInferenceMetrics(response, requestId);
  };

  private updateInferenceMetrics(response: string, requestId: number): void {
    if (!this.inferenceMetricsRunActive || !this.inferenceMetricsActiveRequestIds.has(requestId) ||
      this.inferenceMetricsRecordedRequestIds.has(requestId)) {
      return;
    }
    try {
      const envelope = JSON.parse(response) as InferenceUsageEnvelope;
      if (envelope.finish_reason === null || envelope.finish_reason === undefined || envelope.usage === undefined) {
        return;
      }
      const usage = envelope.usage;
      const promptTokens = usage.prompt_tokens;
      const completionTokens = usage.completion_tokens;
      const prefillLatencyMs = usage.prefill_latency;
      const decodeLatencyMs = usage.decode_latency;
      const deviceCount = usage.device_num;
      if (promptTokens === undefined || completionTokens === undefined || prefillLatencyMs === undefined ||
        decodeLatencyMs === undefined || deviceCount === undefined || !Number.isFinite(promptTokens) ||
        !Number.isFinite(completionTokens) || !Number.isFinite(prefillLatencyMs) ||
        !Number.isFinite(decodeLatencyMs) || !Number.isFinite(deviceCount) || prefillLatencyMs < 0 ||
        decodeLatencyMs < 0) {
        return;
      }
      const prefillSeconds = prefillLatencyMs / 1000;
      const decodeSeconds = decodeLatencyMs / 1000;
      const prefillSpeed = prefillSeconds > 0 ? promptTokens / prefillSeconds : 0;
      const decodeSpeed = decodeSeconds > 0 ? completionTokens / decodeSeconds : 0;
      this.inferenceMetricsRecordedRequestIds.add(requestId);
      this.inferenceMetricsTotalPrefillLatencyMs += prefillLatencyMs;
      this.inferenceMetricsTotalDecodeLatencyMs += decodeLatencyMs;
      const runId = this.inferenceMetricsRunId;
      const page: InferenceMetricsPage = {
        kind: InferenceMetricsPageKind.CALL,
        deviceCount: Math.floor(deviceCount).toString(),
        promptLength: Math.floor(promptTokens).toString(),
        decodeLength: Math.floor(completionTokens).toString(),
        prefillSpeed: prefillSpeed.toFixed(2) + ' token/s',
        decodeSpeed: decodeSpeed.toFixed(2) + ' token/s',
        prefillDuration: prefillSeconds.toFixed(3) + ' s',
        decodeDuration: decodeSeconds.toFixed(3) + ' s',
        taskDuration: '',
        callCount: ''
      };
      setTimeout((): void => {
        if (runId !== this.inferenceMetricsRunId) {
          return;
        }
        this.inferenceMetricsPages = [...this.inferenceMetricsPages, page];
        hilog.info(LOG_DOMAIN, LOG_TAG,
          'inference metrics call=%{public}d requestId=%{public}d prompt=%{public}s decode=%{public}s ' +
          'prefill=%{public}s decodeTime=%{public}s',
          this.inferenceMetricsPages.length, requestId, page.promptLength, page.decodeLength,
          page.prefillDuration, page.decodeDuration);
        this.selectInferenceMetricsPage(this.inferenceMetricsPages.length - 1);
      }, 0);
    } catch (_error) {
      // Streaming chunks without a valid usage payload are intentionally ignored.
    }
  }

  private handleInferenceRequestStarted = (requestId: number): void => {
    if (this.inferenceMetricsRunActive) {
      this.inferenceMetricsActiveRequestIds.add(requestId);
    }
  };

  private prepareInferenceMetricsTask(): void {
    this.inferenceMetricsRunId += 1;
    this.inferenceMetricsTotalPrefillLatencyMs = 0;
    this.inferenceMetricsTotalDecodeLatencyMs = 0;
    this.inferenceMetricsRunActive = true;
    this.inferenceMetricsDismissed = false;
    this.inferenceMetricsActiveRequestIds = new Set<number>();
    this.inferenceMetricsRecordedRequestIds = new Set<number>();
    this.inferenceMetricsPages = [];
    this.inferenceMetricsPageIndex = 0;
    this.inferenceMetricsSummaryPage = false;
    this.inferenceMetricsVisible = false;
  }

  private finishInferenceMetricsTask(): void {
    if (!this.inferenceMetricsRunActive) {
      return;
    }
    this.inferenceMetricsRunActive = false;
    if (this.inferenceMetricsRecordedRequestIds.size === 0) {
      return;
    }
    const runId = this.inferenceMetricsRunId;
    const totalPrefillSeconds = Math.max(0, this.inferenceMetricsTotalPrefillLatencyMs) / 1000;
    const totalDecodeSeconds = Math.max(0, this.inferenceMetricsTotalDecodeLatencyMs) / 1000;
    const totalLatencySeconds = totalPrefillSeconds + totalDecodeSeconds;
    const recordedCallCount = this.inferenceMetricsRecordedRequestIds.size;
    setTimeout((): void => {
      if (runId !== this.inferenceMetricsRunId) {
        return;
      }
      const summary: InferenceMetricsPage = {
        kind: InferenceMetricsPageKind.SUMMARY,
        deviceCount: '',
        promptLength: '',
        decodeLength: '',
        prefillSpeed: '',
        decodeSpeed: '',
        prefillDuration: totalPrefillSeconds.toFixed(3) + ' s',
        decodeDuration: totalDecodeSeconds.toFixed(3) + ' s',
        taskDuration: totalLatencySeconds.toFixed(3) + ' s',
        callCount: recordedCallCount.toString()
      };
      this.inferenceMetricsPages = [...this.inferenceMetricsPages, summary];
      this.selectInferenceMetricsPage(this.inferenceMetricsPages.length - 1);
    }, 0);
  }

  private dismissInferenceMetricsCard(): void {
    this.inferenceMetricsDismissed = true;
    this.inferenceMetricsVisible = false;
  }

  private inferenceMetricsPageLabel(): string {
    const pageNumber = this.inferenceMetricsPageIndex + 1;
    const pageCount = this.inferenceMetricsPages.length;
    if (this.inferenceMetricsSummaryPage) {
      return `总耗时  ${pageNumber} / ${pageCount}`;
    }
    return `第 ${pageNumber} 次调用  ·  ${pageNumber} / ${pageCount}`;
  }

  private selectInferenceMetricsPage(index: number): void {
    if (index < 0 || index >= this.inferenceMetricsPages.length) {
      return;
    }
    const page = this.inferenceMetricsPages[index];
    // ArkUI can retain the Text nodes created inside this Builder even after
    // its @Prop inputs change. Remove the whole card for one event-loop turn
    // so every page switch mounts fresh nodes with this page's values.
    this.inferenceMetricsVisible = false;
    this.inferenceMetricsPageIndex = index;
    this.inferenceMetricsSummaryPage = page.kind === InferenceMetricsPageKind.SUMMARY;
    this.inferenceDeviceCount = page.deviceCount;
    this.inferencePromptLength = page.promptLength;
    this.inferenceDecodeLength = page.decodeLength;
    this.inferencePrefillSpeed = page.prefillSpeed;
    this.inferenceDecodeSpeed = page.decodeSpeed;
    this.inferencePrefillDuration = page.prefillDuration;
    this.inferenceDecodeDuration = page.decodeDuration;
    this.inferenceTaskDuration = page.taskDuration;
    this.inferenceCallCount = page.callCount;
    const runId = this.inferenceMetricsRunId;
    setTimeout((): void => {
      if (runId === this.inferenceMetricsRunId && index === this.inferenceMetricsPageIndex &&
        !this.inferenceMetricsDismissed) {
        this.inferenceMetricsVisible = true;
      }
    }, 0);
  }

  private disposeSingleDeviceSession(): void {
    this.singleDeviceSessionGeneration += 1;
    this.singleDeviceSessionPromise = null;
    const model = this.singleDeviceModel;
    this.singleDeviceModel = null;
    model?.dispose();
  }

  private restartSingleDeviceSession(): void {
    this.disposeSingleDeviceSession();
    this.ensureSingleDeviceSession().catch((_error: Error): void => {});
  }

  private switchCollaborationRole(): void {
    this.collaborationIsMaster = !this.collaborationIsMaster;
    if (this.collabController !== null) {
      this.appendLine('Collaboration', `角色已切换为${this.collaborationIsMaster ? '主机' : '协作者'}，请关闭后重新开始协同。`, BubbleKind.LOOP);
    }
  }

  private async startCollaboration(): Promise<void> {
    if (this.collabController !== null) {
      this.appendLine('Collaboration', '协同已启动，请先关闭再重新开始。', BubbleKind.ERROR);
      return;
    }
    this.sending = true;
    try {
      const context = this.getAbilityContext();
      const binding = await getLocalLlmBinding();
      if (binding === null) {
        this.appendLine('Error', '本地 LLM 绑定不可用，无法启动协同。', BubbleKind.ERROR);
        return;
      }
      const config = await LlmProvider.readLocalLlmConfig(context);
      if (!config.enabled) {
        this.appendLine('Error', '本地 LLM 未启用 (useLocalLlm=false)，无法启动协同。', BubbleKind.ERROR);
        return;
      }
      const collaborationInfo = buildLocalCollaborationInfo({
        isMaster: this.collaborationIsMaster,
        masterIP: config.collaboration.masterIP,
        masterPort: config.collaboration.masterPort
      });
      const sessionAttributes = buildLocalSessionAttributes(config.modelPath, {
        backend: config.backend,
        maxContext: config.maxContext
      });
      if (collaborationInfo === undefined || sessionAttributes === undefined) {
        this.appendLine('Error', '协同参数无效，请检查 llm_config.json 配置。', BubbleKind.ERROR);
        return;
      }
      // A standalone and a distributed Gewu Session must not overlap. The
      // collaboration controller will create its own master/co-session pair.
      this.disposeSingleDeviceSession();
      this.setCollaborationKeepScreenOn(true);
      this.collaborationVisible = true;
      this.collaborationStatus = 'connecting';
      this.collaborationStatusText = this.collaborationIsMaster ? '正在等待协作者连接' : '正在连接主机';
      const controller = new CollaborationController(binding, {
        collaborationInfo: collaborationInfo,
        sessionAttributes: sessionAttributes,
        collaboratorSessionAttributes: (caller: number): string | undefined =>
          buildLocalSessionAttributes(config.modelPath, {
            backend: config.backend,
            maxContext: config.maxContext,
            parallel: { caller: caller, isCo: true }
          }),
        requestType: config.requestType,
        broadcastPort: config.collaboration.broadcastPort,
        masterIP: config.collaboration.masterIP,
        masterPort: config.collaboration.masterPort,
        controlPort: config.collaboration.controlPort,
        isMaster: this.collaborationIsMaster,
        inferenceResponseListener: this.handleCollaborationInferenceResponse
      });
      controller.setStatusListener((status: CollaborationStatus, detail: string): void => {
        setTimeout(() => {
          this.collaborationStatus = status;
          this.collaborationStatusText = detail;
        }, 0);
      });
      if (!await controller.init()) {
        await controller.dispose();
        this.setCollaborationKeepScreenOn(false);
        this.appendLine('Error', '协同初始化失败，请查看日志。', BubbleKind.ERROR);
        return;
      }
      this.collabController = controller;
      this.updateModelStatus('local', this.collaborationIsMaster
        ? 'Qwen2.5-7B-Instruct (Gewu Collaboration)'
        : 'Qwen2.5-7B-Instruct (Gewu Collaboration)');
      this.appendLine('Collaboration',
        `协同已启动，角色：${this.collaborationIsMaster ? '主机' : '协作者'}。`, BubbleKind.LOOP);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      this.appendLine('Error', `启动协同异常：${message}`, BubbleKind.ERROR);
    } finally {
      this.sending = false;
    }
  }

  private async stopCollaboration(): Promise<void> {
    const controller = this.collabController;
    if (controller === null) {
      return;
    }
    this.collabController = null;
    this.collaborationStatus = 'disabled';
    this.collaborationStatusText = '协同未启用';
    this.setCollaborationKeepScreenOn(false);
    this.sending = true;
    try {
      await controller.dispose();
      this.appendLine('Collaboration', '协同已关闭。', BubbleKind.LOOP);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      this.appendLine('Error', `关闭协同失败：${message}`, BubbleKind.ERROR);
    } finally {
      this.sending = false;
    }
  }

  private collaborationStatusColor(): Color {
    if (this.collaborationStatus === 'connected' || this.collaborationStatus === 'ready') {
      return Color.Green;
    }
    if (this.collaborationStatus === 'connecting' || this.collaborationStatus === 'preparing') {
      return Color.Orange;
    }
    if (this.collaborationStatus === 'error' || this.collaborationStatus === 'disconnected') {
      return Color.Red;
    }
    return Color.Gray;
  }

  private setCollaborationKeepScreenOn(enabled: boolean): void {
    if (this.collaborationKeepsScreenOn === enabled) {
      return;
    }
    this.collaborationKeepsScreenOn = enabled;
    window.getLastWindow(this.getAbilityContext()).then((appWindow: window.Window): void => {
      appWindow.setWindowKeepScreenOn(enabled).catch((_error: Error): void => {});
    }).catch((_error: Error): void => {});
  }

  private updateModelStatus(mode: 'llm' | 'scripted' | 'local', modelName: string): void {
    if (mode === 'llm') {
      this.modelStatus = `LLM: ${modelName}`;
    } else if (mode === 'local') {
      this.modelStatus = `Local LLM: ${modelName}`;
    } else {
      this.modelStatus = 'Offline demo (no API key — add entry/.../rawfile/llm_config.json)';
    }
  }

  private restoreConversation(): void {
    this.conversation = loadConversation(this.getAbilityContext());
    this.messages = this.buildMessagesFromConversation(this.conversation);
  }

  private buildMessagesFromConversation(conversation: ConversationContext): ChatBubble[] {
    const turns = conversation.toChatMessages();
    const bubbles: ChatBubble[] = [];
    for (const turn of turns) {
      const isUser = turn.role === ConversationRole.USER;
      bubbles.push(this.createChatBubble(
        isUser ? 'You' : 'Loop',
        turn.content,
        isUser ? BubbleKind.USER : BubbleKind.LOOP
      ));
    }
    return bubbles;
  }

  private clearConversation(): void {
    this.conversation.clear();
    clearStoredConversation(this.getAbilityContext());
    this.messages = [];
    this.activeTaskProgressId = -1;
    this.liveReplyId = -1;
    this.liveReplyPending = false;
    this.processId = -1;
    const controller = this.collabController;
    if (controller !== null) {
      controller.onClear();
    } else {
      this.restartSingleDeviceSession();
    }
  }

  private addEvent(event: AgentEvent): void {
    switch (event.kind) {
      case AgentEventKind.THOUGHT:
        this.appendLine('Loop', event.text, BubbleKind.LOOP);
        break;
      case AgentEventKind.SKILL:
        this.appendLine('Skill', event.text === 'none' ? 'none (continue with tools)' : event.text, BubbleKind.SKILL);
        break;
      case AgentEventKind.ACTION:
        this.appendLine('Tool', event.text, BubbleKind.TOOL);
        break;
      case AgentEventKind.OBSERVATION:
        this.appendLine('Observation', event.text, BubbleKind.OBSERVATION);
        break;
      case AgentEventKind.FINAL:
        this.appendLine('Loop', event.text, BubbleKind.LOOP);
        break;
      case AgentEventKind.ERROR:
      default:
        this.appendLine('Error', event.text, BubbleKind.ERROR);
        break;
    }
  }

  private appendUserMessage(message: string, imagePath: string = ''): void {
    this.appendLine('You', message, BubbleKind.USER, imagePath);
  }

  private appendLine(speaker: string, text: string, kind: BubbleKind, imagePath: string = ''): void {
    this.messages = [...this.messages, this.createChatBubble(speaker, text, kind, imagePath)];
    this.scroller.scrollEdge(Edge.Bottom);
  }

  private createChatBubble(speaker: string, text: string, kind: BubbleKind, imagePath: string = ''): ChatBubble {
    const bubble: ChatBubble = {
      id: this.nextChatBubbleId,
      speaker: speaker,
      text: text,
      kind: kind,
      imagePath: imagePath,
      collapsible: this.shouldCollapseBubble(text),
      expanded: false,
      revision: 0
    };
    this.nextChatBubbleId += 1;
    return bubble;
  }

  private shouldCollapseBubble(text: string): boolean {
    try {
      const size = this.getUIContext().getMeasureUtils().measureTextSize({
        textContent: text,
        constraintWidth: `${this.chatBubbleTextWidthVp}vp`,
        fontSize: '15fp',
        lineHeight: '22vp'
      });
      const heightPx = Number(size.height);
      const lineHeightPx = this.getUIContext().vp2px(22);
      if (Number.isFinite(heightPx) && lineHeightPx > 0) {
        return heightPx > lineHeightPx * 10 + 0.5;
      }
    } catch (_error) {
      // Fall through to the compatible estimate when measurement is unavailable.
    }
    return this.estimateBubbleLineCount(text) > 10;
  }

  private estimateBubbleLineCount(text: string): number {
    const asciiUnitWidthVp = 7.5;
    const unitsPerLine = Math.max(1, Math.floor(this.chatBubbleTextWidthVp / asciiUnitWidthVp));
    const paragraphs = text.split('\n');
    let lines = 0;
    for (const paragraph of paragraphs) {
      let units = 0;
      for (let index = 0; index < paragraph.length; index++) {
        units += paragraph.charCodeAt(index) <= 0x7F ? 1 : 2;
      }
      lines += Math.max(1, Math.ceil(units / unitsPerLine));
    }
    return lines;
  }

  private updateChatBubbleMeasureWidth(scrollWidthVp: number): void {
    if (!Number.isFinite(scrollWidthVp) || scrollWidthVp <= 0) {
      return;
    }
    const nextWidthVp = Math.max(80, (scrollWidthVp - 8) * 0.82 - 24);
    if (Math.abs(nextWidthVp - this.chatBubbleTextWidthVp) < 1) {
      return;
    }
    this.chatBubbleTextWidthVp = nextWidthVp;
    let changed = false;
    const nextMessages: ChatBubble[] = [];
    for (const current of this.messages) {
      const collapsible = current.kind === BubbleKind.PROCESS || this.shouldCollapseBubble(current.text);
      if (collapsible === current.collapsible) {
        nextMessages.push(current);
        continue;
      }
      changed = true;
      nextMessages.push({
        id: current.id,
        speaker: current.speaker,
        text: current.text,
        kind: current.kind,
        imagePath: current.imagePath,
        collapsible: collapsible,
        taskProgress: current.taskProgress,
        expanded: collapsible ? current.expanded : false,
        revision: current.revision + 1
      });
    }
    if (changed) {
      this.messages = nextMessages;
    }
  }

  private toggleBubbleExpansion(id: number): void {
    const index = this.messages.findIndex((bubble: ChatBubble): boolean => bubble.id === id);
    if (index < 0 || !this.messages[index].collapsible) {
      return;
    }
    const current = this.messages[index];
    const updated: ChatBubble = {
      id: current.id,
      speaker: current.speaker,
      text: current.text,
      kind: current.kind,
      imagePath: current.imagePath,
      collapsible: current.collapsible,
      taskProgress: current.taskProgress,
      expanded: !current.expanded,
      revision: current.revision + 1
    };
    const nextMessages = [...this.messages];
    nextMessages[index] = updated;
    this.messages = nextMessages;
  }
}
