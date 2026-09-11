// AgOS · TSP-3 · Мониторинг заявки. Контент зависит от pool.status.
// Анонимность (D40): в filling поставщики показаны без имени (★ · гол · аноним).

import { useEffect, useRef, useState } from 'react'
import { Cta } from '../../components/Cta'
import { PhIcon } from '../../components/icons/PhIcon'
import { fmtMoney } from '../../tsp/data/tsp-utils'
import { NBSP } from '../../tsp/data/tsp-dicts'
import { printDealDoc, fmtDealDate, type DealDocData } from '../../data/deal-doc'
import { useGradeFormula } from '@/hooks/useGradeFormula'
import { useRevealedBatch } from '../data/revealed-batch'
import { mpkCatName, type Pool, type SupplierRow } from '../types'

interface Props {
  pool: Pool
  onClose: () => void
  onPatch: (patch: Partial<Pool>) => void
  toast: (text: string) => void
  onContactTuran: () => void
  mpk?: { orgName: string; region: string; bin: string }            // реквизиты МПК — для документа сделки
  onAdvance?: (poolId: string, status: string) => Promise<void>     // реальный перевод статуса в БД
  onLoadMatches?: (poolId: string) => Promise<SupplierRow[] | null> // реальные поставщики пула
  onConfirmDelivery?: (id: string, source?: SupplierRow['source']) => Promise<void>  // приёмка строки — кусок или партия целиком (ARS-684)
  onSubmitReview?: (batchId: string, rating: number) => Promise<void>  // GAP-REVIEW-MOCK-01: отзыв МПК о фермере
}

// Код категории партии → человекочитаемо (fn_tsp_cat_display отдаёт код bychki/telki/korovy).
const CAT_RU: Record<string, string> = { bychki: 'Бычки', telki: 'Тёлки', korovy: 'Коровы' }
const GRADE_RU: Record<string, string> = { VS: 'КРС · Высшая', S: 'КРС · Первая', NS: 'КРС · Вторая' }
function supplierCatLabel(s: SupplierRow): string {
  const cat = s.cat ? (CAT_RU[s.cat] ?? s.cat) : ''
  const grade = s.grade ? GRADE_RU[s.grade] : ''
  return [cat, grade].filter(Boolean).join(' · ')
}
function deliveryLabel(st: SupplierRow['deliveryStatus']): string {
  switch (st) {
    case 'awaiting_dispatch': return 'Ожидает отгрузки'
    case 'in_transit':        return 'В пути'
    case 'delivered':         return 'Принята'
    case 'withdrawn':         return 'Отозвана'
    default:                  return ''
  }
}
function supplierSum(s: SupplierRow): number {
  return s.avgWeight ? Math.round(s.heads * s.avgWeight * s.price) : 0
}

// Слайс 9 (S4): документ сделки со стороны МПК (покупатель). Куски = поставщики пула.
function minIso(rows: SupplierRow[], key: keyof SupplierRow): string | null {
  const vals = rows.map((r) => r[key]).filter((v): v is string => typeof v === 'string')
  return vals.length ? vals.reduce((a, b) => (a < b ? a : b)) : null
}
function maxIso(rows: SupplierRow[], key: keyof SupplierRow): string | null {
  const vals = rows.map((r) => r[key]).filter((v): v is string => typeof v === 'string')
  return vals.length ? vals.reduce((a, b) => (a > b ? a : b)) : null
}
function buildMpkDealDoc(pool: Pool, suppliers: SupplierRow[], mpk?: Props['mpk']): DealDocData {
  const totalHeads = suppliers.reduce((s, r) => s + r.heads, 0)
  return {
    side: 'mpk',
    dealNo: String(pool.id).slice(0, 8).toUpperCase(),
    self: {
      role: 'Покупатель',
      name: mpk?.orgName || 'Ваше предприятие',
      bin: mpk?.bin ?? null,
      region: mpk?.region ?? pool.region,
    },
    subject: {
      catName: pool.title,
      grade: null,
      breed: null,
      avgWeight: null,      // пул разнородный — вес берём по каждому куску
      fatness: null,
      age: null,
    },
    totalHeads,
    dealPrice: null,        // цена варьируется по кускам — в таблице
    chunks: suppliers.map((s) => ({
      counterparty: s.farmName ?? null,
      counterpartyPhone: s.farmPhone ?? null,
      heads: s.heads,
      price: s.price,
      weight: s.avgWeight ?? null,
      statusLabel: deliveryLabel(s.deliveryStatus),
    })),
    statusLabel: pool.status === 'executed' ? 'Сделка завершена'
      : pool.status === 'executing' ? 'Идёт приёмка'
      : 'Заявка набрана',
    timeline: [
      { label: 'Заявка создана', value: pool.createdAt || '—' },
      { label: 'Первый матч', value: fmtDealDate(minIso(suppliers, 'matchedAt')) },
      { label: 'Пул закрыт (подтверждён)', value: fmtDealDate(minIso(suppliers, 'confirmedAt')) },
      { label: 'Отгрузки начаты', value: fmtDealDate(minIso(suppliers, 'dispatchedAt')) },
      { label: 'Приёмка завершена', value: fmtDealDate(maxIso(suppliers, 'deliveredAt')) },
    ],
  }
}

// Реальный пул — строка БД (UUID). Только для него дёргаем self-serve RPC.
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
// Статусы, которые принимает rpc_self_advance_pool_status ('expired' — демо-only).
const REAL_STATUSES: Pool['status'][] = ['filled', 'executing', 'executed', 'closed']

function avgLinePrice(pool: Pool): number {
  if (pool.lines.length === 0) return 0
  return Math.round(pool.lines.reduce((s, l) => s + l.price, 0) / pool.lines.length)
}

function StarPicker({ value, onChange }: { value: number; onChange: (n: number) => void }) {
  return (
    <div style={{ display: 'flex', gap: 4 }}>
      {[1, 2, 3, 4, 5].map((n) => (
        <button
          key={n}
          onClick={() => onChange(n)}
          style={{ fontSize: 20, color: n <= value ? 'var(--amber)' : 'var(--line)', background: 'none', border: 'none', cursor: 'pointer', padding: 0 }}
        >
          ★
        </button>
      ))}
    </div>
  )
}

// ARS-229 · «Фото и детализация» раскрытой партии (read-only для МПК, post-reveal).
// Личность фермера уже раскрыта (D-M6-5/12) → детализация не нарушает анонимность.
// Лениво: RLS-чтение только при разворачивании. Пусто/закрыто RLS → мягкая деградация.
function RevealedBatchDetail({ batchId }: { batchId: string }) {
  const [open, setOpen] = useState(false)
  const { media, animals, loading, loaded } = useRevealedBatch(batchId, open)
  const isEmpty = loaded && !loading && media.length === 0 && animals.length === 0
  const sexRu = (s: 'm' | 'f' | null) => (s === 'm' ? 'бычок' : s === 'f' ? 'тёлка' : null)
  return (
    <div className="rbd">
      <button className="rbd-toggle" onClick={() => setOpen((v) => !v)} aria-expanded={open}>
        <span className="rbd-caret" data-open={open ? '1' : '0'}><PhIcon name="chevronRight" size={13} /></span>
        Фото и детализация
      </button>
      {open && (
        <div className="rbd-body">
          {loading && <div className="rbd-note">Загрузка…</div>}
          {isEmpty && <div className="rbd-note">Поставщик не добавил фото и детализацию.</div>}
          {media.length > 0 && (
            <div className="rbd-media">
              {media.map((m) => (
                <a
                  key={m.id}
                  className="rbd-thumb"
                  href={m.url ?? undefined}
                  target="_blank"
                  rel="noreferrer"
                >
                  {m.type === 'video'
                    ? <span className="rbd-thumb-ph"><PhIcon name="play" size={18} /></span>
                    : m.url
                      ? <img src={m.url} alt="" loading="lazy" />
                      : <span className="rbd-thumb-ph"><PhIcon name="image" size={18} /></span>}
                </a>
              ))}
            </div>
          )}
          {animals.length > 0 && (
            <div className="rbd-anml">
              <div className="rbd-anml-h">Животные ({animals.length})</div>
              {animals.map((a) => (
                <div className="rbd-anml-row" key={a.id}>
                  <span className="rbd-anml-inzh">{a.inzhNumber || '—'}</span>
                  <span className="rbd-anml-m">
                    {[sexRu(a.sex), a.weightKg ? `${a.weightKg}${NBSP}кг` : null, a.ageMonths ? `${a.ageMonths}${NBSP}мес` : null]
                      .filter(Boolean).join(' · ')}
                  </span>
                </div>
              ))}
            </div>
          )}
        </div>
      )}
    </div>
  )
}

function ModalHead({ title, onClose }: { title: string; onClose: () => void }) {
  return (
    <div className="mpk-modal-head">
      <button className="mpk-back" onClick={onClose} aria-label="Назад">←</button>
      <div className="mpk-modal-title">{title}</div>
    </div>
  )
}

function ProgressLg({ pool }: { pool: Pool }) {
  const pct = pool.totalHeads > 0 ? Math.round((pool.filledHeads / pool.totalHeads) * 100) : 0
  const color = pct < 50 ? 'var(--primary)' : pct <= 80 ? 'var(--amber)' : 'var(--ok)'
  return (
    <div>
      <div className="pool-card-sub" style={{ marginBottom: 6 }}>{pool.filledHeads}/{pool.totalHeads} гол.</div>
      <div className="pool-progress-lg">
        <div className="pool-progress-lg-fill" style={{ width: `${pct}%`, background: color }} />
      </div>
    </div>
  )
}

function LinesList({ pool }: { pool: Pool }) {
  return (
    <div>
      <div className="mpk-field-label">По категориям</div>
      {pool.lines.map((l, i) => (
        <div className="pool-card-sub" key={i}>{mpkCatName(l.catKey)}: {fmtMoney(l.price)}{NBSP}₸/кг</div>
      ))}
    </div>
  )
}

export function PoolMonitorModal({ pool, onClose, onPatch, toast, onContactTuran, mpk, onAdvance, onLoadMatches, onConfirmDelivery, onSubmitReview }: Props) {
  useGradeFormula()
  const realPool = UUID_RE.test(pool.id)
  // Реальные поставщики из БД перекрывают демо-список (контакты — только при executing, D40).
  const [liveSuppliers, setLiveSuppliers] = useState<SupplierRow[] | null>(null)
  // ARS-684 (M-013/M-016): состояние живого чтения read-model — общее для веток filling
  // и executing/filled (обе рисуют suppliers из liveSuppliers через один и тот же источник).
  const [matchesLoading, setMatchesLoading] = useState(() => realPool && !!onLoadMatches)
  const [matchesError, setMatchesError] = useState(false)
  // Ответы поллинга и ручного перечита могут прийти НЕ в порядке отправки: перечит
  // после приёмки обгоняется ответом опроса, выданного до неё, и строка откидывается
  // назад в «В пути» до следующего тика. Поэтому применяем только ответ, который не
  // старше уже применённого (номер выдачи, а не времени прихода).
  const reqSeq = useRef(0)
  const appliedSeq = useRef(0)
  const applyMatches = (rows: SupplierRow[] | null, seq: number) => {
    if (seq < appliedSeq.current) return
    appliedSeq.current = seq
    if (rows !== null) { setLiveSuppliers(rows); setMatchesError(false) } else { setMatchesError(true) }
    setMatchesLoading(false)
  }
  useEffect(() => {
    if (!realPool || !onLoadMatches) { setMatchesLoading(false); return }
    let alive = true
    const load = () => {
      const seq = ++reqSeq.current
      return onLoadMatches(pool.id).then((rows) => { if (alive) applyMatches(rows, seq) })
    }
    load()
    // Лёгкий поллинг (Слайс 9 S3): пока модалка открыта, тихо перечитываем строки —
    // МПК видит отгрузку фермера (matched→dispatched) без переоткрытия окна.
    const iv = setInterval(load, 8000)
    return () => { alive = false; clearInterval(iv) }
  }, [realPool, pool.id, onLoadMatches])

  // Ручной перечит после действия (приёмка, ARS-684 FR-005): строка обязана показать
  // состояние ИЗ БАЗЫ, а не локально угаданное. Тот же путь, что и поллинг выше.
  const reloadMatches = (): Promise<SupplierRow[] | null> => {
    if (!onLoadMatches) return Promise.resolve(null)
    const seq = ++reqSeq.current
    return onLoadMatches(pool.id).then((rows) => { applyMatches(rows, seq); return rows })
  }

  const suppliers = liveSuppliers ?? pool.suppliers ?? []
  const avgPrice = avgLinePrice(pool)

  // Баннер ошибки/офлайн (M-013) и заметка первой загрузки (M-016) — общие для веток
  // filling и executing/filled, обе показывают suppliers из живого чтения.
  const matchesErrorNote = matchesError
    ? <div className="mpk-error-hint" style={{ marginBottom: 8 }}>Не удалось обновить список</div>
    : null
  const matchesLoadingNote = realPool && matchesLoading
    ? <div className="pool-card-sub">Загрузка…</div>
    : null
  // «Поставщиков пока нет» (M-005) — утверждение О БАЗЕ, поэтому только когда список
  // РЕАЛЬНО прочитан и пуст. При сбое чтения (M-013) liveSuppliers остаётся null, и
  // подпись не показывается: «не смогли прочитать» ≠ «поставщиков нет».
  const matchesEmptyNote = realPool && liveSuppliers !== null && liveSuppliers.length === 0
    ? <div className="pool-card-sub">Поставщиков пока нет</div>
    : null

  const downloadDoc = () => {
    const ok = printDealDoc(buildMpkDealDoc(pool, suppliers, mpk))
    if (!ok) toast('Разрешите всплывающие окна, чтобы скачать документ')
  }

  const patchSupplier = (id: string, patch: Partial<SupplierRow>) => {
    if (liveSuppliers) {
      setLiveSuppliers(liveSuppliers.map((s) => (s.id === id ? { ...s, ...patch } : s)))
    } else {
      onPatch({ suppliers: suppliers.map((s) => (s.id === id ? { ...s, ...patch } : s)) })
    }
  }

  // Демо-патч статуса + (для реального пула) реальный перевод в БД через RPC.
  // FR-007: у реального пула на экране не остаётся состояние, которого нет в базе —
  // при отказе RPC локальный патч откатывается. Прогресс (filledHeads) огорожен тем же
  // правилом ниже; статус пула был из него выпущен.
  const applyStatus = (patch: Partial<Pool>) => {
    const prevStatus = pool.status
    onPatch(patch)
    const st = patch.status
    if (realPool && onAdvance && st && REAL_STATUSES.includes(st)) {
      onAdvance(pool.id, st).catch((e) => {
        onPatch({ status: prevStatus })
        toast('Не удалось обновить статус: ' + (e instanceof Error ? e.message : ''))
      })
    }
  }

  // ── filling ───────────────────────────────────────────────────────────
  if (pool.status === 'filling') {
    const addSupplier = () => {
      const next: SupplierRow = {
        id: `s${Date.now()}`, rating: 4.0, heads: 20, price: avgPrice || pool.lines[0]?.price || 0,
        deliveryStatus: 'awaiting_dispatch',
      }
      onPatch({ suppliers: [...suppliers, next], filledHeads: Math.min(pool.totalHeads, pool.filledHeads + 20) })
    }
    return (
      <div className="mpk-modal">
        <ModalHead title={pool.title} onClose={onClose} />
        <div className="mpk-modal-body">
          <ProgressLg pool={pool} />
          <LinesList pool={pool} />

          <div>
            <div className="mpk-field-label">Поставщики ({suppliers.length})</div>
            {matchesErrorNote}
            {matchesLoadingNote ?? matchesEmptyNote ?? (suppliers.length === 0 ? null : (
              <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
                {suppliers.map((s) => (
                  <div className="supplier-row" key={s.id}>
                    <div className="supplier-row-t">
                      {/* FR-015: своя прошлая оценка либо прочерк. Демо-строки несут свой
                          rating (разные значения) — константы 4.5 у реальных строк больше нет. */}
                      <span>★ {(s.myRating ?? s.rating) != null ? (s.myRating ?? s.rating)!.toFixed(1) : '—'} · {s.heads} гол</span>
                      <span className="supplier-row-s">аноним</span>
                    </div>
                  </div>
                ))}
              </div>
            ))}
            <div className="mpk-error-hint" style={{ color: 'var(--ink-3)', marginTop: 8 }}>
              Личность поставщика раскрывается только после подтверждения сделки
            </div>
          </div>

          {/* FR-007: дорисовывающие поставщиков элементы — только демо (по образцу «Демо: фермер отгрузил»). */}
          {!realPool && (
            <Cta variant="ghost" onClick={addSupplier}>+ Добавить поставщика</Cta>
          )}
          <Cta onClick={() => {
            // FR-007: для реального пула прогресс обязан прийти из базы — filledHeads не дорисовываем,
            // applyStatus обновит статус в БД (onAdvance), а следующий refetch принесёт настоящий filledHeads.
            applyStatus(realPool ? { status: 'filled' } : { status: 'filled', filledHeads: pool.totalHeads })
            toast('Заявка набрана')
          }}>
            Все набраны
          </Cta>
          {!realPool && (
            <Cta variant="ghost" onClick={() => { onPatch({ status: 'expired' }); toast('Срок заявки истёк') }}>
              Истёк срок
            </Cta>
          )}
          <Cta variant="danger" onClick={() => { applyStatus({ status: 'closed' }); toast('Заявка отменена'); onClose() }}>
            Отменить заявку
          </Cta>
        </div>
      </div>
    )
  }

  // ── expired ─────────────────────────────────────────────────────────────
  if (pool.status === 'expired') {
    if (suppliers.length === 0) {
      return (
        <div className="mpk-modal">
          <ModalHead title={pool.title} onClose={onClose} />
          <div className="mpk-modal-body">
            <div className="mpk-banner bad"><div className="mpk-banner-t">Истекла — не набрана</div></div>
            <div className="pool-card-sub">За время действия заявки не поступило ни одного предложения.</div>
            <Cta onClick={() => { onClose(); toast('Создайте новую заявку через «+ Создать»') }}>Создать новую заявку</Cta>
          </div>
        </div>
      )
    }
    return (
      <div className="mpk-modal">
        <ModalHead title={pool.title} onClose={onClose} />
        <div className="mpk-modal-body">
          <div className="mpk-banner neutral"><div className="mpk-banner-t">⚠ Срок истёк</div></div>
          {/* FR-007: выдуманный срок — ветка 'expired' и так недостижима для реального пула
              (статус ставится только локально, REAL_STATUSES его не содержит), но не полагаемся
              на это молча — гейт явный. */}
          {!realPool && (
            <div className="pool-card-sub">Осталось решить: 23 ч 41 мин</div>
          )}
          <div className="pool-card-sub">
            Набрано {pool.filledHeads} из {pool.totalHeads} · средняя цена {fmtMoney(avgPrice)}{NBSP}₸/кг
          </div>
          <Cta onClick={() => { applyStatus({ status: 'executed', executionResult: 'partial' }); toast('Собранный объём принят') }}>
            Принять собранный объём
          </Cta>
          <Cta variant="ghost" onClick={() => { applyStatus({ status: 'closed' }); toast('Партии возвращены поставщикам') }}>
            Вернуть поставщикам
          </Cta>
          <div className="mpk-error-hint" style={{ color: 'var(--ink-3)' }}>
            Решение на всю заявку. Не решите за 24 ч — партии вернутся автоматически.
          </div>
          <button className="mpk-back" style={{ paddingLeft: 0, color: 'var(--ink-3)', fontSize: 13 }} onClick={onContactTuran}>
            Обратиться в TURAN
          </button>
        </div>
      </div>
    )
  }

  // ── filled / executing (приёмка по маршруту строки) ──────────────────────
  // Слайс 9 S3 + ARS-684: контакты раскрыты по факту закрытия пула (mpk_contact_revealed_at),
  // а приёмку МПК подтверждает по КАЖДОЙ строке (кусок или партия целиком — см. s.source),
  // как только фермер её отгрузил. Поэтому отдельный шаг «Перейти к приёмке» не нужен —
  // filled и executing едины: как только пул набран, МПК сразу видит строки и принимает отгруженные.
  if (pool.status === 'executing' || pool.status === 'filled') {
    const allDone = suppliers.length > 0
      && suppliers.every((s) => s.deliveryStatus === 'delivered' || s.deliveryStatus === 'withdrawn')
    const anyInTransit = suppliers.some((s) => s.deliveryStatus === 'in_transit')
    return (
      <div className="mpk-modal">
        <ModalHead title={pool.title} onClose={onClose} />
        <div className="mpk-modal-body">
          <div className="mpk-banner ok"><div className="mpk-banner-t">
            {anyInTransit ? 'Идёт приёмка'
              : pool.status === 'filled' ? '✓ Заявка набрана — ждём отгрузки от поставщиков'
              : 'Идёт приёмка'}
          </div></div>
          <Cta variant="ghost" onClick={downloadDoc}>Скачать документ сделки</Cta>
          {matchesErrorNote}
          {matchesLoadingNote}
          {/* M-005: набранный пул с пустым списком — ровно тот симптом, с которого начался
              слайс, поэтому подпись обязана быть и здесь, а не только в ветке filling
              (closed_filled маппится в 'filled', pools-load.ts:44). */}
          {matchesEmptyNote}
          {/* M-016: список за тем же гейтом загрузки, что в ветке filling. Раньше эта ветка
              рендерила строки БЕЗУСЛОВНО, и до первого ответа сюда попадал бы pool.suppliers
              одновременно с надписью «Загрузка…» — проверено экспериментом (подложенная строка
              просачивалась в DOM). В проде путь замаскирован: toPool всегда ставит
              suppliers: [] реальному пулу (pools-load.ts:78). Но комментарии выше обещают эту
              гарантию для ОБЕИХ ветвей, а структурно она была только в одной. */}
          {!matchesLoadingNote && <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
            {suppliers.map((s) => (
              <div className="supplier-row" key={s.id}>
                <div className="supplier-row-t">
                  <span>{s.farmName ?? 'Хозяйство'}</span>
                  <span className="supplier-row-s">{s.district ?? ''}</span>
                </div>
                {supplierCatLabel(s) && <div className="supplier-row-s">{supplierCatLabel(s)}</div>}
                <div className="supplier-row-s">
                  {s.heads} гол{s.avgWeight ? ` · ~${s.avgWeight}${NBSP}кг` : ''} · {fmtMoney(s.price)}{NBSP}₸/кг
                  {supplierSum(s) > 0 ? ` · ≈ ${fmtMoney(supplierSum(s))}${NBSP}₸` : ''}
                </div>
                {/* FR-003/M-001: телефон хозяйства В СТРОКЕ, а не только в печатном документе.
                    RPC его отдаёт после раскрытия контактов пула, до раскрытия присылает null
                    (M-004) — поэтому отдельного гейта здесь не нужно, гейт живёт в базе.
                    Половина смысла слайса — «узнать, у кого купил, и позвонить»: у фермера
                    телефон покупателя печатается в строке (BatchScreen.tsx:287), у комбината
                    не печатался нигде — та самая асимметрия, которую FR-003 и называет. */}
                {s.farmPhone && (
                  <div className="supplier-row-s">
                    <a href={`tel:${s.farmPhone}`}>{s.farmPhone}</a>
                  </div>
                )}
                {s.deliveryStatus === 'awaiting_dispatch' && (
                  <>
                    <div className="supplier-status">Ожидает отгрузки</div>
                    {/* Реальный пул: отгрузку отмечает фермер в своём кабинете. Демо-кнопка — только для seed. */}
                    {!realPool && (
                      <Cta variant="ghost" onClick={() => patchSupplier(s.id, { deliveryStatus: 'in_transit' })}>
                        Демо: фермер отгрузил
                      </Cta>
                    )}
                  </>
                )}
                {s.deliveryStatus === 'in_transit' && (
                  <>
                    <div className="supplier-status transit">В пути</div>
                    <Cta onClick={() => {
                      if (realPool && onConfirmDelivery) {
                        // ARS-684 FR-002: адрес приёмки по маршруту строки — кусок (allocation.id)
                        // или партия целиком (batchId).
                        const confirmId = s.source === 'batch' ? s.batchId : s.id
                        if (!confirmId) return
                        onConfirmDelivery(confirmId, s.source)
                          .then(() => {
                            toast('Приёмка подтверждена')
                            // FR-005: строка обязана показать состояние ИЗ БАЗЫ, не локальный патч.
                            reloadMatches()
                          })
                          .catch((e) => {
                            const msg = e instanceof Error ? e.message : ''
                            // M-017: двойной клик / уже принята — перечитываем факт из базы; если
                            // строка там уже delivered, это не ошибка оператора (цель достигнута).
                            reloadMatches().then((rows) => {
                              const fresh = rows?.find((r) => r.id === s.id)
                              if (msg.includes('INVALID_STATUS') && fresh?.deliveryStatus === 'delivered') return
                              toast('Не удалось: ' + msg)
                            })
                          })
                      } else {
                        patchSupplier(s.id, { deliveryStatus: 'delivered' }); toast('Приёмка подтверждена')
                      }
                    }}>
                      Подтвердить приёмку
                    </Cta>
                  </>
                )}
                {s.deliveryStatus === 'delivered' && (
                  <>
                    <div className="supplier-status done">✓ Принята</div>
                    {/* FR-006/M-010,011: отзыв достижим сразу после приёмки, не дожидаясь закрытия
                        всего пула — но ТОЛЬКО на маршруте «партия». Канонический
                        rpc_submit_deal_review гейтит по статусу ПАРТИИ
                        (20260731074557:470 «reviews only from delivered»), а строка-кусок
                        delivered не означает delivered у партии: пока в пути другие куски,
                        отзыв упрётся в INVALID_STATUS. Матрица и говорит про партию
                        («партия принята», M-010/M-011). Для кусков отзыв остаётся там, где был —
                        в ветке executed ниже (пул completed = все партии delivered), поведение
                        куска не меняется (M-007). */}
                    {s.source === 'batch' && <StarPicker
                      value={s.myRating ?? 0}
                      onChange={(n) => {
                        const prev = s.myRating
                        patchSupplier(s.id, { myRating: n })
                        if (realPool && s.batchId && onSubmitReview) {
                          onSubmitReview(s.batchId, n).catch((e) => {
                            // Не оставляем на экране оценку, которой нет в базе (FR-005).
                            patchSupplier(s.id, { myRating: prev })
                            toast('Не удалось отправить отзыв: ' + (e instanceof Error ? e.message : ''))
                          })
                        }
                      }}
                    />}
                  </>
                )}
                {s.deliveryStatus === 'withdrawn' && <div className="supplier-status">Отозвана</div>}
                {realPool && s.batchId && <RevealedBatchDetail batchId={s.batchId} />}
              </div>
            ))}
          </div>}
          {allDone && (
            <Cta onClick={() => { applyStatus({ status: 'executed', executionResult: 'full' }); toast('Сделка завершена') }}>
              Завершить
            </Cta>
          )}
        </div>
      </div>
    )
  }

  // ── executed (и closed) ───────────────────────────────────────────────────
  const allRated = suppliers.length > 0 && suppliers.every((s) => (s.myRating ?? 0) > 0)
  // Итог сделки — сумма по строкам поставщиков (гол × средний вес × цена строки), тем же
  // supplierSum, которым считается «≈ N ₸» в самой строке. Прежняя формула брала выдуманный
  // коэффициент 0.45 вместо настоящего avgWeight и делила так, что печатала величину примерно
  // в 1000 раз меньше действительной (100 гол × 450 кг × 1650 ₸ = 74 млн ₸ → «0.1 млн ₸»).
  // Решение владельца 10.09: считать по настоящим данным, элемент сохранить.
  const dealSum = suppliers.reduce((acc, s) => acc + supplierSum(s), 0)
  return (
    <div className="mpk-modal">
      <ModalHead title={pool.title} onClose={onClose} />
      <div className="mpk-modal-body">
        {pool.status === 'closed' ? (
          <div className="mpk-banner neutral"><div className="mpk-banner-t">Заявка закрыта</div></div>
        ) : (
          <>
            <div className="mpk-banner ok"><div className="mpk-banner-t">✓ Сделка завершена</div></div>
            <div className="pool-card-sub">
              {pool.filledHeads} гол · ср. цена {fmtMoney(avgPrice)}{NBSP}₸/кг
              {dealSum > 0 ? ` · сумма ≈ ${fmtMoney(dealSum)}${NBSP}₸` : ''}
            </div>
            {/* M-013 / M-016: сообщение о сбое чтения и признак загрузки нужны и здесь —
                завершённый пул читает тот же список тем же вызовом. */}
            {matchesErrorNote}
            {matchesLoadingNote}
            <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
              {suppliers.map((s) => (
                <div className="supplier-row" key={s.id}>
                  <div className="supplier-row-t">
                    <span>{s.farmName ?? 'Хозяйство'}</span>
                    <span className="supplier-row-s">{s.heads} гол</span>
                  </div>
                  {s.farmPhone && (
                    <div className="supplier-row-s">
                      <a href={`tel:${s.farmPhone}`}>{s.farmPhone}</a>
                    </div>
                  )}
                  {/* M-011: отзыв — только на принятой строке. Пул может оказаться здесь
                      с непринятыми строками: rollup закрытия считает лишь свой маршрут
                      (POOL-COMPLETE-PER-ROUTE-01), и тогда «в пути» получала бы звёзды,
                      а канон отказал бы («reviews only from delivered»). Состояние строки
                      теперь и подписано — раньше эта ветка его не показывала вовсе. */}
                  <div className={s.deliveryStatus === 'delivered' ? 'supplier-status done' : 'supplier-status'}>
                    {deliveryLabel(s.deliveryStatus)}
                  </div>
                  {s.deliveryStatus === 'delivered' && <StarPicker
                    value={s.myRating ?? 0}
                    onChange={(n) => {
                      const prev = s.myRating
                      patchSupplier(s.id, { myRating: n })
                      // GAP-REVIEW-MOCK-01: одна звёздная форма шлёт то же значение как
                      // overall и как ключевую размерность («Соответствие скота заявленному»,
                      // MS6 §4c) — раздельный ввод второй размерности + комментария не
                      // добавлялся (это отдельное UX-расширение, не входит в этот фикс).
                      if (realPool && s.batchId && onSubmitReview) {
                        onSubmitReview(s.batchId, n).catch((e) => {
                          patchSupplier(s.id, { myRating: prev })
                          toast('Не удалось отправить отзыв: ' + (e instanceof Error ? e.message : ''))
                        })
                      }
                    }}
                  />}
                  {realPool && s.batchId && <RevealedBatchDetail batchId={s.batchId} />}
                </div>
              ))}
            </div>
            {allRated && <div className="mpk-ok-hint">Все поставщики оценены ✓</div>}
          </>
        )}
        {suppliers.length > 0 && (
          <Cta variant="ghost" onClick={downloadDoc}>Скачать документ сделки</Cta>
        )}
        <Cta variant="ghost" onClick={onClose}>Готово</Cta>
      </div>
    </div>
  )
}
