/**
 * 离线缓存指纹工具（纯 ArkTS）
 * ------------------------------------------------------------------
 * 对输入字符串生成稳定的 8 位十六进制指纹，用作离线缓存键。
 * 采用 FNV-1a 32 位哈希；算法与原先 Cangjie 双栈方案中的实现逐位一致，
 * 因此历史缓存键保持不变。纯 ArkTS 实现，无需任何原生/Cangjie 依赖。
 */

export class Fingerprint {
  /** 对输入字符串生成稳定的 8 位十六进制指纹（FNV-1a 32）。 */
  static fingerprint(input: string): string {
    let h: number = 2166136261;
    for (let i = 0; i < input.length; i++) {
      h = Math.imul(h ^ input.charCodeAt(i), 16777619);
    }
    const n: number = h >>> 0;
    let hex: string = n.toString(16);
    while (hex.length < 8) {
      hex = '0' + hex;
    }
    return hex;
  }
}
