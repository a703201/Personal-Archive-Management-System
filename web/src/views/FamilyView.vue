<script setup lang="ts">
/**
 * 家庭协作（FR-ACL-010 · 方案 B：主体 + 条目两级授权）。
 *
 * 接口清单（与 packages/ams-api/src/routes/family.cj 一一对应）：
 *   GET    /family/groups                          我加入的组
 *   POST   /family/groups                          建组（family:manage）
 *   GET    /family/groups/:id                      组详情（含 canXxx 三个能力位）
 *   DELETE /family/groups/:id                      解散（family:manage）
 *   GET    /family/groups/:id/members              成员
 *   DELETE /family/groups/:id/members/:userId      移除成员（family:manage）
 *   POST   /family/groups/:id/invites              生成邀请（family:invite）
 *   GET    /family/groups/:id/invites              邀请列表（family:invite）
 *   DELETE /family/invites/:id                     撤销邀请（family:invite）
 *   POST   /family/groups/:id/grants               新增授权（family:invite）
 *   GET    /family/groups/:id/grants               授权列表（family:invite）
 *   DELETE /family/grants/:id                      撤销授权（family:invite）
 *   GET    /family/shared-items                    共享给我的条目（只读）
 *
 * 三条设计取舍：
 *   ① **能力位以后端为准**：能否邀请/授权/解散不在前端重新推导角色，
 *      直接读组详情里的 canInvite/canGrant/canDissolve。前端只是入口，
 *      后端 requireRole 才是权威 —— 两边各写一套判断必然会漂移。
 *   ② **邀请凭据只显示一次**：code 与 token 后端只存摘要，关掉面板就再也
 *      看不到（只能撤销重发）。所以创建成功后**不自动关闭**，并明确提示
 *      「离开本页后无法再次查看」。
 *   ③ **授权三级但分类是收窄**：整个主体 / 某分类 / 单条条目。分类档
 *      不是独立资源，而是「同主体内按分类收窄」（docs/15 §6 结论），
 *      所以界面上它必须选主体之后才可选。
 */
import { computed, onMounted, ref, watch } from 'vue'
import { t } from '../i18n'
import { api, ApiError } from '../api/client'
import AppSheet from '../components/AppSheet.vue'
import { CATEGORY_DEFS, categoryName, formatTime, sensitivityName, statusName } from '../composables/useCatalog'
import { useToast } from '../composables/useToast'

const { success, error: toastError } = useToast()

// ---------------------------------------------------------------
// 契约类型
// ---------------------------------------------------------------

interface Group {
  groupId: string
  name: string
  ownerId: string
  myRole: string
  memberCount: number
  createdAt: number
}

interface GroupDetail {
  groupId: string
  name: string
  ownerId: string
  myRole: string
  canInvite: boolean
  canGrant: boolean
  canDissolve: boolean
  createdAt: number
}

interface Member {
  userId: string
  nickname: string
  username: string
  role: string
  joinedAt: number
  invitedBy: string
}

interface Invite {
  inviteId: string
  targetRole: string
  maxUses: number
  usedCount: number
  failCount: number
  remainingUses: number
  revoked: boolean
  state: string
  expiresAt: number
  createdAt: number
}

interface Grant {
  grantId: string
  granteeId: string
  subjectId: string
  itemId: string
  category: number
  resourceType: string
  perms: string
  active: boolean
  expiresAt: number
  grantedAt: number
}

interface SharedItem {
  id: string
  subjectId: string
  category: number
  title: string
  status: number
  sensitivity: number
  issuer: string
  issuedDate: string
  expiresAt: string
  remark: string
  updatedAt: number
  shared: boolean
}

interface Subject {
  id: string
  name: string
  alias: string
  isPrimary: boolean
}

interface ItemBrief {
  id: string
  subjectId: string
  category: number
  title: string
  sensitivity: number
  status: number
}

interface CreatedInvite {
  inviteId: string
  code: string
  token: string
  link: string
  maxUses: number
  expiresAt: number
}

// ---------------------------------------------------------------
// 文案字典
// ---------------------------------------------------------------

const ROLE_LABEL: Record<string, string> = {
  owner: '所有者',
  manager: '管理员',
  member: '成员',
}

const INVITE_STATE_LABEL: Record<string, string> = {
  usable: '可用',
  revoked: '已撤销',
  expired: '已过期',
  exhausted: '已用尽',
  too_many_fails: '错误过多',
}

function roleLabel(code: string): string {
  return ROLE_LABEL[code] ?? '成员'
}

function inviteStateLabel(code: string): string {
  return INVITE_STATE_LABEL[code] ?? code
}

/** 授权范围的一句话描述（与后端 resourceTypeOf 的判定同序） */
function grantScopeText(g: Grant): string {
  if (g.resourceType === 'item') return `单条条目 #${g.itemId}`
  if (g.resourceType === 'category') return `分类：${categoryName(g.category)}`
  return '整个主体'
}

// ---------------------------------------------------------------
// 顶层状态
// ---------------------------------------------------------------

type Tab = 'groups' | 'shared'
const tab = ref<Tab>('groups')

const loading = ref(true)
const loadError = ref('')
const groups = ref<Group[]>([])
const perms = ref<string[]>([])

/** 建组是全局功能权限，与「我在某个组里是什么角色」无关 */
const canManage = computed(() => perms.value.includes('family:manage'))

async function load(): Promise<void> {
  loading.value = true
  loadError.value = ''
  try {
    const [me, g] = await Promise.all([
      api<{ perms: string[] }>('/me'),
      api<{ items: Group[] }>('/family/groups'),
    ])
    perms.value = me.perms ?? []
    groups.value = g.items ?? []
  } catch (e) {
    loadError.value = (e as ApiError).message || '加载失败'
  } finally {
    loading.value = false
  }
}

onMounted(() => {
  load()
  loadShared()
})

// ---------------------------------------------------------------
// 建组
// ---------------------------------------------------------------

const showCreate = ref(false)
const newName = ref('')
const creating = ref(false)
const createError = ref('')

function openCreate(): void {
  newName.value = ''
  createError.value = ''
  showCreate.value = true
}

async function submitCreate(): Promise<void> {
  const name = newName.value.trim()
  if (!name) {
    createError.value = '请填写家庭组名称'
    return
  }
  creating.value = true
  createError.value = ''
  try {
    const r = await api<{ groupId: string }>('/family/groups', {
      method: 'POST',
      body: { name },
    })
    success('家庭组已创建')
    showCreate.value = false
    await load()
    await openDetail(r.groupId)
  } catch (e) {
    createError.value = (e as ApiError).message || '创建失败'
  } finally {
    creating.value = false
  }
}

// ---------------------------------------------------------------
// 组详情（Sheet + 三个子页）
// ---------------------------------------------------------------

type DetailTab = 'members' | 'grants' | 'invites'

const showDetail = ref(false)
const detail = ref<GroupDetail | null>(null)
const detailLoading = ref(false)
const detailError = ref('')
const detailTab = ref<DetailTab>('members')

const members = ref<Member[]>([])
const grants = ref<Grant[]>([])
const invites = ref<Invite[]>([])

/** userId → 显示名，供授权列表回显被授权人 */
const memberName = computed<Record<string, string>>(() => {
  const map: Record<string, string> = {}
  for (const m of members.value) {
    map[m.userId] = m.nickname || m.username || `用户 ${m.userId}`
  }
  return map
})

const myUserId = ref('')

async function openDetail(groupId: string): Promise<void> {
  showDetail.value = true
  detailTab.value = 'members'
  detail.value = null
  detailError.value = ''
  createdInvite.value = null
  await refreshDetail(groupId)
}

async function refreshDetail(groupId?: string): Promise<void> {
  const id = groupId ?? detail.value?.groupId ?? ''
  if (!id) return
  detailLoading.value = true
  detailError.value = ''
  try {
    const [d, m] = await Promise.all([
      api<GroupDetail>(`/family/groups/${id}`),
      api<{ items: Member[] }>(`/family/groups/${id}/members`),
    ])
    detail.value = d
    members.value = m.items ?? []
    // 组内 owner 若不是自己，就是把「我自己」从被授权人候选里排掉的依据
    await Promise.all([loadGrants(id), loadInvites(id)])
  } catch (e) {
    detailError.value = (e as ApiError).message || '加载失败'
  } finally {
    detailLoading.value = false
  }
}

async function loadGrants(groupId: string): Promise<void> {
  // 成员看不到授权列表（后端 403），所以按能力位静默跳过，
  // 不能让这里抛出的错误把整个详情页打成失败态。
  if (!detail.value?.canGrant) {
    grants.value = []
    return
  }
  try {
    const r = await api<{ items: Grant[] }>(`/family/groups/${groupId}/grants`)
    grants.value = r.items ?? []
  } catch {
    grants.value = []
  }
}

async function loadInvites(groupId: string): Promise<void> {
  if (!detail.value?.canInvite) {
    invites.value = []
    return
  }
  try {
    const r = await api<{ items: Invite[] }>(`/family/groups/${groupId}/invites`)
    invites.value = r.items ?? []
  } catch {
    invites.value = []
  }
}

watch(detailTab, () => {
  const id = detail.value?.groupId
  if (!id) return
  if (detailTab.value === 'grants') loadGrants(id)
  if (detailTab.value === 'invites') loadInvites(id)
})

function closeDetail(): void {
  showDetail.value = false
  createdInvite.value = null
  load()
}

// ---- 解散 ----

async function dissolve(): Promise<void> {
  const g = detail.value
  if (!g) return
  if (!window.confirm(`解散「${g.name}」？组内成员将立即失去所有由此组授出的访问权。`)) return
  try {
    const r = await api<{ revokedGrants: number }>(`/family/groups/${g.groupId}`, {
      method: 'DELETE',
    })
    success(`已解散，撤销 ${r.revokedGrants} 条授权`)
    closeDetail()
  } catch (e) {
    toastError((e as ApiError).message || '解散失败')
  }
}

// ---- 移除成员 ----

async function removeMember(m: Member): Promise<void> {
  const g = detail.value
  if (!g) return
  const name = m.nickname || m.username || `用户 ${m.userId}`
  if (!window.confirm(`把「${name}」移出家庭组？该成员由此组获得的授权会一并撤销。`)) return
  try {
    const r = await api<{ revokedGrants: number }>(
      `/family/groups/${g.groupId}/members/${m.userId}`,
      { method: 'DELETE' },
    )
    success(`已移除，撤销 ${r.revokedGrants} 条授权`)
    await refreshDetail()
    await load()
  } catch (e) {
    toastError((e as ApiError).message || '移除失败')
  }
}

// ---------------------------------------------------------------
// 邀请
// ---------------------------------------------------------------

const showInviteForm = ref(false)
const inviteRole = ref('member')
const inviteMinutes = ref(15)
const inviteUses = ref(1)
const inviteFails = ref(5)
const creatingInvite = ref(false)
const inviteError = ref('')

/**
 * 新建邀请的明文结果。**只在本次会话内存里**：后端只落摘要，
 * 关掉这个面板就再也拿不回来（这正是设计意图）。
 */
const createdInvite = ref<CreatedInvite | null>(null)

function openInviteForm(): void {
  inviteRole.value = 'member'
  inviteMinutes.value = 15
  inviteUses.value = 1
  inviteFails.value = 5
  inviteError.value = ''
  createdInvite.value = null
  showInviteForm.value = true
}

async function submitInvite(): Promise<void> {
  const g = detail.value
  if (!g) return
  creatingInvite.value = true
  inviteError.value = ''
  try {
    const r = await api<CreatedInvite>(`/family/groups/${g.groupId}/invites`, {
      method: 'POST',
      body: {
        targetRole: inviteRole.value,
        expiresInMinutes: Number(inviteMinutes.value) || 0,
        maxUses: Number(inviteUses.value) || 0,
        maxFails: Number(inviteFails.value) || 0,
      },
    })
    createdInvite.value = r
    await loadInvites(g.groupId)
  } catch (e) {
    inviteError.value = (e as ApiError).message || '生成失败'
  } finally {
    creatingInvite.value = false
  }
}

async function revokeInvite(inv: Invite): Promise<void> {
  if (!window.confirm('撤销这条邀请？已用该邀请入组的成员不会被移除。')) return
  try {
    await api(`/family/invites/${inv.inviteId}`, { method: 'DELETE' })
    success('邀请已撤销')
    const id = detail.value?.groupId
    if (id) await loadInvites(id)
  } catch (e) {
    toastError((e as ApiError).message || '撤销失败')
  }
}

/** 邀请链接的完整地址（供二维码/复制） */
const inviteUrl = computed(() => {
  const c = createdInvite.value
  if (!c) return ''
  return `${window.location.origin}${c.link}`
})

// ---------------------------------------------------------------
// 授权
// ---------------------------------------------------------------

const showGrantForm = ref(false)
const grantGrantee = ref('')
const grantSubject = ref('')
const grantScope = ref<'subject' | 'category' | 'item'>('subject')
const grantCategory = ref(1)
const grantItem = ref('')
const grantHours = ref(0)
const creatingGrant = ref(false)
const grantError = ref('')

const subjects = ref<Subject[]>([])
const grantItems = ref<ItemBrief[]>([])
const grantItemsLoading = ref(false)

/** 可被授权的人 = 除自己以外的成员 */
const granteeOptions = computed(() =>
  members.value.filter((m) => m.userId !== myUserId.value && m.userId !== detail.value?.ownerId),
)

async function openGrantForm(): Promise<void> {
  grantGrantee.value = ''
  grantSubject.value = ''
  grantScope.value = 'subject'
  grantCategory.value = 1
  grantItem.value = ''
  grantHours.value = 0
  grantItems.value = []
  grantError.value = ''
  showGrantForm.value = true
  if (subjects.value.length === 0) {
    try {
      const r = await api<{ subjects: Subject[] }>('/subjects')
      subjects.value = r.subjects ?? []
    } catch (e) {
      grantError.value = (e as ApiError).message || '加载档案主体失败'
    }
  }
}

/** 条目级授权必须先选主体，且只列该主体下的条目 */
async function loadGrantItems(): Promise<void> {
  grantItem.value = ''
  grantItems.value = []
  if (grantScope.value !== 'item' || !grantSubject.value) return
  grantItemsLoading.value = true
  try {
    const r = await api<{ items: ItemBrief[] }>(
      `/items?subjectId=${encodeURIComponent(grantSubject.value)}&size=100`,
    )
    grantItems.value = r.items ?? []
  } catch (e) {
    grantError.value = (e as ApiError).message || '加载条目失败'
  } finally {
    grantItemsLoading.value = false
  }
}

watch([grantScope, grantSubject], () => {
  if (grantScope.value === 'item') loadGrantItems()
})

async function submitGrant(): Promise<void> {
  const g = detail.value
  if (!g) return
  if (!grantGrantee.value) {
    grantError.value = '请选择被授权人'
    return
  }
  if (!grantSubject.value) {
    grantError.value = '请选择档案主体'
    return
  }
  if (grantScope.value === 'item' && !grantItem.value) {
    grantError.value = '请选择要共享的条目'
    return
  }
  creatingGrant.value = true
  grantError.value = ''
  try {
    const r = await api<{ resourceType: string }>(`/family/groups/${g.groupId}/grants`, {
      method: 'POST',
      body: {
        granteeId: Number(grantGrantee.value),
        subjectId: Number(grantSubject.value),
        itemId: grantScope.value === 'item' ? Number(grantItem.value) : 0,
        category: grantScope.value === 'category' ? Number(grantCategory.value) : 0,
        expiresInHours: Number(grantHours.value) || 0,
      },
    })
    success(`已授权（${r.resourceType === 'item' ? '单条条目' : r.resourceType === 'category' ? '某分类' : '整个主体'}）`)
    showGrantForm.value = false
    await loadGrants(g.groupId)
  } catch (e) {
    grantError.value = (e as ApiError).message || '授权失败'
  } finally {
    creatingGrant.value = false
  }
}

async function revokeGrant(g: Grant): Promise<void> {
  const who = memberName.value[g.granteeId] ?? `用户 ${g.granteeId}`
  if (!window.confirm(`撤销「${who}」的这条授权？对方将立即无法再访问。`)) return
  try {
    await api(`/family/grants/${g.grantId}`, { method: 'DELETE' })
    success('授权已撤销')
    const id = detail.value?.groupId
    if (id) await loadGrants(id)
  } catch (e) {
    toastError((e as ApiError).message || '撤销失败')
  }
}

// ---------------------------------------------------------------
// 共享给我的（成员视角，只读）
// ---------------------------------------------------------------

const shared = ref<SharedItem[]>([])
const sharedTotal = ref(0)
const sharedLoading = ref(true)
const sharedError = ref('')

async function loadShared(): Promise<void> {
  sharedLoading.value = true
  sharedError.value = ''
  try {
    const r = await api<{ items: SharedItem[]; total: number }>('/family/shared-items?size=100')
    shared.value = r.items ?? []
    sharedTotal.value = r.total ?? 0
  } catch (e) {
    sharedError.value = (e as ApiError).message || '加载失败'
  } finally {
    sharedLoading.value = false
  }
}

const showSharedItem = ref(false)
const sharedDetail = ref<SharedItem | null>(null)
const sharedDetailError = ref('')

async function openSharedItem(it: SharedItem): Promise<void> {
  showSharedItem.value = true
  sharedDetail.value = null
  sharedDetailError.value = ''
  try {
    sharedDetail.value = await api<SharedItem>(`/family/shared-items/${it.id}`)
  } catch (e) {
    sharedDetailError.value = (e as ApiError).message || '加载失败'
  }
}

// ---------------------------------------------------------------
// 剪贴板
// ---------------------------------------------------------------

const copied = ref('')

async function copy(text: string, what: string): Promise<void> {
  try {
    await navigator.clipboard.writeText(text)
    copied.value = what
    window.setTimeout(() => {
      if (copied.value === what) copied.value = ''
    }, 1800)
  } catch {
    toastError('复制失败，请手动选中复制')
  }
}

/** 挂载时取一次自己的 userId，用于把「我」排除在候选被授权人之外 */
onMounted(async () => {
  try {
    const me = await api<{ userId: string }>('/me')
    myUserId.value = String(me.userId ?? '')
  } catch {
    /* 拿不到就不过滤，后端仍会校验 */
  }
})
</script>

<template>
  <section class="family-page">
    <header class="page-head">
      <div>
        <h1 class="page-title">{{ t('FamilyView.e686bb', '家庭协作') }}</h1>
        <p class="page-desc">
          把家人拉进家庭组，再按「整个主体 / 某分类 / 单条条目」逐级缩小范围授予只读权限。
          成员不会因此获得系统角色，也看不到任何未被授权的档案。
        </p>
      </div>
      <button v-if="canManage" class="btn-primary" type="button" @click="openCreate">
        创建家庭组
      </button>
    </header>

    <div class="seg" role="tablist">
      <button
        class="seg__btn"
        :class="{ 'seg__btn--on': tab === 'groups' }"
        type="button"
        role="tab"
        :aria-selected="tab === 'groups'"
        @click="tab = 'groups'"
      >
        我的家庭组
        <span v-if="groups.length" class="seg__count">{{ groups.length }}</span>
      </button>
      <button
        class="seg__btn"
        :class="{ 'seg__btn--on': tab === 'shared' }"
        type="button"
        role="tab"
        :aria-selected="tab === 'shared'"
        @click="tab = 'shared'"
      >
        共享给我的
        <span v-if="sharedTotal" class="seg__count">{{ sharedTotal }}</span>
      </button>
    </div>

    <!-- ---------- 我的家庭组 ---------- -->
    <template v-if="tab === 'groups'">
      <p v-if="loading" class="hint">{{ t('FamilyView.300ee3', '加载中…') }}</p>
      <p v-else-if="loadError" class="hint hint--error">{{ loadError }}</p>
      <p v-else-if="groups.length === 0" class="hint">
        你还没有加入任何家庭组。创建一个，或让组所有者把邀请码发给你。
      </p>

      <ul v-else class="grp-list">
        <li v-for="g in groups" :key="g.groupId" class="grp-item">
          <button class="grp-item__main" type="button" @click="openDetail(g.groupId)">
            <span class="grp-item__top">
              <span class="grp-item__name">{{ g.name }}</span>
              <span class="chip" :class="{ 'chip--own': g.myRole === 'owner' }">
                {{ roleLabel(g.myRole) }}
              </span>
            </span>
            <span class="grp-item__meta">
              <span>{{ g.memberCount }} 位成员</span>
              <span>{{ t('FamilyView.f3b01f', '创建于') }} {{ formatTime(g.createdAt) }}</span>
            </span>
          </button>
          <span class="grp-item__arrow" aria-hidden="true">›</span>
        </li>
      </ul>
    </template>

    <!-- ---------- 共享给我的 ---------- -->
    <template v-else>
      <p v-if="sharedLoading" class="hint">{{ t('FamilyView.300ee3', '加载中…') }}</p>
      <p v-else-if="sharedError" class="hint hint--error">{{ sharedError }}</p>
      <p v-else-if="shared.length === 0" class="hint">
        还没有人向你共享档案。当家庭成员为你授权后，这里会出现对应条目（只读）。
      </p>

      <ul v-else class="grp-list">
        <li v-for="it in shared" :key="it.id" class="grp-item">
          <button class="grp-item__main" type="button" @click="openSharedItem(it)">
            <span class="grp-item__top">
              <span class="grp-item__name">{{ it.title }}</span>
              <span class="chip">{{ categoryName(it.category) }}</span>
              <span class="chip" :class="`chip--sens${it.sensitivity}`">
                {{ sensitivityName(it.sensitivity) }}
              </span>
            </span>
            <span class="grp-item__meta">
              <span>{{ statusName(it.status) }}</span>
              <span v-if="it.issuer">{{ t('FamilyView.89de45', '签发：') }}{{ it.issuer }}</span>
              <span>{{ t('FamilyView.1e1ed7', '更新于') }} {{ formatTime(it.updatedAt) }}</span>
            </span>
          </button>
          <span class="grp-item__arrow" aria-hidden="true">›</span>
        </li>
      </ul>
      <p class="hint hint--foot">{{ t('FamilyView.e5daa2', '家庭成员视角只读：不能编辑、导出或再分享。') }}</p>
    </template>

    <!-- ---------- 组详情 ---------- -->
    <AppSheet
      v-model="showDetail"
      ::title="t('FamilyView.f95cbd', 'detail?.name ?? \'家庭组\'')"
      size="lg"
      @close="closeDetail"
    >
      <p v-if="detailLoading && !detail" class="hint">{{ t('FamilyView.300ee3', '加载中…') }}</p>
      <p v-else-if="detailError" class="hint hint--error">{{ detailError }}</p>

      <div v-else-if="detail" class="detail">
        <div class="detail__meta">
          <span class="chip" :class="{ 'chip--own': detail.myRole === 'owner' }">
            {{ roleLabel(detail.myRole) }}
          </span>
          <span>{{ t('FamilyView.f3b01f', '创建于') }} {{ formatTime(detail.createdAt) }}</span>
        </div>

        <div class="seg seg--sub" role="tablist">
          <button
            class="seg__btn"
            :class="{ 'seg__btn--on': detailTab === 'members' }"
            type="button"
            role="tab"
            @click="detailTab = 'members'"
          >
            成员 {{ members.length }}
          </button>
          <button
            v-if="detail.canGrant"
            class="seg__btn"
            :class="{ 'seg__btn--on': detailTab === 'grants' }"
            type="button"
            role="tab"
            @click="detailTab = 'grants'"
          >
            授权 {{ grants.length }}
          </button>
          <button
            v-if="detail.canInvite"
            class="seg__btn"
            :class="{ 'seg__btn--on': detailTab === 'invites' }"
            type="button"
            role="tab"
            @click="detailTab = 'invites'"
          >
            邀请 {{ invites.length }}
          </button>
        </div>

        <!-- 成员 -->
        <div v-if="detailTab === 'members'" class="pane">
          <ul class="row-list">
            <li v-for="m in members" :key="m.userId" class="row">
              <div class="row__main">
                <span class="row__title">
                  {{ m.nickname || m.username || `用户 ${m.userId}` }}
                  <span class="chip">{{ roleLabel(m.role) }}</span>
                </span>
                <span class="row__meta">
                  <span>{{ m.username }}</span>
                  <span>{{ t('FamilyView.c5d3fe', '加入于') }} {{ formatTime(m.joinedAt) }}</span>
                </span>
              </div>
              <button
                v-if="detail.canDissolve && m.role !== 'owner' && m.userId !== myUserId"
                class="btn-text danger"
                type="button"
                @click="removeMember(m)"
              >
                移出
              </button>
            </li>
          </ul>
          <p class="hint hint--foot">
            成员之间彼此可见昵称与用户名，用于核对「谁被授权了什么」。
          </p>
        </div>

        <!-- 授权 -->
        <div v-else-if="detailTab === 'grants'" class="pane">
          <button class="btn-primary pane__action" type="button" @click="openGrantForm">
            新增授权
          </button>

          <p v-if="grants.length === 0" class="hint">
            还没有授权。点「新增授权」后，对方刷新页面即可看到被共享的内容。
          </p>
          <ul v-else class="row-list">
            <li v-for="g in grants" :key="g.grantId" class="row">
              <div class="row__main">
                <span class="row__title">
                  {{ memberName[g.granteeId] ?? `用户 ${g.granteeId}` }}
                  <span class="chip">{{ grantScopeText(g) }}</span>
                  <span v-if="!g.active" class="chip chip--off">{{ t('FamilyView.a09345', '已失效') }}</span>
                </span>
                <span class="row__meta">
                  <span>{{ t('FamilyView.e88715', '主体 #') }}{{ g.subjectId }}</span>
                  <span>{{ g.expiresAt ? `到期 ${formatTime(g.expiresAt)}` : '长期有效' }}</span>
                  <span>{{ t('FamilyView.1d4d5d', '授予于') }} {{ formatTime(g.grantedAt) }}</span>
                </span>
              </div>
              <button
                v-if="g.active"
                class="btn-text danger"
                type="button"
                @click="revokeGrant(g)"
              >
                撤销
              </button>
            </li>
          </ul>
        </div>

        <!-- 邀请 -->
        <div v-else class="pane">
          <!-- 刚生成：明文只显示这一次 -->
          <div v-if="createdInvite" class="invite-new">
            <p class="invite-new__warn">
              邀请码与链接<strong>{{ t('FamilyView.3ebcff', '只显示这一次') }}</strong>，关闭后无法再次查看；如需重发请撤销后重新生成。
            </p>
            <div class="invite-new__code">{{ createdInvite.code }}</div>
            <div class="invite-new__acts">
              <button class="btn-text" type="button" @click="copy(createdInvite.code, 'code')">
                {{ copied === 'code' ? '已复制' : '复制邀请码' }}
              </button>
              <button class="btn-text" type="button" @click="copy(inviteUrl, 'link')">
                {{ copied === 'link' ? '已复制' : '复制链接' }}
              </button>
            </div>
            <p class="invite-new__link">{{ inviteUrl }}</p>
            <p class="invite-new__meta">
              有效期至 {{ formatTime(createdInvite.expiresAt) }} ·
              最多可用 {{ createdInvite.maxUses }} 次
            </p>
          </div>

          <button class="btn-primary pane__action" type="button" @click="openInviteForm">
            {{ createdInvite ? '再生成一条' : '生成邀请' }}
          </button>

          <p v-if="invites.length === 0" class="hint">
            还没有邀请记录。生成后把 8 位邀请码当面或电话告知对方。
          </p>
          <ul v-else class="row-list">
            <li v-for="inv in invites" :key="inv.inviteId" class="row">
              <div class="row__main">
                <span class="row__title">
                  <span class="chip" :class="{ 'chip--ok': inv.state === 'usable' }">
                    {{ inviteStateLabel(inv.state) }}
                  </span>
                  <span class="chip">{{ roleLabel(inv.targetRole) }}</span>
                </span>
                <span class="row__meta">
                  <span>{{ t('FamilyView.4c9426', '已用') }} {{ inv.usedCount }}{{ t('FamilyView.42099b', '/') }}{{ inv.maxUses }}</span>
                  <span>{{ t('FamilyView.3e3c80', '失败') }} {{ inv.failCount }} {{ t('FamilyView.5e5b81', '次') }}</span>
                  <span>{{ t('FamilyView.8066e0', '到期') }} {{ formatTime(inv.expiresAt) }}</span>
                </span>
              </div>
              <button
                v-if="inv.state === 'usable'"
                class="btn-text danger"
                type="button"
                @click="revokeInvite(inv)"
              >
                撤销
              </button>
            </li>
          </ul>
        </div>

        <div v-if="detail.canDissolve" class="detail__foot">
          <button class="btn-text danger" type="button" @click="dissolve">{{ t('FamilyView.75274f', '解散家庭组') }}</button>
        </div>
      </div>
    </AppSheet>

    <!-- ---------- 创建家庭组 ---------- -->
    <AppSheet v-model="showCreate" :title="t('FamilyView.ee508f', '创建家庭组')" size="sm" :dismissible="!creating">
      <div class="field">
        <label class="field__label" for="fam-name">{{ t('FamilyView.1be7ae', '名称') }} <em>*</em></label>
        <input
          id="fam-name"
          v-model="newName"
          class="field-control"
          maxlength="32"
          :placeholder="t('FamilyView.37b795', '例如：何家、我的小家庭')"
          autofocus
          @keyup.enter="submitCreate"
        />
        <p class="field__hint">{{ t('FamilyView.9269c0', '最多 32 个字符。名称仅组内成员可见。') }}</p>
      </div>
      <p v-if="createError" class="hint hint--error">{{ createError }}</p>
      <template #footer>
        <button class="btn-text" type="button" :disabled="creating" @click="showCreate = false">
          取消
        </button>
        <button class="btn-primary" type="button" :disabled="creating" @click="submitCreate">
          {{ creating ? '创建中…' : '创建' }}
        </button>
      </template>
    </AppSheet>

    <!-- ---------- 生成邀请 ---------- -->
    <AppSheet v-model="showInviteForm" :title="t('FamilyView.83dc50', '生成邀请')" :dismissible="!creatingInvite">
      <!-- 结果已出：只展示结果，不再显示表单，避免误以为还能再点一次 -->
      <div v-if="createdInvite" class="invite-new">
        <p class="invite-new__warn">
          邀请码与链接<strong>{{ t('FamilyView.3ebcff', '只显示这一次') }}</strong>，关闭后无法再次查看。
        </p>
        <div class="invite-new__code">{{ createdInvite.code }}</div>
        <div class="invite-new__acts">
          <button class="btn-text" type="button" @click="copy(createdInvite.code, 'code2')">
            {{ copied === 'code2' ? '已复制' : '复制邀请码' }}
          </button>
          <button class="btn-text" type="button" @click="copy(inviteUrl, 'link2')">
            {{ copied === 'link2' ? '已复制' : '复制链接' }}
          </button>
        </div>
        <p class="invite-new__link">{{ inviteUrl }}</p>
        <p class="invite-new__meta">
          有效期至 {{ formatTime(createdInvite.expiresAt) }} ·
          最多可用 {{ createdInvite.maxUses }} 次
        </p>
      </div>

      <div v-else class="form-grid">
        <div class="field">
          <label class="field__label" for="inv-role">{{ t('FamilyView.121b61', '加入后的角色') }}</label>
          <select id="inv-role" v-model="inviteRole" class="field-control">
            <option value="member">{{ t('FamilyView.e61e87', '成员（只看被授权内容）') }}</option>
            <option value="manager">{{ t('FamilyView.d02c90', '管理员（可邀请与授权）') }}</option>
          </select>
          <p class="field__hint">{{ t('FamilyView.728184', '不能通过邀请直接产生第二个所有者。') }}</p>
        </div>
        <div class="field">
          <label class="field__label" for="inv-min">{{ t('FamilyView.f27221', '有效分钟数') }}</label>
          <input
            id="inv-min"
            v-model.number="inviteMinutes"
            class="field-control"
            type="number"
            min="1"
            max="1440"
          />
          <p class="field__hint">{{ t('FamilyView.739ecc', '默认 15 分钟，上限 1440（1 天）。') }}</p>
        </div>
        <div class="field">
          <label class="field__label" for="inv-uses">{{ t('FamilyView.e49a4e', '可用次数') }}</label>
          <input
            id="inv-uses"
            v-model.number="inviteUses"
            class="field-control"
            type="number"
            min="1"
            max="10"
          />
          <p class="field__hint">{{ t('FamilyView.066f2c', '默认 1 次，上限 10 次。') }}</p>
        </div>
        <div class="field">
          <label class="field__label" for="inv-fails">{{ t('FamilyView.7a52f1', '错误次数上限') }}</label>
          <input
            id="inv-fails"
            v-model.number="inviteFails"
            class="field-control"
            type="number"
            min="1"
            max="20"
          />
          <p class="field__hint">{{ t('FamilyView.5e3e27', '输错达到该次数即自动作废。') }}</p>
        </div>
      </div>

      <p v-if="inviteError" class="hint hint--error">{{ inviteError }}</p>

      <template #footer>
        <button
          class="btn-text"
          type="button"
          :disabled="creatingInvite"
          @click="showInviteForm = false"
        >
          {{ createdInvite ? '完成' : '取消' }}
        </button>
        <button
          v-if="!createdInvite"
          class="btn-primary"
          type="button"
          :disabled="creatingInvite"
          @click="submitInvite"
        >
          {{ creatingInvite ? '生成中…' : '生成' }}
        </button>
      </template>
    </AppSheet>

    <!-- ---------- 新增授权 ---------- -->
    <AppSheet v-model="showGrantForm" :title="t('FamilyView.f31d07', '新增授权')" :dismissible="!creatingGrant">
      <div class="form-grid">
        <div class="field">
          <label class="field__label" for="gr-grantee">{{ t('FamilyView.810d0e', '被授权人') }} <em>*</em></label>
          <select id="gr-grantee" v-model="grantGrantee" class="field-control">
            <option value="">{{ t('FamilyView.257d2c', '请选择成员') }}</option>
            <option v-for="m in granteeOptions" :key="m.userId" :value="m.userId">
              {{ m.nickname || m.username }}（{{ roleLabel(m.role) }}）
            </option>
          </select>
          <p v-if="granteeOptions.length === 0" class="field__hint">
            组内还没有其他成员，先邀请再授权。
          </p>
        </div>
        <div class="field">
          <label class="field__label" for="gr-subject">{{ t('FamilyView.74bc27', '档案主体') }} <em>*</em></label>
          <select id="gr-subject" v-model="grantSubject" class="field-control">
            <option value="">{{ t('FamilyView.518358', '请选择主体') }}</option>
            <option v-for="s in subjects" :key="s.id" :value="s.id">
              {{ s.name }}{{ s.isPrimary ? '（本人）' : '' }}
            </option>
          </select>
          <p class="field__hint">{{ t('FamilyView.4b82ee', '只能授权自己名下的主体。') }}</p>
        </div>

        <div class="field field--full">
          <span class="field__label">{{ t('FamilyView.6483bf', '授权粒度') }}</span>
          <div class="radios">
            <label class="radio">
              <input v-model="grantScope" type="radio" value="subject" />
              <span>{{ t('FamilyView.2a9637', '整个主体（该主体下全部条目）') }}</span>
            </label>
            <label class="radio">
              <input v-model="grantScope" type="radio" value="category" />
              <span>{{ t('FamilyView.996773', '某个分类（同主体内按分类收窄）') }}</span>
            </label>
            <label class="radio">
              <input v-model="grantScope" type="radio" value="item" />
              <span>{{ t('FamilyView.2204ad', '单条条目（最小范围）') }}</span>
            </label>
          </div>
        </div>

        <div v-if="grantScope === 'category'" class="field field--full">
          <label class="field__label" for="gr-cat">{{ t('FamilyView.435c52', '分类') }}</label>
          <select id="gr-cat" v-model.number="grantCategory" class="field-control">
            <option v-for="c in CATEGORY_DEFS" :key="c.code" :value="c.code">
              {{ c.name }}
            </option>
          </select>
        </div>

        <div v-if="grantScope === 'item'" class="field field--full">
          <label class="field__label" for="gr-item">{{ t('FamilyView.4e5f90', '条目') }} <em>*</em></label>
          <select id="gr-item" v-model="grantItem" class="field-control" :disabled="grantItemsLoading">
            <option value="">
              {{ grantItemsLoading ? '加载中…' : grantSubject ? '请选择条目' : '请先选择档案主体' }}
            </option>
            <option v-for="it in grantItems" :key="it.id" :value="it.id">
              {{ it.title }}（{{ categoryName(it.category) }}）
            </option>
          </select>
        </div>

        <div class="field field--full">
          <label class="field__label" for="gr-hours">{{ t('FamilyView.222460', '有效期') }}</label>
          <select id="gr-hours" v-model.number="grantHours" class="field-control">
            <option :value="0">{{ t('FamilyView.b6444d', '长期有效（直到手动撤销）') }}</option>
            <option :value="24">{{ t('FamilyView.284b07', '24 小时') }}</option>
            <option :value="168">{{ t('FamilyView.e45a81', '7 天') }}</option>
            <option :value="720">{{ t('FamilyView.9401ee', '30 天') }}</option>
          </select>
        </div>
      </div>

      <p class="notice">{{ t('FamilyView.48f774', '授权为只读：对方可以查看被共享的条目，但不能编辑、导出或再分享。') }}</p>
      <p v-if="grantError" class="hint hint--error">{{ grantError }}</p>

      <template #footer>
        <button class="btn-text" type="button" :disabled="creatingGrant" @click="showGrantForm = false">
          取消
        </button>
        <button class="btn-primary" type="button" :disabled="creatingGrant" @click="submitGrant">
          {{ creatingGrant ? '授权中…' : '确认授权' }}
        </button>
      </template>
    </AppSheet>

    <!-- ---------- 共享条目详情（只读） ---------- -->
    <AppSheet v-model="showSharedItem" ::title="sharedDetail?.title ?? t('FamilyView.f104e4', '档案')" @close="sharedDetail = null">
      <p v-if="!sharedDetail && !sharedDetailError" class="hint">{{ t('FamilyView.300ee3', '加载中…') }}</p>
      <p v-else-if="sharedDetailError" class="hint hint--error">{{ sharedDetailError }}</p>
      <div v-else-if="sharedDetail" class="shared-detail">
        <div class="shared-detail__tags">
          <span class="chip">{{ categoryName(sharedDetail.category) }}</span>
          <span class="chip">{{ statusName(sharedDetail.status) }}</span>
          <span class="chip" :class="`chip--sens${sharedDetail.sensitivity}`">
            {{ sensitivityName(sharedDetail.sensitivity) }}
          </span>
        </div>
        <dl class="kv">
          <template v-if="sharedDetail.issuer">
            <dt>{{ t('FamilyView.8eb731', '签发机构') }}</dt>
            <dd>{{ sharedDetail.issuer }}</dd>
          </template>
          <template v-if="sharedDetail.issuedDate">
            <dt>{{ t('FamilyView.0b8bcd', '签发日期') }}</dt>
            <dd>{{ sharedDetail.issuedDate }}</dd>
          </template>
          <template v-if="sharedDetail.expiresAt">
            <dt>{{ t('FamilyView.37eb47', '有效期至') }}</dt>
            <dd>{{ sharedDetail.expiresAt }}</dd>
          </template>
          <template v-if="sharedDetail.remark">
            <dt>{{ t('FamilyView.e03614', '备注') }}</dt>
            <dd class="kv__multi">{{ sharedDetail.remark }}</dd>
          </template>
          <dt>{{ t('FamilyView.093dea', '更新时间') }}</dt>
          <dd>{{ formatTime(sharedDetail.updatedAt) }}</dd>
        </dl>
        <p v-if="sharedDetail.sensitivity >= 3" class="notice notice--warn">
          高敏条目：签发机构与备注不通过协作通道展示。
        </p>
      </div>
    </AppSheet>
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
.page-desc {
  margin: var(--sp-1) 0 0;
  color: var(--text-muted);
  font-size: var(--font-size-sm);
  line-height: 1.6;
  max-width: 640px;
}

.hint {
  color: var(--text-muted);
  font-size: var(--font-size-sm);
  margin-top: var(--sp-4);
  line-height: 1.6;
}
.hint--error {
  color: var(--danger);
}
.hint--foot {
  font-size: 12px;
  margin-top: var(--sp-3);
}

/* ---- 分段控件 ---- */
.seg {
  display: inline-flex;
  gap: 2px;
  padding: 3px;
  margin: var(--sp-4) 0 0;
  background: var(--bg-hover);
  border-radius: var(--g3-pill);
}
.seg--sub {
  margin: var(--sp-3) 0 var(--sp-3);
}
.seg__btn {
  border: none;
  background: transparent;
  color: var(--text-secondary);
  font-size: 13px;
  padding: 6px 14px;
  border-radius: var(--g3-pill);
  transition: background-color var(--spring-fast) ease-out, color var(--spring-fast) ease-out;
  white-space: nowrap;
}
.seg__btn--on {
  background: var(--bg-surface);
  color: var(--text-primary);
  box-shadow: 0 1px 2px rgb(0 0 0 / 0.06);
}
.seg__count {
  margin-left: 4px;
  font-size: 11px;
  color: var(--text-muted);
}

/* ---- 列表 ---- */
.grp-list {
  list-style: none;
  padding: 0;
  margin: var(--sp-3) 0 0;
  display: grid;
  gap: var(--sp-2);
}
.grp-item {
  display: flex;
  align-items: center;
  gap: var(--sp-2);
  background: var(--bg-surface);
  border: 1px solid var(--border-subtle);
  border-radius: var(--g3-lg);
  transition: border-color var(--spring-fast) ease-out;
}
.grp-item:hover {
  border-color: var(--border-strong, var(--border-subtle));
}
.grp-item__main {
  flex: 1;
  min-width: 0;
  display: grid;
  gap: 6px;
  padding: var(--sp-4);
  border: none;
  background: transparent;
  text-align: left;
  color: inherit;
  font: inherit;
  cursor: pointer;
}
.grp-item__top {
  display: flex;
  align-items: center;
  gap: var(--sp-2);
  flex-wrap: wrap;
}
.grp-item__name {
  font-weight: 600;
  font-size: var(--font-size-md);
}
.grp-item__meta {
  display: flex;
  gap: var(--sp-3);
  flex-wrap: wrap;
  font-size: 12px;
  color: var(--text-muted);
}
.grp-item__arrow {
  color: var(--text-muted);
  font-size: 20px;
  padding-right: var(--sp-3);
}

/* ---- 组详情内部 ---- */
.detail {
  display: grid;
  gap: var(--sp-1);
}
.detail__meta {
  display: flex;
  align-items: center;
  gap: var(--sp-2);
  flex-wrap: wrap;
  font-size: 12px;
  color: var(--text-muted);
}
.detail__foot {
  margin-top: var(--sp-4);
  padding-top: var(--sp-3);
  border-top: 1px solid var(--border-subtle);
  display: flex;
  justify-content: flex-end;
}

.pane {
  display: grid;
  gap: var(--sp-2);
}
.pane__action {
  justify-self: start;
  margin-bottom: var(--sp-1);
}

.row-list {
  list-style: none;
  padding: 0;
  margin: 0;
  display: grid;
  gap: var(--sp-2);
}
.row {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: var(--sp-3);
  padding: var(--sp-3);
  background: var(--bg-hover);
  border-radius: var(--g3-sm);
}
.row__main {
  min-width: 0;
  display: grid;
  gap: 4px;
}
.row__title {
  display: flex;
  align-items: center;
  gap: var(--sp-2);
  flex-wrap: wrap;
  font-size: var(--font-size-sm);
  font-weight: 500;
}
.row__meta {
  display: flex;
  gap: var(--sp-3);
  flex-wrap: wrap;
  font-size: 12px;
  color: var(--text-muted);
}
.btn-text.danger {
  color: var(--danger);
  flex-shrink: 0;
}

/* ---- chip ---- */
.chip {
  font-size: 11px;
  padding: 1px 8px;
  border-radius: var(--g3-pill);
  background: var(--bg-surface);
  color: var(--text-secondary);
  font-weight: 400;
}
.chip--own {
  background: color-mix(in srgb, var(--accent) 14%, transparent);
  color: var(--accent);
}
.chip--ok {
  background: color-mix(in srgb, var(--success, #2f9e44) 16%, transparent);
  color: var(--success, #2f9e44);
}
.chip--off {
  background: color-mix(in srgb, var(--text-muted) 16%, transparent);
  color: var(--text-muted);
}
.chip--sens2 {
  background: color-mix(in srgb, var(--warning) 16%, transparent);
  color: var(--warning);
}
.chip--sens3 {
  background: color-mix(in srgb, var(--danger) 16%, transparent);
  color: var(--danger);
}

/* ---- 新建邀请的明文展示 ---- */
.invite-new {
  display: grid;
  gap: var(--sp-2);
  padding: var(--sp-4);
  background: color-mix(in srgb, var(--accent) 8%, transparent);
  border: 1px solid color-mix(in srgb, var(--accent) 26%, transparent);
  border-radius: var(--g3-md, var(--g3-lg));
  margin-bottom: var(--sp-3);
}
.invite-new__warn {
  margin: 0;
  font-size: 12px;
  color: var(--text-secondary);
  line-height: 1.6;
}
.invite-new__code {
  font-family: var(--font-mono, ui-monospace, SFMono-Regular, Menlo, monospace);
  font-size: 28px;
  letter-spacing: 0.22em;
  font-weight: 700;
  color: var(--accent);
  text-align: center;
  padding: var(--sp-2) 0;
  user-select: all;
}
.invite-new__acts {
  display: flex;
  gap: var(--sp-1);
  justify-content: center;
  flex-wrap: wrap;
}
.invite-new__link {
  margin: 0;
  font-size: 12px;
  color: var(--text-muted);
  word-break: break-all;
  text-align: center;
}
.invite-new__meta {
  margin: 0;
  font-size: 12px;
  color: var(--text-muted);
  text-align: center;
}

/* ---- 表单 ---- */
.form-grid {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: var(--sp-3);
}
.field {
  display: flex;
  flex-direction: column;
  gap: 6px;
}
.field--full {
  grid-column: 1 / -1;
}
.field__label {
  font-size: 13px;
  color: var(--text-secondary);
}
.field__label em {
  color: var(--danger);
  font-style: normal;
}
.field__hint {
  font-size: 12px;
  color: var(--text-muted);
  line-height: 1.5;
}
.radios {
  display: grid;
  gap: 6px;
}
.radio {
  display: flex;
  align-items: center;
  gap: var(--sp-2);
  font-size: var(--font-size-sm);
  color: var(--text-secondary);
}

.notice {
  font-size: var(--font-size-sm);
  color: var(--text-secondary);
  background: var(--bg-hover);
  border-radius: var(--g3-sm);
  padding: var(--sp-3);
  margin: var(--sp-3) 0 0;
  line-height: 1.6;
}
.notice--warn {
  color: var(--warning);
  background: color-mix(in srgb, var(--warning) 12%, transparent);
}

/* ---- 共享条目详情 ---- */
.shared-detail {
  display: grid;
  gap: var(--sp-3);
}
.shared-detail__tags {
  display: flex;
  gap: var(--sp-2);
  flex-wrap: wrap;
}
.kv {
  display: grid;
  grid-template-columns: 88px 1fr;
  gap: var(--sp-2) var(--sp-3);
  margin: 0;
}
.kv dt {
  color: var(--text-muted);
  font-size: var(--font-size-sm);
}
.kv dd {
  margin: 0;
  font-size: var(--font-size-sm);
  color: var(--text-primary);
  word-break: break-word;
}
.kv__multi {
  white-space: pre-wrap;
  line-height: 1.6;
}

@media (max-width: 639px) {
  .form-grid {
    grid-template-columns: 1fr;
  }
  .kv {
    grid-template-columns: 1fr;
    gap: 2px var(--sp-3);
  }
  .kv dt {
    margin-top: var(--sp-2);
  }
  .invite-new__code {
    font-size: 22px;
  }
}
</style>
