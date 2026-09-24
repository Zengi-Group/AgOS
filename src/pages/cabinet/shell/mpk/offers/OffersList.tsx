// AgOS · ARS-785 · Список входящих офферов в десктопной консоли МПК.
//
// Партия фермера без прямого матча разослана подходящим МПК (broadcast, FCFS, окно 24 ч)
// и здесь ВИДНА. Отвечать на неё — ARS-786: кнопок «Принять»/«Отклонить» в этом разделе
// нет намеренно, и это не забытая работа.
//
// Личность фермера не раскрыта (`D-M6-12`) — только характеристики партии. Ст. 171:
// карточка сообщает факты и срок, но не подталкивает («осталось ответить», не «успейте»).

import { PhIcon } from '../../components/icons/PhIcon'
import { fmtMoney } from '../../tsp/data/tsp-utils'
import { NBSP } from '../../tsp/data/tsp-dicts'
import type { IncomingOffer } from '../types'
import { deadlineLabel, offerTitle, offerTonnes, sortByDeadline } from './offers-model'

interface Props {
  /** Исход чтения (ARS-785): три состояния различимы. Демо-офферов нет ни в одном —
   *  в этом разделе их просто нет, «пусто» утверждается только по прочитанному ответу. */
  status: 'loading' | 'ready' | 'failed'
  offers: IncomingOffer[]
  onRetry: () => void
}

function OfferRow({ offer }: { offer: IncomingOffer }) {
  const tonnes = offerTonnes(offer)
  return (
    <div className="mpko-row">
      <div className="mpko-cell mpko-cell-title">
        <span className="mpkr-row-title">{offerTitle(offer)}</span>
        <span className="mpkr-row-sub">{offer.region}</span>
      </div>

      {/* Среднего веса может не быть: партия заполняется постепенно (`P11`), а RPC отдаёт
          `avgWeight` без `coalesce`. «Вес не указан» и «0 кг» — разные факты, и второй был
          бы утверждением о партии, которого база не делала. */}
      <div className="mpko-cell">
        <span className="mpko-num">{offer.heads} гол</span>
        <span className="mpkr-row-sub">
          {offer.avgWeight ? `~${offer.avgWeight}${NBSP}кг средний` : 'вес не указан'}
        </span>
      </div>

      <div className="mpko-cell">
        {tonnes === null ? (
          <span className="mpkr-row-sub">тоннаж не посчитать</span>
        ) : (
          <>
            <span className="mpko-num">{tonnes}{NBSP}т</span>
            <span className="mpkr-row-sub">живого веса</span>
          </>
        )}
      </div>

      <div className="mpko-cell">
        <span className="mpkr-price">{fmtMoney(offer.offeredPrice)}{NBSP}₸/кг</span>
        <span className="mpkr-row-sub">цена поставщика</span>
      </div>

      <div className="mpko-cell">
        <span className="mpko-left"><PhIcon name="clock" size={13} />{deadlineLabel(offer)}</span>
        <span className="mpkr-row-sub">готовы {offer.windowLabel}</span>
      </div>
    </div>
  )
}

export function OffersList({ status, offers, onRetry }: Props) {
  // Порядок задаётся здесь, а не приходит порядком строк RPC: «по сроку ответа» —
  // требование экрана (см. `sortByDeadline`).
  const rows = sortByDeadline(offers)

  return (
    <div className="mpko">
      <div className="mpkc-body">
        <div className="mpkc-body-inner">
          {status === 'loading' && (
            <div className="mpkc-skel" aria-busy="true" aria-label="Загрузка офферов">
              <div className="mpkc-skel-row" />
              <div className="mpkc-skel-row" />
              <div className="mpkc-skel-row" />
            </div>
          )}

          {/* Отказ чтения: честный текст + повтор. «Не прочитали» ≠ «офферов нет» —
              иначе сбой сети выглядел бы как пустой рынок, ровно то, чем слайс занят. */}
          {status === 'failed' && (
            <div className="mpkc-stub">
              <PhIcon name="wifiSlash" size={40} />
              <div className="mpkc-stub-title">Список не загрузился</div>
              <div className="mpkc-stub-note">
                Входящие офферы не удалось прочитать. Это сбой связи с базой, а не пустой список.
              </div>
              <button type="button" className="mpkc-stub-act" onClick={onRetry}>Повторить</button>
            </div>
          )}

          {status === 'ready' && rows.length === 0 && (
            // Пусто — это факт о рынке, и он объясняет себя: иначе оператор читает пустой
            // экран как поломку.
            <div className="mpkc-stub">
              <PhIcon name="mail" size={40} />
              <div className="mpkc-stub-title">Нет входящих офферов</div>
              <div className="mpkc-stub-note">
                Когда подходящая партия не найдёт прямого матча, поставщик пришлёт
                предложение — оно появится здесь.
              </div>
            </div>
          )}

          {status === 'ready' && rows.length > 0 && (
            <>
              <div className="mpko-head" aria-hidden="true">
                <div className="mpko-cell mpko-cell-title">Партия</div>
                <div className="mpko-cell">Поголовье</div>
                <div className="mpko-cell">Тоннаж</div>
                <div className="mpko-cell">Цена</div>
                <div className="mpko-cell">Срок ответа</div>
              </div>
              <div className="mpkr-rows">
                {rows.map((o) => <OfferRow key={o.id} offer={o} />)}
              </div>
              {/* D-M6-12 · сказано один раз для списка, а не на каждой карточке: факт
                  общий для всех офферов и на карточке превращался бы в шум. */}
              <div className="mpkr-note">
                Личность поставщика раскроется при подтверждении сделки.
              </div>
            </>
          )}
        </div>
      </div>
    </div>
  )
}
