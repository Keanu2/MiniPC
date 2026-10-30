/**
 * 路由算法注册表与工厂（对齐 Switchyard build_algorithm 的 match arms /
 * model-router registry::create_algorithm）。名字即配置：routeMode 字段、
 * 设置面板下拉、持久化 JSON 共用同一值域（knownRouterNames）。
 *
 * 当前只有 least_load（能力门槛 → 最小负载 → 档位决胜）；对比测试用的
 * 新算法按"一算法一文件"接入。未知名字构造期归一 least_load（持久化
 * 脏值不崩 app；写错名字的 fail-fast 由测试承担）。
 *
 * 加一个算法 = 加一个实现 RouteAlgorithm 的文件 + 这里两个 set 语句
 * （FACTORIES 与 LABELS）。
 */
import { RouteAlgorithm } from './RouterTypes';
import { LeastLoadRouter } from './LeastLoadRouter';

/** 设置面板下拉的一个选项。 */
export class RouterChoice {
  name: string = '';
  label: string = '';
}

const FACTORIES: Map<string, () => RouteAlgorithm> = new Map();
FACTORIES.set('least_load', (): RouteAlgorithm => new LeastLoadRouter());

const LABELS: Map<string, string> = new Map();
LABELS.set('least_load', '最小负载（空闲优先，档位决胜）');

/** routeMode 值域 = 面板选项 = 持久化合法值。 */
export function knownRouterNames(): string[] {
  return ['least_load'];
}

/** 按名字构造算法实例；未知名字回落 least_load。 */
export function createRouter(name: string): RouteAlgorithm {
  const factory = FACTORIES.get(name);
  return factory !== undefined ? factory() : new LeastLoadRouter();
}

/** 面板/日志用的中文标签；未注册的名字原样返回。 */
export function routerLabel(name: string): string {
  const label = LABELS.get(name);
  return label !== undefined ? label : name;
}

/** 设置面板的全部选项（顺序即 knownRouterNames 的顺序）。 */
export function routerChoices(): RouterChoice[] {
  const choices: RouterChoice[] = [];
  for (const name of knownRouterNames()) {
    const choice = new RouterChoice();
    choice.name = name;
    choice.label = routerLabel(name);
    choices.push(choice);
  }
  return choices;
}
