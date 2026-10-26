// 补字候选中的否定字一律拒绝：把"可以"补成"不可以"这类语义反转比保留乱码更糟。
const NEGATIVE_PREFIXES: string[] = ['不', '没', '无', '非', '未', '别', '勿', '莫', '反', '难'];
/**
 * 模型输出的出口清理。GEWU 引擎会在内部把跨块的多字节字符替换成 U+FFFD
 * （真机实测：答案首个汉字被替换成 1-3 个 U+FFFD，原始字节在引擎侧已丢失，
 * 无法真正还原；QoS Gewu API 无输出模式可调）。
 * 1) 先按源文本启发式修复 repairUtf8FromSource——只补回有把握的字符
 *    （多字锚点，或答案后文与提示词双证据一致的单字锚，且不在否定黑名单）；
 * 2) 修不回来的残留 U+FFFD 直接剔除——显示层宁可缺一个字，也不出乱码，
 *    更不出错字。
 * 幂等：对干净文本是恒等变换，多层调用安全。
 */
export function sanitizeModelOutput(output: string, source: string): string {
  const repaired = repairUtf8FromSource(output, source);
  if (repaired.indexOf('\uFFFD') < 0) return repaired;
  return repaired.replace(/\uFFFD/g, '');
}

export function repairUtf8FromSource(output: string, source: string): string {
  if (output.indexOf('\uFFFD') < 0 || source.length === 0) {
    return output;
  }
  const chars = Array.from(output);
  const result: string[] = [];
  let index = 0;
  while (index < chars.length) {
    if (chars[index] !== '\uFFFD') {
      result.push(chars[index]);
      index += 1;
      continue;
    }
    let end = index;
    while (end < chars.length && chars[end] === '\uFFFD') {
      end += 1;
    }
    const run = end - index;
    const following = chars.slice(end, Math.min(chars.length, end + 24));
    let replacement = '';
    if (run >= 1 && run <= 6) {
      for (let length = following.length; length >= 2; length--) {
        const anchor = following.slice(0, length).join('');
        const previous = sharedPrevious(source, anchor);
        if (previous.length > 0) {
          replacement = previous;
          break;
        }
      }
      // GEWU 的 flush 边界常切在 ASCII 标记后的首个中文字上（如 "Final: □□□圳去日本"
      // 丢"深"），答案措辞改写后整段锚点不在提示词里。单字补回必须双重一致：答案后文
      // 与提示词各自独立给出同一个前字（答案重现"深圳"、问题里也有"深圳"→补"深"）。
      // 只有一方一致时保留乱码——补错字比留乱码更糟。
      if (replacement.length === 0 && run <= 3 && following.length > 0 && following[0].charCodeAt(0) > 127) {
        const single = following[0];
        const fromAnswer = sharedPrevious(chars.slice(end + 1).join(''), single);
        const fromPrompt = sharedPrevious(source, single);
        if (fromAnswer.length > 0 && fromAnswer === fromPrompt && NEGATIVE_PREFIXES.indexOf(fromAnswer) < 0) {
          replacement = fromAnswer;
        }
      }
    }
    if (replacement.length > 0) {
      result.push(replacement);
    } else {
      for (let cursor = index; cursor < end; cursor++) {
        result.push(chars[cursor]);
      }
    }
    index = end;
  }
  return result.join('');
}

function sharedPrevious(source: string, anchor: string): string {
  let agreed = '';
  let from = 0;
  let hits = 0;
  while (from < source.length) {
    const at = source.indexOf(anchor, from);
    if (at < 0) {
      break;
    }
    hits += 1;
    if (at <= 0) {
      return '';
    }
    const previous = codePointBefore(source, at);
    if (previous.length === 0 || previous === '\uFFFD' || previous.charCodeAt(0) <= 127) {
      return '';
    }
    if (agreed.length === 0) {
      agreed = previous;
    } else if (agreed !== previous) {
      return '';
    }
    from = at + anchor.length;
  }
  return hits > 0 ? agreed : '';
}

function codePointBefore(text: string, index: number): string {
  const head = Array.from(text.substring(0, index));
  if (head.length === 0) {
    return '';
  }
  return head[head.length - 1];
}
