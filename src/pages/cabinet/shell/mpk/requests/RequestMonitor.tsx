// AgOS · Slice11 (ARS-718) · SCR-R2 — заявка МПК на десктопе: обзор и поставщики.
//
// Две вкладки, и только две (FR-020): «События» не строится — читателя журнала событий по
// заявке нет ни одного, а экран без данных — это `HS-4`.
//
// Мутирующие ходы приходят пропсами и зовут те же RPC, что мобильный шелл (FR-008/FR-009):
// правило исхода живёт в SQL, экран показывает то, что вернула база, и своей ветки решения
// не заводит.

import { useState } from 'react'
import { PhIcon } from '../../components/icons/PhIcon'
import { fmtMoney } from '../../tsp/data/tsp-utils'
import { NBSP } from '../../tsp/data/tsp-dicts'
import { DELIVERY_STATUS_LABEL, mpkCatName, type Pool, type SupplierRow } from '../types'
import { rpcErrorText } from '../data/rpc-error-text'
import {
  avgLinePrice, bucketOf, closureReason, fillPct, isAvgPrice, purchaseAvgPrice, purchaseAvgText,
  statusLabel, supplierPriceText,
} from './requests-model'

export type MonitorView = 'overview' | 'suppliers'

interface Props {
  pool: Pool
  /** Строки поставщиков из `rpc_get_pool_matches`; null — ещё не прочитаны или отказ. */
  suppliers: SupplierRow[] | null
  matchesStatus: 'loading' | 'ready' | 'failed'
  view: MonitorView
  onView: (v: MonitorView) => void
  onBack: () => void
  onRetryMatches: () => void
  /** Перечитать заявку и строки. Зовётся и при ОТКАЗЕ хода: `INVALID_STATUS` означает, что
   *  заявку уже перевели (подметанием или из телефона), и экран обязан показать актуальное
   *  состояние, а не оставить оператора с прежними кнопками (M-006/M-007). */
  onRefresh: () => void
  /** Ходы заявки. Каждый бросает при отказе — текст причины показывает экран. */
  onAcceptPartial: (poolId: string) => Promise<void>
  onReturnBatches: (poolId: string) => Promise<void>
  onConfirmDelivery: (row: SupplierRow) => Promise<void>
}

// ARS-731 (FR-008): локальная карта подписей удалена — она была вторым домом одного
// факта и уже разошлась с мобильным монитором в словах. Подпись берётся из types.ts.

function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="mpkr-field">
      <div className="mpkr-field-l">{label}</div>
      <div className="mpkr-field-v">{children}</div>
    </div>
  )
}

export function RequestMonitor({
  pool, suppliers, matchesStatus, view, onView, onBack, onRetryMatches, onRefresh,
  onAcceptPartial, onReturnBatches, onConfirmDelivery,
}: Props) {
  const [busy, setBusy] = useState(false)
  const [flash, setFlash] = useState<string | null>(null)
  const [error, setError] = useState<{ text: string; code: string | null } | null>(null)
  // id строки, по которой идёт приёмка: блокируется одна кнопка, а не весь список.
  const [confirming, setConfirming] = useState<string | null>(null)

  const chip = statusLabel(pool)
  const closure = closureReason(pool)
  // FR-022: порог показывается ТОЛЬКО из ответа RPC (`minPoolHeads`). Фолбэка-константы
  // здесь нет намеренно: «Минимум для закупки — 10 голов» при отсутствии поля было бы
  // числом, которого нет ни в одном поле ответа, — ровно тот провал, который FR-022
  // называет по имени. Нет поля — нет утверждения о пороге.
  const minHeads = pool.minPoolHeads
  const belowMin = minHeads !== undefined && pool.filledHeads < minHeads

  const run = (fn: () => Promise<void>, okText: string) => {
    setBusy(true)
    setError(null)
    fn()
      .then(() => setFlash(okText))
      .catch((e) => {
        // M-006/M-007 · отказ (в том числе `INVALID_STATUS` — заявку уже перевели
        // подметанием или из телефона): называем причину И перечитываем заявку, чтобы
        // экран показал актуальное состояние, а не прежние кнопки над изменившейся
        // заявкой. Без перечитывания оператор жал бы по несуществующему ходу.
        setError(rpcErrorText(e))
        setFlash(null)
        onRefresh()
      })
      .finally(() => setBusy(false))
  }

  const decisionBlock = () => {
    // FR-006/FR-008 · точка выбора: ровно два хода, оба — RPC мобильного шелла.
    if (pool.dbStatus === 'awaiting_mpk_decision') {
      return (
        <div className="mpkr-act">
          <div className="mpkr-act-t">Нужно ваше решение</div>
          <div className="mpkr-act-n">
            Набрано {pool.filledHeads} из {pool.totalHeads} гол. Срок набора истёк.
            Примите набранное или верните партии поставщикам — они вернутся на рынок.
          </div>
          <div className="mpkr-act-row">
            <button
              type="button"
              className="mpkc-stub-act primary"
              disabled={busy}
              onClick={() => run(() => onAcceptPartial(pool.id), 'Набранное принято — поставщики видны')}
            >
              {busy ? 'Применяем…' : `Принять частично (${pool.filledHeads} гол.)`}
            </button>
            <button
              type="button"
              className="mpkc-stub-act"
              disabled={busy}
              onClick={() => run(() => onReturnBatches(pool.id), 'Партии возвращены поставщикам')}
            >
              Вернуть партии
            </button>
          </div>
        </div>
      )
    }
    // M-008 · заявка набирается, но набрано меньше порога: хода нет, и экран обязан
    // сказать почему, а не молчать. Хода «закрыть набор досрочно» здесь НЕТ намеренно:
    // ни один `FR`/`M` замороженного блока его не требует, а ход, которого никто не
    // заказывал, — это правка замысла мимо гейта (находка converge, якорь 7).
    if ((pool.dbStatus === 'filling' || pool.dbStatus === 'draft') && belowMin) {
      return (
        <div className="mpkr-act">
          <div className="mpkr-act-t">Закупка пока невозможна</div>
          <div className="mpkr-act-n">
            Набрано {pool.filledHeads} из {pool.totalHeads} гол. Минимум для закупки —
            {NBSP}{minHeads} голов.
          </div>
        </div>
      )
    }
    return null
  }

  const overview = () => (
    <>
      {/* FR-010 · причина закрытия — из статуса базы: после возврата партий
          `filledHeads` обнуляется, и по числам недобор неотличим от пустой заявки. */}
      {closure && (
        <div className="mpkr-act closed">
          <div className="mpkr-act-t">{closure.title}</div>
          <div className="mpkr-act-n">{closure.note}</div>
        </div>
      )}

      {decisionBlock()}

      <div className="mpkr-grid">
        <Field label="Набрано">
          <div className="mpkr-prog">
            <div className="mpkr-prog-num">{pool.filledHeads} из {pool.totalHeads} гол</div>
            <div className="mpkr-prog-track">
              <div className="mpkr-prog-fill" style={{ width: `${fillPct(pool)}%` }} />
            </div>
          </div>
        </Field>
        <Field label="Цена заявки">
          {fmtMoney(avgLinePrice(pool))}{NBSP}₸/кг{isAvgPrice(pool) ? ' · средняя по строкам' : ''}
        </Field>
        {/* ARS-831 FR-006 · у несостоявшейся заявки купленного нет — поля нет. FR-004 ·
            состояние числа = состояние списка поставщиков (`matchesStatus`); «Повторить» —
            то же перечитывание, что во вкладке «Поставщики». */}
        {bucketOf(pool) !== 'failed' && (
          <Field label="Средняя закупочная">
            {purchaseAvgText(
              matchesStatus === 'ready' ? purchaseAvgPrice(suppliers ?? []) : matchesStatus,
            )}
            {matchesStatus === 'failed' && (
              <div>
                <button type="button" className="mpkc-stub-act" onClick={onRetryMatches}>Повторить</button>
              </div>
            )}
          </Field>
        )}
        <Field label="Срок поставки">{pool.targetMonth}</Field>
        <Field label="География">{pool.region}</Field>
        {/* Порога нет в ответе — плитки нет: молчание честнее правдоподобной константы. */}
        {minHeads !== undefined && <Field label="Минимум для закупки">{minHeads} гол</Field>}
        <Field label="Заявка создана">{pool.createdAt}</Field>
      </div>

      <div className="mpkr-lines">
        <div className="mpkr-field-l">Категории заявки</div>
        {/* Только категория и цена: ровно то, что отдаёт `rpc_get_my_pools`
            (`lines[{code, price}]`, FR-015) и оставляет `toLines`. Предел голов и порода
            в ответе не приходят — веток под них здесь нет, они были бы мёртвыми (`HS-4`). */}
        {pool.lines.map((l, i) => (
          <div className="mpkr-line" key={i}>
            <span>{mpkCatName(l.catKey)}</span>
            <span>{fmtMoney(l.price)}{NBSP}₸/кг</span>
          </div>
        ))}
      </div>
    </>
  )

  const supplierList = () => {
    if (matchesStatus === 'loading') {
      return (
        <div className="mpkc-skel" aria-busy="true" aria-label="Загрузка поставщиков">
          <div className="mpkc-skel-row" />
          <div className="mpkc-skel-row" />
        </div>
      )
    }
    if (matchesStatus === 'failed') {
      return (
        <div className="mpkc-stub">
          <PhIcon name="wifiSlash" size={40} />
          <div className="mpkc-stub-title">Поставщики не загрузились</div>
          <div className="mpkc-stub-note">Это сбой чтения, а не отсутствие поставщиков.</div>
          <button type="button" className="mpkc-stub-act" onClick={onRetryMatches}>Повторить</button>
        </div>
      )
    }
    const rows = suppliers ?? []
    if (rows.length === 0) {
      return (
        <div className="mpkc-stub">
          <PhIcon name="users" size={40} />
          <div className="mpkc-stub-title">Поставщиков пока нет</div>
          <div className="mpkc-stub-note">К заявке ещё не привязана ни одна партия.</div>
        </div>
      )
    }
    return (
      <>
        {/* M-012 · до закрытия заявки личность поставщика не раскрывается (D-M6-5/12,
            ст. 171). Раскрытие считает база — экран лишь показывает то, что пришло. */}
        {!pool.contactRevealed && (
          <div className="mpkr-note">
            Хозяйство и телефон поставщика раскрываются после закрытия заявки.
          </div>
        )}
        <div className="mpkr-rows">
          {rows.map((s) => (
            <div className="mpkr-srow" key={s.id}>
              <div className="mpkr-cell mpkr-cell-title">
                {/* M-016: после закрытия заявки в строке видно хозяйство и телефон —
                    ровно то, ради чего заявку открывают. Нет телефона в ответе → поле
                    пустое, строка остаётся. */}
                <span className="mpkr-row-title">{s.farmName ?? 'Поставщик скрыт'}</span>
                {/* M-012: до раскрытия не показывается и РАЙОН хозяйства — это адресная
                    привязка поставщика, а не характеристика партии. `rpc_get_pool_matches`
                    отдаёт `region` безусловно (гейт базы стоит на имени и телефоне), так
                    что молчать обязан экран. */}
                <span className="mpkr-row-sub">
                  {pool.contactRevealed
                    ? ([s.district, s.farmPhone].filter(Boolean).join(' · ') || '—')
                    : 'до закрытия заявки'}
                </span>
              </div>
              <div className="mpkr-cell">
                <span className="mpkr-row-title">{s.heads} гол</span>
                <span className="mpkr-row-sub">
                  {[s.breed, s.avgWeight ? `~${s.avgWeight} кг` : null].filter(Boolean).join(' · ')}
                </span>
              </div>
              <div className="mpkr-cell">{supplierPriceText(s)}</div>
              <div className="mpkr-cell">
                <span className={`mpkc-badge ${s.deliveryStatus === 'delivered' ? 'green' : 'neutral'}`}>
                  {DELIVERY_STATUS_LABEL[s.deliveryStatus]}
                </span>
              </div>
              <div className="mpkr-cell">
                {/* FR-009 · приёмка идёт по маршруту строки (`source`), решает это
                    `pool-actions.confirmDeliveryRow`, а не экран.
                    Кнопка показана ТОЛЬКО строке «в пути» (`status = dispatched` в базе):
                    обе RPC приёмки требуют именно этого статуса и иначе бросают
                    `INVALID_STATUS: … (must be dispatched)` — сырым английским текстом
                    оператору. Отгрузку отмечает фермер в своём кабинете, и до неё принимать
                    нечего. Тот же гейт, что в мобильном мониторе. */}
                {s.deliveryStatus === 'in_transit' && (
                  <button
                    type="button"
                    className="mpkc-stub-act"
                    disabled={confirming === s.id}
                    onClick={() => {
                      setConfirming(s.id)
                      setError(null)
                      onConfirmDelivery(s)
                        .then(() => setFlash('Приёмка подтверждена'))
                        // M-011: отказ — строка остаётся в прежнем состоянии, и это сказано.
                        .catch((e) => setError(rpcErrorText(e)))
                        .finally(() => setConfirming(null))
                    }}
                  >
                    {confirming === s.id ? 'Подтверждаем…' : 'Подтвердить приёмку'}
                  </button>
                )}
              </div>
            </div>
          ))}
        </div>
      </>
    )
  }

  return (
    <div className="mpkr">
      <div className="mpkr-mon-head">
        <button type="button" className="mpkr-back" onClick={onBack}>
          <PhIcon name="chevronLeft" size={14} /><span>К списку заявок</span>
        </button>
        <div className="mpkr-mon-title">
          <span className="mpkc-head-name">{pool.title}</span>
          <span className={`mpkc-badge ${chip.tone}`}>{chip.label}</span>
        </div>
      </div>

      <div className="mpkc-tabs" role="tablist" aria-label="Разделы заявки">
        {([['overview', 'Обзор'], ['suppliers', 'Поставщики']] as [MonitorView, string][]).map(([id, label]) => (
          <button
            key={id}
            type="button"
            role="tab"
            aria-selected={view === id}
            className={`mpkc-tab${view === id ? ' on' : ''}`}
            onClick={() => onView(id)}
          >
            <span>{label}</span>
          </button>
        ))}
      </div>

      <div className="mpkc-body">
        <div className="mpkc-body-inner">
          {flash && <div className="mpkr-flash" role="status">{flash}</div>}
          {error && (
            <div className="mpkr-flash bad" role="alert">
              {error.text}
              {error.code && <div className="rpc-error-code">Код: {error.code}</div>}
            </div>
          )}
          {view === 'overview' ? overview() : supplierList()}
        </div>
      </div>
    </div>
  )
}
