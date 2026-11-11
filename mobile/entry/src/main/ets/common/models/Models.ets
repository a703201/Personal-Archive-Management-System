export interface Subject {
  id: string;
  name: string;
  alias?: string;
  relation?: number;
  summary?: string;
  version?: number;
  itemCount?: number;
}

export interface ArchiveItem {
  id: string;
  subjectId: string;
  category: number;
  title: string;
  status: number;
  sensitivity: number;
  issuer?: string;
  remark?: string;
  version: number;
  source?: number;
  createdAt?: number;
  updatedAt?: number;
  shared?: boolean;
  issuedDate?: string;
  expiresAt?: string;
}

export interface CategoryRef {
  code: number;
  name: string;
}

/** 条目编辑页参数：mode = 'create' | 'edit'。 */
export interface EditParam {
  mode: string;
  category: number;
  subjectId: string;
  item?: ArchiveItem;
}

// 与后端 useCatalog / 前端 useCatalog.ts 保持一致的口径（docs/06 §12.3）
export const CATEGORIES: CategoryRef[] = [
  { code: 1, name: '个人基本信息' },
  { code: 2, name: '证件信息' },
  { code: 3, name: '教育经历' },
  { code: 4, name: '职业经历' },
  { code: 5, name: '资质证书' },
  { code: 6, name: '联系方式' },
  { code: 7, name: '家庭关系' },
  { code: 8, name: '健康信息' },
  { code: 9, name: '资产信息' },
  { code: 10, name: '影像附件' },
  { code: 11, name: '自定义分类' }
];

export function categoryName(code: number): string {
  for (let i = 0; i < CATEGORIES.length; i++) {
    if (CATEGORIES[i].code === code) {
      return CATEGORIES[i].name;
    }
  }
  return '其他';
}
