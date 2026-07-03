// AgOS · TSP-3 · Мониторинг заявки. Контент зависит от pool.status.
// Анонимность (D40): в filling поставщики показаны без имени (★ · гол · аноним).

import { useEffect, useState } from 'react'
import { Cta } from '../../components/Cta'
import { fmtMoney } from '../../tsp/data/tsp-utils'
import { NBSP } from '../../tsp/data/tsp-dicts'
import { printDealDoc, fmtDealDate, type DealDocData } from '../../data/deal-doc'
import { MPK_CATS, type Pool, type SupplierRow } from '../types'

interface Props {
  pool: Pool
  onClose: () => void
  onPatch: (patch: Partial<Pool>) => void
  toast: (text: string) => void
  onContactTuran: () => void
  mpk?: { orgName: string; region: string; bin: string }            // реквизиты МПК — для документа сделки
  onAdvance?: (poolId: string, status: string) => Promise<void>     // реальный перевод статуса в БД
  onLoadMatches?: (poolId: string) => Promise<SupplierRow[] | null> // реальные поставщики пула
  onConfirmDelivery?: (allocationId: string) => Promise<void>       // МПК подтверждает приёмку КУСКА (BT-18, Слайс 9 S3)
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
        <div className="pool-card-sub" key={i}>{MPK_CATS[l.catKey].name}: {fmtMoney(l.price)}{NBSP}₸/кг</div>
      ))}
    </div>
  )
}

export function PoolMonitorModal({ pool, onClose, onPatch, toast, onContactTuran, mpk, onAdvance, onLoadMatches, onConfirmDelivery }: Props) {
  const realPool = UUID_RE.test(pool.id)
  // Реальные поставщики из БД перекрывают демо-список (контакты — только при executing, D40).
  const [liveSuppliers, setLiveSuppliers] = useState<SupplierRow[] | null>(null)
  useEffect(() => {
    if (!realPool || !onLoadMatches) return
    let alive = true
    const load = () => onLoadMatches(pool.id).then((rows) => { if (alive && rows !== null) setLiveSuppliers(rows) })
    load()
    // Лёгкий поллинг (Слайс 9 S3): пока модалка открыта, тихо перечитываем куски —
    // МПК видит отгрузку фермера (matched→dispatched) без переоткрытия окна.
    const iv = setInterval(load, 8000)
    return () => { alive = false; clearInterval(iv) }
  }, [realPool, pool.id, onLoadMatches])

  const suppliers = liveSuppliers ?? pool.suppliers ?? []
  const avgPrice = avgLinePrice(pool)

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
  const applyStatus = (patch: Partial<Pool>) => {
    onPatch(patch)
    const st = patch.status
    if (realPool && onAdvance && st && REAL_STATUSES.includes(st)) {
      onAdvance(pool.id, st).catch((e) =>
        toast('Не удалось обновить статус: ' + (e instanceof Error ? e.message : '')))
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
            <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
              {suppliers.map((s) => (
                <div className="supplier-row" key={s.id}>
                  <div className="supplier-row-t">
                    <span>★ {s.rating.toFixed(1)} · {s.heads} гол</span>
                    <span className="supplier-row-s">аноним</span>
                  </div>
                </div>
              ))}
            </div>
            <div className="mpk-error-hint" style={{ color: 'var(--ink-3)', marginTop: 8 }}>
              Личность поставщика раскрывается только после подтверждения сделки
            </div>
          </div>

          <Cta variant="ghost" onClick={addSupplier}>+ Добавить поставщика</Cta>
          <Cta onClick={() => { applyStatus({ status: 'filled', filledHeads: pool.totalHeads }); toast('Заявка набрана') }}>
            Все набраны
          </Cta>
          <Cta variant="ghost" onClick={() => { onPatch({ status: 'expired' }); toast('Срок заявки истёк') }}>
            Истёк срок
          </Cta>
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
          <div className="pool-card-sub">Осталось решить: 23 ч 41 мин</div>
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

  // ── filled / executing (приёмка ПО КУСКАМ) ───────────────────────────────
  // Слайс 9 S3: контакты раскрыты по факту закрытия пула (mpk_contact_revealed_at),
  // а приёмку МПК подтверждает по КАЖДОМУ куску, как только фермер его отгрузил.
  // Поэтому отдельный шаг «Перейти к приёмке» не нужен — filled и executing едины:
  // как только пул набран, МПК сразу видит куски и принимает отгруженные.
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
          <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
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
                        onConfirmDelivery(s.id)
                          .then(() => toast('Приёмка подтверждена'))
                          .catch((e) => toast('Не удалось: ' + (e instanceof Error ? e.message : '')))
                      } else {
                        patchSupplier(s.id, { deliveryStatus: 'delivered' }); toast('Приёмка подтверждена')
                      }
                    }}>
                      Подтвердить приёмку
                    </Cta>
                  </>
                )}
                {s.deliveryStatus === 'delivered' && <div className="supplier-status done">✓ Принята</div>}
                {s.deliveryStatus === 'withdrawn' && <div className="supplier-status">Отозвана</div>}
              </div>
            ))}
          </div>
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
  const sumMln = Math.round((pool.filledHeads * 0.45 * avgPrice) / 100000) / 10
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
              {pool.filledHeads} гол · ср. цена {fmtMoney(avgPrice)}{NBSP}₸/кг · сумма ≈ {sumMln} млн{NBSP}₸
            </div>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
              {suppliers.map((s) => (
                <div className="supplier-row" key={s.id}>
                  <div className="supplier-row-t">
                    <span>{s.farmName ?? 'Хозяйство'}</span>
                    <span className="supplier-row-s">{s.heads} гол</span>
                  </div>
                  <StarPicker value={s.myRating ?? 0} onChange={(n) => patchSupplier(s.id, { myRating: n })} />
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
