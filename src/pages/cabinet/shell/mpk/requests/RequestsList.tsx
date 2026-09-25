// AgOS · Slice11 (ARS-718) · SCR-R1 — список заявок МПК в десктопной консоли.
//
// Каждое число на экране прослеживается до поля ответа `rpc_get_my_pools` (FR-022):
// N = `filledHeads`, M = `totalHeads`, цена = `lines[].price`, срок = `targetMonthIso`
// (человекочитаемо его собирает `toPool` в `data/pools-load.ts`). Ни одной константы,
// ни одного вывода вроде «голов × 0.45».

import { PhIcon } from '../../components/icons/PhIcon'
import { fmtMoney } from '../../tsp/data/tsp-utils'
import { NBSP } from '../../tsp/data/tsp-dicts'
import type { Pool } from '../types'
import {
  REQUESTS_TABS, avgLinePrice, fillPct, filterByTab, isAvgPrice, linesSummary,
  needsDecision, statusLabel, type RequestsTab,
} from './requests-model'

interface Props {
  /** Исход чтения списка (FR-012): три состояния различимы, демо-заявок нет ни в одном. */
  status: 'loading' | 'ready' | 'failed'
  /** Все заявки МПК — счётчики вкладок считаются по ним, а не по отфильтрованным. */
  pools: Pool[]
  counts: Record<RequestsTab, number>
  tab: RequestsTab
  onTab: (tab: RequestsTab) => void
  onOpen: (poolId: string) => void
  onCreate: () => void
  /** Можно ли заводить заявку: организация прочитана. false — кнопка выключена и
   *  объясняет себя, а не молчит (иначе клик по ней неотличим от поломки). */
  canCreate: boolean
  onRetry: () => void
}

function ProgressRow({ pool }: { pool: Pool }) {
  const pct = fillPct(pool)
  const color = pct < 50 ? 'var(--blue)' : pct <= 80 ? 'var(--amber)' : 'var(--green)'
  return (
    <div className="mpkr-prog">
      <div className="mpkr-prog-num">{pool.filledHeads} из {pool.totalHeads} гол</div>
      <div className="mpkr-prog-track">
        <div className="mpkr-prog-fill" style={{ width: `${pct}%`, background: color }} />
      </div>
    </div>
  )
}

function RequestRow({ pool, onOpen }: { pool: Pool; onOpen: (id: string) => void }) {
  const chip = statusLabel(pool)
  const decision = needsDecision(pool)
  return (
    <button type="button" className="mpkr-row" onClick={() => onOpen(pool.id)}>
      <div className="mpkr-cell mpkr-cell-title">
        <span className="mpkr-row-title">{pool.title}</span>
        <span className="mpkr-row-sub">{linesSummary(pool)}</span>
      </div>

      <div className="mpkr-cell">
        <span className={`mpkc-badge ${chip.tone}`}>{chip.label}</span>
      </div>

      <div className="mpkr-cell"><ProgressRow pool={pool} /></div>

      <div className="mpkr-cell">
        <span className="mpkr-price">{fmtMoney(avgLinePrice(pool))}{NBSP}₸/кг</span>
        {isAvgPrice(pool) && <span className="mpkr-row-sub">средняя</span>}
      </div>

      <div className="mpkr-cell">
        <span className="mpkr-month">{pool.targetMonth}</span>
        {/* FR-006: ход виден из строки, а не только после открытия заявки. */}
        {decision && (
          <span className="mpkr-decide"><PhIcon name="alert" size={13} />Принять решение</span>
        )}
      </div>
    </button>
  )
}

export function RequestsList({ status, pools, counts, tab, onTab, onOpen, onCreate, canCreate, onRetry }: Props) {
  // Счётчики считаются по ВСЕМ заявкам, строки — по выбранной вкладке: один источник,
  // две выборки (иначе счётчик вкладки зависел бы от того, на какой вкладке стоишь).
  const rows = filterByTab(pools, tab)

  return (
    <div className="mpkr">
      <div className="mpkc-tabs" role="tablist" aria-label="Состояния заявок">
        {REQUESTS_TABS.map((t) => {
          const on = t.id === tab
          return (
            <button
              key={t.id}
              type="button"
              role="tab"
              aria-selected={on}
              className={`mpkc-tab${on ? ' on' : ''}`}
              onClick={() => onTab(t.id)}
            >
              <span>{t.label}</span>
              {/* M-004: пока список не прочитан, счётчиков НЕТ вовсе. Ноль здесь был бы
                  утверждением «заявок столько», которого мы ещё не знаем (FR-008). */}
              {status === 'ready' && <span className="mpkr-count">{counts[t.id]}</span>}
            </button>
          )
        })}
      </div>

      <div className="mpkc-body">
        <div className="mpkc-body-inner">
          {status === 'loading' && (
            <div className="mpkc-skel" aria-busy="true" aria-label="Загрузка заявок">
              <div className="mpkc-skel-row" />
              <div className="mpkc-skel-row" />
              <div className="mpkc-skel-row" />
            </div>
          )}

          {/* M-003 · отказ чтения: честный текст + повтор. Демо-заявки не показываются
              ни в одном состоянии этого экрана — их здесь просто нет (FR-012). */}
          {status === 'failed' && (
            <div className="mpkc-stub">
              <PhIcon name="wifiSlash" size={40} />
              <div className="mpkc-stub-title">Список не загрузился</div>
              <div className="mpkc-stub-note">
                Заявки не удалось прочитать. Это сбой связи с базой, а не пустой список.
              </div>
              <button type="button" className="mpkc-stub-act" onClick={onRetry}>Повторить</button>
            </div>
          )}

          {status === 'ready' && pools.length === 0 && (
            // M-002 · у пустого кабинета есть ход вперёд, иначе он тупик для нового МПК.
            <div className="mpkc-stub">
              <PhIcon name="fileText" size={40} />
              <div className="mpkc-stub-title">Заявок пока нет</div>
              <div className="mpkc-stub-note">
                Заведите заявку на закупку — фермеры увидят её и смогут привязать свои партии.
              </div>
              <button type="button" className="mpkc-stub-act" onClick={onCreate} disabled={!canCreate}>
                Новая заявка
              </button>
              {!canCreate && (
                <div className="mpkc-stub-note">
                  Данные предприятия не загрузились — заявку пока не завести. Обновите страницу.
                </div>
              )}
            </div>
          )}

          {/* Вкладка без заявок при непустом списке — это не «заявок нет», а «в этом
              состоянии нет»: разные факты, и второй не должен звать заводить новую. */}
          {status === 'ready' && pools.length > 0 && rows.length === 0 && (
            <div className="mpkc-stub">
              <PhIcon name="list" size={40} />
              <div className="mpkc-stub-title">В этой вкладке заявок нет</div>
              <div className="mpkc-stub-note">Остальные заявки видны на вкладке «Все».</div>
            </div>
          )}

          {status === 'ready' && rows.length > 0 && (
            <>
              <div className="mpkr-head" aria-hidden="true">
                <div className="mpkr-cell mpkr-cell-title">Заявка</div>
                <div className="mpkr-cell">Состояние</div>
                <div className="mpkr-cell">Набор</div>
                <div className="mpkr-cell">Цена заявки</div>
                <div className="mpkr-cell">Срок</div>
              </div>
              <div className="mpkr-rows">
                {rows.map((p) => <RequestRow key={p.id} pool={p} onOpen={onOpen} />)}
              </div>
            </>
          )}
        </div>
      </div>
    </div>
  )
}
