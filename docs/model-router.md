
> 路由问题：给定请求与模型、集群快照，从候选集合中选出一个 **(device, model) 二元组**并决定立即派发 / 入队 / 拒绝。四阶段流水线：**S1 能力过滤 → S2 多目标评分 → S3 请求下发**，外加 **反馈闭环**。



姜宁讨论中提到的几个问题
- 长程agent任务的kv cache问题，任务从端切换到云时因为没有缓存命中，实际并不能节省费用。
  - 在请求难度评分中考虑这一点，research、reasonning类任务直接上云，本地模型用于subagent任务
  - 即使中途切换到云端模型，如果本地模型工作正常（没有多次失败尝试），相比于一开始就在云测也不会增加费用（只是没有减少）
- 模型精度问题
  - 模型名中包含量化信息，qwen3-9B-FP16和Qwen3-9B-INT4是不同的模型
- 系统用户画像和用户画像
  - 系统用户画像：针对主要的任务类型设置不同策略，体现为预置权重
  - 用户画像和使用习惯：①允许用户自定义策略；②记录调用历史和路由结果，用于自动权重更新；③对不同应用进一步细化

符号表  
| 符号 | 含义 |
|---|---|
| `j` | 请求画像 |
| `d` | 设备，`m` 模型；候选 `c = (d, m)` |
| `warm_set(d)` | d 当前已加载模型集 |
| `quality_tier(m)` | 模型质量档 1–5 |
| `complexity_tier(j)` | 请求复杂度档 1–5 |
| `pressure(d)` | 0–3 压力分带 |
| `N_q(d)` | d 的队列深度（遥测） |
| `R(d)` | 路由器侧预约计数 |
| `max_parallel(d)` | d 的并发槽位数；v1 = 1 |
| `κ_pre/κ_dec(d, mc)` | 反馈闭环修正因子 |
| `SLO(j)` | 请求 SLO（TTFT 或 e2e 语义） |

## S1 能力过滤

先确定性过滤，不满足即淘汰：

| # | 过滤器 | 规则 |
|---|---|---|
| 1 | 模态匹配 | `modality(j) ∈ modality(m)` |
| 2 | 上下文窗口 | `est_prompt_tokens(j) + est_output_tokens(j) ≤ context_window(m)` |
| 3 | 内存可行性 | `memory(m) ≤ (vram_mb(d) − vram_used_mb(d)) + 可驱逐已载模型占用`（允许换出 warm 模型腾位） |
| 4 | 设备健康 | 电量、内存、温度满足阈值 |
| 5 | 隐私要求 | 是否含有隐私数据，分为二类（是否可上云）或三类（本机、本地模型、上云） |

注意过滤器的**warm/cold 区分不在此处**——未加载模型只要显存允许换出后能装下就保留为候选，但要考虑加载耗时。

## S2 · 多目标评分


$$
Score(j, d, m) = w_Q · Q̂_{norm} + w_L · L̂_{norm} + w_C · \hat{C}_{norm}
$$

三个归一化项分别对应质量、耗时和成本，通过权重控制每项对模型选择的重要程度

### 2.1 Q̂ · 质量评分

复用JiuwenRouting的模型质量预测


#### 方法1-基于MF和轻量网络预测的评分
对每个请求，输出每个模型的质量分 row(m) ∈ (0,1)，可以直接作为Q̂_norm

增加模型需要增训。优点是能够区分模型擅长的任务，这类方法普遍比难度分级更准确。

#### 方法2-难度分级评分
以X-router中将任务难度和模型能力分为5档为例，
```
Δ = quality_tier(m) − complexity_tier(j)          # ∈ [−4, +4]

Q̂_norm = 1 - Δ²/16   若 Δ < 0    （质量下降）
         1           若 Δ ≥ 0    （满足质量需求，时间和成本不在这一项体现）

```

这里每一个请求需要经过一个小型LLM判断难度；每个模型需要一个能力评分，考虑用benchmark得分来划分。缺点：请求复杂度和模型能力评分需要匹配，扩展难度较大；不同模型在不同种类的任务上各有优劣，用一个评分来衡量不够细粒度。

### 2.2 L̂ · 延迟评分

#### 方法1-粗略估计
对设备d上的模型m，将推理速度分别排序得到rank_prefill_tps(d, m)，rank_decode_tps(d, m)
```
L̂_norm = 1 - (rank_prefill_tps(d, m) + rank_decode_tps(d, m)) / 2n  
```
速度rank0--L̂_norm = 1
#### 方法2
可进一步分为两种L̂

```
L̂_TTFT = T̂_wait + T̂_load + T̂_pre + RTT    #不含decode
L̂_e2e  = L̂_TTFT + T̂_dec
```
在多项时延的误差叠加下，L̂与真实结果的偏差可能
**(a) 排队等待 `T̂_wait`** —— PAIR 的 pending 计数改造为时间量纲，并乘以 **token 级服务时间 S̄**：

```
S̄(d, m) = EWMA(该 (d, m_class) 实测 e2e 服务时间)      # 反馈闭环维护
          缺省 = 典型请求的 T̂_pre + T̂_dec（类别缺省 token 数）

ahead(j) = 队列中优先级 ≥ priority(j) 的请求数 + 运行中请求的预计剩余时间 / S̄

Q̂_wait =
    0                                    若 d 空闲且无更高优先级排队
    T_preempt ≈ 200ms                    若运行中为 P2 且 j 为 P0（抢占路径，见 S3）
    min( ahead(j), cap=3 ) × S̄           否则（cap 防止长队估计发散；更长队列实际上
                                         会触发溢出而非等待，见 2.6 预约）
```

**(b) 冷加载 `T̂_load`**：

```
T̂_load = 0                                    若 m ∈ warm_set(d)
       = 1.2 × load_time(m, d)               否则（1.2 = 换出余量系数：可能需驱逐
                                                warm 模型腾显存，其重载概率计入代价）

load_time 缺省值用参数量估算，后续表（按 model_class，NVMe 假设）：
  embed-0.5b ≈ 1s · llm-1b ≈ 2s · vlm-2b ≈ 3s · llm-7b-q4 ≈ 5s · vlm-7b ≈ 6s · llm-32b ≈ 18s
  （缺省值由反馈闭环用实测 load 时间逐设备修正）
```

**(c) prefill / decode 时间**：

```
T̂_pre = est_prompt_tokens / ( prefill_tps(d, m_class) × κ_pre(d, m_class) )
T̂_dec = est_output_tokens / ( decode_tps(d, m_class) × κ_dec(d, m_class) )
```

κ 为反馈闭环修正因子（缺省 1.0）。

**(d) 网络 `RTT̂(d)`**：router↔agent RTT 的 EWMA；缺省有线 3ms / Wi-Fi 10ms，上云100ms。

**(e) 前缀缓存修正 `Ĉ_cache`**：会话亲和——`session_id` 的最近一次请求落在同一 (d, m) 且当前 prompt 与其共享前缀、引擎支持前缀缓存：

```
Ĉ_cache = 0.6 × T̂_pre          # 保守假设命中可省 60% prefill；引擎不支持 → 0
```


### 2.3 决策输出与审计

每次 route() 返回完整决策记录：

```json
{
  "request_id": "req-01hxz...",
  "decision": "dispatch | enqueue | reject",
  "ordered_candidates": [
    { "device": "npu-box", "model": "smolvlm2:2b",
      "L_hat_ms": 1306, "L_norm": 0.65, "Q_norm": 0.0, "B_norm": 0.0, "cost": 0.325 },
    { "device": "gaming-pc", "model": "qwen2.5-vl:7b",
      "L_hat_ms": 1385, "L_norm": 0.69, "Q_norm": 0.083, "B_norm": 0.583, "cost": 0.537 }
  ],
  "chosen": 0, "downgraded_floor": null,
  "epoch": 42, "snapshot_ts": "..."
}
```

拒绝决策同样记录 `candidates_tried` 与原因——每个请求的路由决策**可审计、可回放**（快照 + 纯函数 = 确定性重放）。

## 3. 请求下发


派发时不下发单一目标，而是下发**整个有序列表**（`scored` 降序）：

```
[强制指定（若有且可用）] → [S2 评分降序] → [稳定 device_id 序兜底（冷启动/评分全 NaN 时）]
```

请求失败时，router沿列表尝试下一个候选。


## 5. 反馈闭环（待完善）

### 4.1 快速修正
把每次执行变成下一次估计的输入：

```
Agent 每次请求结束 → POST /agent/v1/events { event: "request_done",
    queue_wait_ms, cold_load_ms, prefill_ms, ttfb_ms, decode_tps, e2e_ms, status }

Router 维护 per (d, m_class) 的 EWMA 修正因子：
    κ_pre  = EWMA( 实测 prefill_tps / 预测 prefill_tps )      # T̂_pre 修正
    κ_dec  = EWMA( 实测 decode_tps  / 预测 decode_tps  )      # T̂_dec 修正
    S̄     = EWMA( 实测 e2e 服务时间 )                          # Q̂_wait 修正
    Λ̂_mes = EWMA( 实测 load 时间 )                             # 冷加载表修正
    RTT̂   = EWMA( 实测 RTT )
```

**稳定性防护**（⚠️ 风险#4：反馈环路振荡）：
1. κ 限幅 ∈ [0.5, 2.0]，**每次更新幅度 ≤ ±10%**（限速）
2. 压力分带自带滞回（02 §4.2），负载侧不会抖
3. 层次收缩（hierarchical shrinkage）：(d, m_class) 实测样本 < 5 → 向 (tier, m_class) 层收缩（02 §4.3 回退链共享）
4. 08 §4 设振荡检测指标：5 分钟窗口内路由决策翻转率，超阈值告警并自动回退 κ → 1（缺省估计）
### 4.2 慢速权重自适应