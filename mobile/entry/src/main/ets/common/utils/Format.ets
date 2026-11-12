import { C } from '../theme/Theme';
import { t } from '../theme/I18n';

export function sensitivityLabel(level: number): string {
  if (level >= 3) {
    return t('sens.high');
  }
  if (level === 2) {
    return t('sens.mid');
  }
  return t('sens.low');
}

export function sensitivityColor(level: number): string {
  if (level >= 3) {
    return C.danger;
  }
  if (level === 2) {
    return C.warn;
  }
  return C.success;
}

/**
 * 条目状态 —— 以 docs/06 §arc_items 为准：0 草稿 / 1 正常 / 2 已归档 / 3 已删除。
 * 旧版误写成「0 有效 / 1 临期 / 2 已过期 / 3 草稿」，与后端完全不符，已订正。
 */
export function statusLabel(status: number): string {
  const key: string = 'status.' + status.toString();
  const v: string = t(key);
  return v === key ? t('common.other') : v;
}

export function statusColor(status: number): string {
  switch (status) {
    case 0:
      return C.ink3;
    case 1:
      return C.success;
    case 2:
      return C.accent;
    case 3:
      return C.danger;
    default:
      return C.ink2;
  }
}

/** 状态流转的目标值与按钮文案（草稿→正常→已归档，已归档可撤回正常）。 */
export function nextStatus(status: number): number {
  if (status === 0) {
    return 1;
  }
  if (status === 1) {
    return 2;
  }
  return 1;
}

export function nextStatusLabel(status: number): string {
  if (status === 0) {
    return t('next.publish');
  }
  if (status === 1) {
    return t('next.archive');
  }
  return t('next.revert');
}

export function formatDate(ms?: number): string {
  if (ms === undefined || ms === 0) {
    return '—';
  }
  const d = new Date(ms);
  const y = d.getFullYear();
  const m = (d.getMonth() + 1).toString().padStart(2, '0');
  const day = d.getDate().toString().padStart(2, '0');
  return `${y}-${m}-${day}`;
}

export function formatDateTime(ms?: number): string {
  if (ms === undefined || ms === 0) {
    return '—';
  }
  const d = new Date(ms);
  const hh = d.getHours().toString().padStart(2, '0');
  const mm = d.getMinutes().toString().padStart(2, '0');
  return formatDate(ms) + ' ' + hh + ':' + mm;
}
