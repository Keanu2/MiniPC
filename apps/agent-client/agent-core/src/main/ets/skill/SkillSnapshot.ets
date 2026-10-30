import { common } from '@kit.AbilityKit';
import { AgentSkill } from './AgentSkill';
import { buildSkillCatalog } from './SkillCatalog';
import { loadSkillsFromContext } from './SkillLoader';

export class SkillSnapshot {
  readonly eligible: AgentSkill[];
  readonly catalogText: string;

  constructor(eligible: AgentSkill[], catalogText: string) {
    this.eligible = eligible;
    this.catalogText = catalogText;
  }

  findByName(name: string): AgentSkill | null {
    const trimmed = name.trim();
    for (const skill of this.eligible) {
      if (skill.name === trimmed) {
        return skill;
      }
    }
    return null;
  }

  /** Select one bundled benchmark Skill when its natural-language trigger is unambiguous. */
  findByNaturalLanguageTask(task: string): AgentSkill | null {
    const normalized = task.trim().toLowerCase();
    if (normalized.length === 0) {
      return null;
    }
    let best: AgentSkill | null = null;
    let bestScore = 0;
    let tied = false;
    for (const skill of this.eligible) {
      let score = normalized.includes(skill.name.toLowerCase()) ? 100 : 0;
      if (score > bestScore) {
        best = skill;
        bestScore = score;
        tied = false;
      } else if (score > 0 && score === bestScore) {
        tied = true;
      }
    }
    return bestScore > 0 && !tied ? best : null;
  }

  isEmpty(): boolean {
    return this.eligible.length === 0;
  }
}

export async function createSkillSnapshot(context: common.UIAbilityContext): Promise<SkillSnapshot> {
  const skills = await loadSkillsFromContext(context);
  return new SkillSnapshot(skills, buildSkillCatalog(skills));
}

export function buildSkillsSection(snapshot: SkillSnapshot | null): string {
  if (snapshot === null || snapshot.isEmpty()) {
    return '';
  }

  let section = '## Skills\n';
  section += 'Choose at most one matching skill. If the user names a listed skill, your first tool call MUST be read[exact_skill_name]. ';
  section += 'Otherwise, when exactly one description matches, first call read[skill_name]. Follow the loaded instructions after its Observation. ';
  section += 'If none matches, use another tool or Final. Do not bypass a matching skill by calling its downstream tool first.\n';
  section += 'Never read or invoke skill_creator unless the user explicitly asks to create or update a Skill. ';
  section += 'When the user explicitly asks to create or update a Skill, first read skill_creator, then follow it.\n';
  section += snapshot.catalogText;
  return section;
}

export function buildLoopSystemPrompt(snapshot: SkillSnapshot | null): string {
  let content = 'You are Loop, a concise ReAct agent on HarmonyOS.';
  content += buildReActFormatRules();

  const skillsSection = buildSkillsSection(snapshot);
  if (skillsSection.length > 0) {
    content += '\n\n';
    content += skillsSection;
  }

  return content;
}

export function buildReActFormatRules(): string {
  return ' Reply directly with either Final Answer (in Chinese): answer, or Execution: serial or parallel followed by Action: line(s). Never output Thought, reasoning, or analysis.\n'
    + '- Single tool: Execution: serial then Action: tool_name[input]\n'
    + '- Parallel tools: Execution: parallel then multiple independent Action: lines\n'
    + '- Ordered tools with known inputs: Execution: serial then multiple Action: lines\n'
    + '- Output-dependent tools: call one tool, wait for Observation, then call the next\n'
    + 'Do not use markdown bold, bullets, or code blocks on Action/Final lines. '
    + 'Use only listed tools.';
}
