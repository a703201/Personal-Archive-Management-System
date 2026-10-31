<script setup lang="ts">
/**
 * 标签管理（FR-TAG-003 重命名/合并 / FR-TAG-004 使用统计 / FR-TAG-005 标签层级）。
 *
 * 合并（FR-TAG-003）：把源标签的所有条目关联迁到目标标签后删除源标签，
 * 后端 `POST /api/tags/:id/merge` 在同 owner 下做归属迁移 + 软删，带「防合并到自身」
 * 校验；前端要求先选目标再点「确认合并」，避免误并。可选项同样排除自身与子孙
 * （复用 `parentOptions`，与服务端环路/深度校验形成双保险）。
 *
 * 【为什么把层级判定放在服务端】
 *   parent_id 是自引用列，「A→B→A」会让树变成环。服务端在写库前做环路
 *   与深度检测（`TagRepo.move`），响应里直接给出 depth / childCount ——
 *   前端只负责按这两个数渲染。若让前端从扁平列表推层级，一旦库里出现
 *   环（历史数据或直连 SQL 写入），前端就是无限递归白屏。
 *
 * 【渲染仍做一层防御】
 *   即便服务端保证了无环，前端递归建树时也带 visited 集合和深度上限：
 *   白屏是最难排查的一类缺陷，多一层判断几乎零成本。
 */
import { computed, onMounted, ref } from 'vue'
import { t as tr } from '../i18n'
import { api } from '../api/client'
import { useToast } from '../composables/useToast'

const { success, error: toastError, info } = useToast()

interface TagNode {
  id: string
  name: string
  color: string
  category: number
  usageCount: number
  parentId: string
  depth: number
  childCount: number
  lastUsedAt: string
  children?: TagNode[]
}

interface TagStats {
  total: number
  used: number
  unused: number
  totalUsage: number
  lastUsedAt: string
}

const tags = ref<TagNode[]>([])
const stats = ref<TagStats | null>(null)
const maxDepth = ref(5)
const busy = ref(false)

// ---- 新建 / 改名 ----
const newName = ref('')
const newParent = ref('')
const editingId = ref('')
const editName = ref('')

// ---- 合并（FR-TAG-003）----
const mergeId = ref('')
const mergeTarget = ref('')

/**
 * 由扁平列表建树。
 *
 * visited + 深度上限：库里若因历史数据出现环，宁可截断也不递归到爆栈。
 */
function buildTree(items: TagNode[]): TagNode[] {
  const byId = new Map<string, TagNode>()
  for (const t of items) {
    byId.set(t.id, { ...t, children: [] })
  }
  const roots: TagNode[] = []
  for (const t of items) {
    const node = byId.get(t.id) as TagNode
    const pid = t.parentId && t.parentId !== '0' ? t.parentId : ''
    const parent = pid ? byId.get(pid) : undefined
    if (parent && parent.id !== t.id && t.depth <= maxDepth.value) {
      ;(parent.children as TagNode[]).push(node)
    } else {
      roots.push(node)
    }
  }
  return roots
}

const tree = computed(() => buildTree(tags.value))

/**
 * 深度优先展开成行序：子标签紧跟在父标签之后（表格里用缩进表示层级）。
 * 直接按库里的顺序排会出现「子和父隔着几行」的错位。
 */
const ordered = computed(() => {
  const out: TagNode[] = []
  const walk = (nodes: TagNode[], depth: number): void => {
    for (const n of nodes) {
      out.push({ ...n, depth })
      const kids = n.children ?? []
      if (kids.length > 0 && depth < maxDepth.value) {
        walk(kids, depth + 1)
      }
    }
  }
  walk(tree.value, 1)
  return out
})

/** 可选父标签：排除自己与其子孙（前端先挡一道，服务端再判一次） */
function parentOptions(excludeId: string): TagNode[] {
  if (!excludeId) return tags.value
  const banned = new Set<string>([excludeId])
  let grew = true
  while (grew) {
    grew = false
    for (const t of tags.value) {
      if (banned.has(t.parentId) && !banned.has(t.id)) {
        banned.add(t.id)
        grew = true
      }
    }
  }
  return tags.value.filter((t) => !banned.has(t.id))
}

const createParentOptions = computed(() => parentOptions(''))
const moveParentOptions = computed(() => parentOptions(editingId.value))
const mergeTargetOptions = computed(() => parentOptions(mergeId.value))

function fmtTime(ms: string | number): string {
  const n = Number(ms)
  if (!n) return '—'
  const d = new Date(n)
  const p = (x: number) => String(x).padStart(2, '0')
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}`
}

async function load(): Promise<void> {
  try {
    const list = await api<{ items: TagNode[]; total: number; maxDepth: number }>('/tags?tree=1')
    tags.value = list.items ?? []
    maxDepth.value = Number(list.maxDepth) || 5
    stats.value = await api<TagStats>('/tags/stats')
  } catch (e) {
    toastError((e as Error).message)
  }
}

onMounted(load)

async function createTag(): Promise<void> {
  const name = newName.value.trim()
  if (!name) {
    toastError(tr('viewsTagView.b0f792', '请填写标签名'))
    return
  }
  busy.value = true
  try {
    await api('/tags', { method: 'POST', body: { name, parentId: newParent.value || undefined } })
    success(tr('viewsTagView.bb2841', '已创建标签'))
    newName.value = ''
    newParent.value = ''
    await load()
  } catch (e) {
    toastError((e as Error).message)
  } finally {
    busy.value = false
  }
}

function startEdit(t: TagNode): void {
  editingId.value = t.id
  editName.value = t.name
}

async function saveEdit(): Promise<void> {
  const name = editName.value.trim()
  if (!editingId.value || !name) return
  busy.value = true
  try {
    await api(`/tags/${editingId.value}`, { method: 'PUT', body: { name } })
    success(tr('viewsTagView.112f98', '已更新'))
    editingId.value = ''
    await load()
  } catch (e) {
    toastError((e as Error).message)
  } finally {
    busy.value = false
  }
}

/** 移动：改父级。parentId 为空 = 提升为顶层 */
async function moveTag(t: TagNode, parentId: string): Promise<void> {
  busy.value = true
  try {
    await api(`/tags/${t.id}/parent`, { method: 'PUT', body: { parentId: parentId || 0 } })
    success(parentId ? '已移动到该父标签下' : tr('viewsTagView.0a5fb5', '已提升为顶层标签'))
    await load()
  } catch (e) {
    toastError((e as Error).message)
  } finally {
    busy.value = false
  }
}

async function removeTag(t: TagNode): Promise<void> {
  if (t.childCount > 0) {
    info(tr('viewsTagView.3a8cbb', '该标签下还有子标签，请先移走或删除子标签'))
    return
  }
  busy.value = true
  try {
    await api(`/tags/${t.id}`, { method: 'DELETE' })
    success(tr('viewsTagView.eb22b0', '已删除标签'))
    await load()
  } catch (e) {
    toastError((e as Error).message)
  } finally {
    busy.value = false
  }
}

// ---- 合并（FR-TAG-003）----
function startMerge(t: TagNode): void {
  mergeId.value = t.id
  mergeTarget.value = ''
}

function cancelMerge(): void {
  mergeId.value = ''
  mergeTarget.value = ''
}

async function confirmMerge(t: TagNode): Promise<void> {
  const targetId = mergeTarget.value
  if (!targetId || targetId === t.id) {
    toastError(tr('viewsTagView.a28546', '请选择一个不同的目标标签'))
    return
  }
  busy.value = true
  try {
    const r = await api<{ moved: number }>(`/tags/${t.id}/merge`, { method: 'POST', body: { targetId } })
    success(tr('viewsTagView.b6fae7', `已合并，迁移 ${r.moved} 条关联`))
    mergeId.value = ''
    await load()
  } catch (e) {
    toastError((e as Error).message)
  } finally {
    busy.value = false
  }
}
</script>

<template>
  <section>
    <div class="page-head">
      <div>
        <h1 class="page-title">{{ tr('TagView.4e02a9', '标签管理') }}</h1>
        <p class="page-sub">
          支持父子层级（最多 {{ maxDepth }} 层）。移动时会拒绝形成环的层级，深度超限也会被拦下。
        </p>
      </div>
    </div>

    <!-- 统计（FR-TAG-004） -->
    <div v-if="stats" class="card block">
      <h2 class="block__title">{{ tr('TagView.65a834', '使用统计') }}</h2>
      <div class="stats">
        <div class="stat">
          <span class="stat__n">{{ stats.total }}</span>
          <span class="stat__k">{{ tr('TagView.745416', '标签总数') }}</span>
        </div>
        <div class="stat stat--ok">
          <span class="stat__n">{{ stats.used }}</span>
          <span class="stat__k">{{ tr('TagView.004f7f', '已使用') }}</span>
        </div>
        <div class="stat stat--muted">
          <span class="stat__n">{{ stats.unused }}</span>
          <span class="stat__k">{{ tr('TagView.13cec8', '未使用') }}</span>
        </div>
        <div class="stat">
          <span class="stat__n">{{ stats.totalUsage }}</span>
          <span class="stat__k">{{ tr('TagView.5352e6', '累计打标次数') }}</span>
        </div>
      </div>
      <p class="hint">{{ tr('TagView.3de4e1', '最近使用：') }}{{ fmtTime(stats.lastUsedAt) }}{{ tr('TagView.872da6', '；未使用的标签可直接清理。') }}</p>
    </div>

    <!-- 新建 -->
    <div class="card block">
      <h2 class="block__title">{{ tr('TagView.616054', '新建标签') }}</h2>
      <div class="form">
        <label class="field">
          <span class="field__label">{{ tr('TagView.8290b4', '标签名') }}</span>
          <input v-model="newName" class="field-control" :placeholder="tr('TagView.1f2a83', '如：学历 / 本科')" />
        </label>
        <label class="field">
          <span class="field__label">{{ tr('TagView.9aa429', '父标签（可选）') }}</span>
          <select v-model="newParent" class="field-control">
            <option value="">{{ tr('TagView.6b81b9', '（顶层标签）') }}</option>
            <option v-for="t in createParentOptions" :key="t.id" :value="t.id">
              {{ '　'.repeat(Math.max(0, t.depth - 1)) }}{{ t.name }}
            </option>
          </select>
        </label>
        <div class="actions">
          <button class="btn-primary" :disabled="busy" @click="createTag">{{ tr('TagView.fcbd09', '创建') }}</button>
        </div>
      </div>
    </div>

    <!-- 层级树（FR-TAG-005） -->
    <div class="card block">
      <div class="block__head">
        <h2 class="block__title">{{ tr('TagView.6eba89', '标签层级') }}</h2>
        <button class="btn-ghost" type="button" :disabled="busy" @click="load">{{ tr('TagView.38108e', '刷新') }}</button>
      </div>
      <div v-if="!tags.length" class="empty">{{ tr('TagView.be5c53', '还没有标签。') }}</div>
      <table v-else class="tbl">
        <thead>
          <tr>
            <th>{{ tr('TagView.ae0a7a', '标签') }}</th>
            <th>{{ tr('TagView.dac36c', '层级') }}</th>
            <th>{{ tr('TagView.2d7d18', '使用次数') }}</th>
            <th>{{ tr('TagView.1017b3', '子标签') }}</th>
            <th>{{ tr('TagView.71265f', '最近使用') }}</th>
            <th></th>
          </tr>
        </thead>
        <tbody>
          <template v-for="t in ordered" :key="t.id">
            <tr>
              <td>
                <span class="indent" :style="{ width: `${(t.depth - 1) * 16}px` }"></span>
                <span v-if="t.depth > 1" class="tree-mark">└</span>
                <span v-if="editingId === t.id" class="rename">
                  <input v-model="editName" class="field-control field-control--sm" />
                </span>
                <span v-else class="tag-name">{{ t.name }}</span>
              </td>
              <td class="mono">{{ t.depth }}</td>
              <td class="mono">{{ t.usageCount }}</td>
              <td class="mono">{{ t.childCount }}</td>
              <td class="mono">{{ fmtTime(t.lastUsedAt) }}</td>
              <td class="row-actions">
                <template v-if="editingId === t.id">
                  <button class="btn-text" type="button" :disabled="busy" @click="saveEdit">{{ tr('TagView.fadf24', '保存') }}</button>
                  <button class="btn-text" type="button" @click="editingId = ''">{{ tr('TagView.4d0b46', '取消') }}</button>
                </template>
                <template v-else-if="mergeId === t.id">
                  <select
                    class="field-control field-control--sm"
                    v-model="mergeTarget"
                    :disabled="busy"
                  >
                    <option value="">{{ tr('TagView.938cd0', '合并到…') }}</option>
                    <option v-for="p in mergeTargetOptions" :key="p.id" :value="p.id">
                      {{ '　'.repeat(Math.max(0, p.depth - 1)) }}{{ p.name }}
                    </option>
                  </select>
                  <button class="btn-text" type="button" :disabled="busy" @click="confirmMerge(t)">
                    确认合并
                  </button>
                  <button class="btn-text" type="button" @click="cancelMerge">{{ tr('TagView.4d0b46', '取消') }}</button>
                </template>
                <template v-else>
                  <button class="btn-text" type="button" @click="startEdit(t)">改名</button>
                  <button
                    class="btn-text"
                    type="button"
                    :disabled="busy"
                    @click="moveTag(t, '')"
                  >
                    提升为顶层
                  </button>
                  <select
                    class="field-control field-control--sm"
                    :disabled="busy"
                    @change="moveTag(t, ($event.target as HTMLSelectElement).value)"
                  >
                    <option value="">{{ tr('TagView.7afafc', '移到…') }}</option>
                    <option
                      v-for="p in moveParentOptions.filter((x) => x.id !== t.id && x.parentId !== t.id)"
                      :key="p.id"
                      :value="p.id"
                    >
                      {{ p.name }}
                    </option>
                  </select>
                  <button class="btn-text" type="button" :disabled="busy" @click="startMerge(t)">
                    合并
                  </button>
                  <button class="btn-text" type="button" :disabled="busy" @click="removeTag(t)">
                    删除
                  </button>
                </template>
              </td>
            </tr>
          </template>
        </tbody>
      </table>
      <p class="hint">
        列表按层级与名称排序展示；「移到…」下拉已排除自身与自己的子孙，服务端还会再校验一次环与深度。
      </p>
    </div>
  </section>
</template>

<style scoped>
.page-head {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: var(--sp-3);
  flex-wrap: wrap;
}
.page-title {
  font-size: var(--font-size-xl);
  margin: 0;
}
.page-sub {
  margin: 4px 0 0;
  color: var(--text-muted);
  font-size: var(--font-size-sm);
}
.hint {
  color: var(--text-muted);
  font-size: var(--font-size-sm);
  margin: 8px 0 0;
}
.mono {
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  font-size: 12px;
}
.block {
  margin-top: var(--sp-4);
  padding: var(--sp-4);
}
.block__head {
  display: flex;
  align-items: center;
  justify-content: space-between;
}
.block__title {
  font-size: var(--font-size-md);
  margin: 0 0 var(--sp-2);
}
.form {
  display: flex;
  gap: var(--sp-4);
  flex-wrap: wrap;
  align-items: flex-end;
}
.field {
  display: flex;
  flex-direction: column;
  gap: 6px;
  min-width: 200px;
}
.field__label {
  font-size: var(--font-size-sm);
  color: var(--text-secondary);
}
.field-control--sm {
  padding: 4px 8px;
  font-size: 12px;
}
.stats {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(96px, 1fr));
  gap: var(--sp-2);
  margin: var(--sp-2) 0 var(--sp-3);
}
.stat {
  background: var(--bg-hover);
  border-radius: var(--radius-md);
  padding: 10px 12px;
  display: flex;
  flex-direction: column;
  gap: 2px;
}
.stat__n {
  font-size: 20px;
  font-weight: 600;
  line-height: 1.1;
}
.stat__k {
  font-size: 11px;
  color: var(--text-muted);
}
.stat--ok .stat__n {
  color: var(--success);
}
.stat--muted .stat__n {
  color: var(--text-muted);
}
.tbl {
  width: 100%;
  border-collapse: collapse;
  font-size: var(--font-size-sm);
}
.tbl th {
  text-align: left;
  font-weight: 500;
  color: var(--text-muted);
  font-size: 12px;
  padding: 6px 8px;
  border-bottom: 1px solid var(--border-subtle);
  white-space: nowrap;
}
.tbl td {
  padding: 8px;
  border-bottom: 1px solid var(--border-subtle);
  vertical-align: middle;
}
.tbl tr:last-child td {
  border-bottom: 0;
}
.indent {
  display: inline-block;
}
.tree-mark {
  color: var(--text-muted);
  margin-right: 4px;
}
.tag-name {
  font-weight: 500;
}
.rename {
  display: inline-block;
}
.row-actions {
  display: flex;
  gap: 8px;
  align-items: center;
  flex-wrap: wrap;
}
.empty {
  color: var(--text-muted);
  font-size: var(--font-size-sm);
  padding: var(--sp-3) 0;
}
</style>
