import { describe, expect, it } from 'vitest'
import {
  CATEGORY_DEFS,
  STATUS_DEFS,
  SOURCE_DEFS,
  categoryName,
  categorySensitivity,
  statusName,
  sensitivityName,
  sourceName,
  formatTime,
} from '../composables/useCatalog'

describe('useCatalog · 分类字典', () => {
  it('共 11 类且采用现行中文口径，不含历史废弃名', () => {
    expect(CATEGORY_DEFS).toHaveLength(11)
    const names = CATEGORY_DEFS.map((c) => c.name)
    expect(names).toContain('证件信息')
    expect(names).toContain('职业经历')
    expect(names).toContain('资质证书')
    expect(names).not.toContain('身份证明')
    expect(names).not.toContain('工作经历')
    expect(names).not.toContain('资格证书')
    expect(CATEGORY_DEFS.map((c) => c.code)).toEqual([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11])
  })

  it('categoryName / categorySensitivity 按编码取值', () => {
    expect(categoryName(2)).toBe('证件信息')
    expect(categoryName('4')).toBe('职业经历')
    expect(categoryName(5)).toBe('资质证书')
    expect(categoryName(99)).toBe('分类 99')
    expect(categorySensitivity(8)).toBe(3)
    expect(categorySensitivity('2')).toBe(2)
    expect(categorySensitivity(999)).toBe(1)
  })
})

describe('useCatalog · 状态 / 来源 / 敏感度映射', () => {
  it('字典规模与映射值正确', () => {
    expect(STATUS_DEFS).toHaveLength(4)
    expect(SOURCE_DEFS).toHaveLength(6)
    expect(statusName(0)).toBe('草稿')
    expect(statusName(2)).toBe('已归档')
    expect(statusName('3')).toBe('已删除')
    expect(statusName(99)).toBe('—')
    expect(sourceName(1)).toBe('CSV 导入')
    expect(sourceName(5)).toBe('导出包回导')
    expect(sourceName(99)).toBe('手动')
    expect(sensitivityName(1)).toBe('普通')
    expect(sensitivityName(2)).toBe('敏感')
    expect(sensitivityName(3)).toBe('高敏')
    expect(sensitivityName(9)).toBe('高敏')
    expect(sensitivityName(0)).toBe('普通')
  })
})

describe('useCatalog · 时间格式化', () => {
  it('空值给破折号，正常值格式化为 YYYY-MM-DD HH:mm', () => {
    expect(formatTime(0)).toBe('—')
    expect(formatTime(undefined)).toBe('—')
    expect(formatTime(null)).toBe('—')
    // 用本地时间构造，避免时区差异导致断言不稳定
    const ms = new Date(2024, 0, 2, 3, 4).getTime()
    expect(formatTime(ms)).toBe('2024-01-02 03:04')
    expect(formatTime(String(ms))).toBe('2024-01-02 03:04')
  })
})
