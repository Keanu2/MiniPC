import { schemaProperties } from '../ToolContract';
import { ContractRequirement, ValueSchema } from '../ToolContract';
export interface DomainScope {
    entity: string;
    date: string;
    timeWindow: string;
    trainType?: string;
}
export function scopeOf(entry: ContractRequirement): DomainScope { return entry.scope as DomainScope; }
export function clauses(task: string): string[] { return task.split(/[，,。；;！？!?\n]|并且|以及|还有|另外|同时|然后|顺便|接着|还要/); }
export function cleanRequest(text: string): string { return text.trim().replace(/^(?:请|帮我|帮忙|请问|告诉我|根据|按照|依据|基于|参考|结合|查询一下|查询|查一下|查下|查|看看|看一下)+/, '').trim(); }
export function cleanEntity(text: string): string { return cleanRequest(text.replace(/[？?！!。，,；;]+$/g, '').trim()).replace(/的$/, '').trim(); }
export function dates(text: string): string[] { return text.match(/\d{4}-\d{2}-\d{2}|大后天|后天|明天|今天/g) ?? []; }
export function normalizeDate(text: string, anchorTime: number): string {
    const offset = ['今天', '明天', '后天', '大后天'].indexOf(text);
    if (offset < 0) {
        return text;
    }
    const value = new Date(anchorTime);
    value.setHours(12, 0, 0, 0);
    value.setDate(value.getDate() + offset);
    return value.getFullYear().toString().padStart(4, '0') + '-' + (value.getMonth() + 1).toString().padStart(2, '0') + '-' + value.getDate().toString().padStart(2, '0');
}
export function requirement(tool: string, entity: string, date: string, anchorTime: number, kind: string, task: string, timeWindow: string = ''): ContractRequirement {
    return { tool: tool, label: [entity, date, timeWindow, kind].filter((text: string): boolean => text.length > 0).join(' '),
        scope: { entity: entity, date: date, timeWindow: timeWindow } as DomainScope, anchorTime: anchorTime,
        position: Math.max(entity.length ? task.indexOf(entity) : task.indexOf(tool), date.length ? task.indexOf(date) : 0, 0), status: 'pending', output: '' };
}
export function queryInput(input: string): Record<string, Object> {
    try {
        return JSON.parse(input) as Record<string, Object>;
    }
    catch (_error) {
        return {};
    }
}
export function queryOf(input: string): string {
    const values = queryInput(input);
    return typeof values.query === 'string' ? values.query as string : typeof values.prompt === 'string' ? values.prompt as string : '';
}
export function querySchema(): ValueSchema {
    return { type: 'object', properties: schemaProperties(["query", "prompt", "context"], [{ type: 'string', minLength: 1 } as ValueSchema, { type: 'string', minLength: 1 } as ValueSchema, { type: 'string' } as ValueSchema]) as Record<string, ValueSchema>,
        anyOf: [{ type: 'object', required: ['query'] } as ValueSchema, { type: 'object', required: ['prompt'] } as ValueSchema] } as ValueSchema;
}
export function sections(answer: string): string[] { return answer.split(/[\n。；;]/).filter((text: string): boolean => text.trim().length > 0); }
export function scopedSections(entry: ContractRequirement, answer: string, marker?: RegExp, route: boolean = false): string[] {
    const scope = scopeOf(entry);
    // In a numbered/heading section the entity may be in the heading and its
    // date/facts on following lines. Keep that section together; never borrow
    // facts from the next numbered section.
    const structured = /(?:^|\n)\s*(?:\d+[.)、]\s|#{1,3}\s)/.test(answer);
    const parts = structured ? answer.split(/\n(?=\s*(?:\d+[.)、]\s|#{1,3}\s))/).map((part: string): string => part.replace(/\n/g, ' ')) : sections(answer);
    return parts.filter((section: string): boolean => {
        if (route) {
            const ends = scope.entity.split('到');
            if (section.indexOf(ends[0]) < 0 || section.indexOf(ends[1]) <= section.indexOf(ends[0])) {
                return false;
            }
        }
        else if (scope.entity.length > 0 && section.indexOf(scope.entity) < 0 && section.indexOf(scope.entity.replace(/市$/, '')) < 0) {
            return false;
        }
        if (scope.date.length > 0 && section.indexOf(scope.date) < 0 && section.indexOf(normalizeDate(scope.date, entry.anchorTime)) < 0) {
            return false;
        }
        return marker === undefined || marker.test(section);
    });
}
export function terminalIssues(entry: ContractRequirement, selected: string[]): string[] {
    if (selected.length === 0) {
        return [entry.label];
    }
    return entry.status !== 'success' && !/失败|无法|未获得|未查到|未找到|没有|不可用|不支持|未完成/.test(selected.join('\n')) ? [entry.label] : [];
}
export function metricToken(value: string): string {
    return value.replace(/\s|[:：]/g, '').replace(/℃/g, '°C').toLowerCase().replace(/-?\d+(?:\.\d+)?/g, (number: string): string => Number(number).toString());
}
