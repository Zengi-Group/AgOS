// AgOS · Slice10 · MP-3.7 (ARS-628) — SCR-P1 «Обзор». Отвечает на один вопрос:
// «можем ли закупать прямо сейчас и что требует действия» (Intent слайса).
//
// ЧТЕНИЕ ЗДЕСЬ НЕ ЖИВЁТ. Агрегат `rpc_get_mpk_profile_overview` (ARS-646 / RPC-64,
// задеплоен 2026-09-09 11:33 UTC) читается на уровне оболочки консоли, а вкладка получает
// данные пропсом — §3.0 «Дом вердикта допуска — БАЗА», решение владельца 2026-09-09.
// Причина не в удобстве: бейдж шапки и заголовок «Обзора» показывают ОДИН факт, и пока
// чтение жило во вкладке, шапка выводила вердикт заново на клиенте. Два вывода одного
// факта расходятся не «если», а «когда» (`P4`).
//
// ДОМ ТЕКСТА — КЛИЕНТ (`FR-006` спеки ARS-646, Dok3 RPC-64): БД отдаёт `kind`/`tone`/
// `action.type` + числа, русские формулировки живут здесь и в `overview-model.ts`.
// Нормативный дом строк, которых прототип не рисовал, — **§3.2 спеки** (`KEEP-10`);
// строки, перенесённые из прототипа дословно, помечены ниже `// прототип` (`FR-015`).

import type { MpkProfileTab } from '../types'
import { PhIcon, type PhIconName } from '../../components/icons/PhIcon'
import { ConsoleSkeleton } from './SectionStub'
import { PEND_FIELD_LABEL, type LoadFailure } from './OrgSection'
import {
  ACTION_TAB, admissionSub, admissionTitle, admissionTone, formatChecked, formatDay,
  formatNumber, formatScore, hasScore, plural,
  type AttentionItem, type DocumentsGate, type MembershipGate, type OverviewGate,
  type OverviewPayload, type Tone, type VerificationGate,
  OVERVIEW_READ_FALLBACK,
} from './overview-model'

// ── Гейты

const GATE_LABEL: Record<OverviewGate['kind'], string> = {
  verification: 'Верификация TURAN',      // прототип L1994
  membership: 'Членство в ассоциации',    // прототип L1999
  documents: 'Документы',                 // прототип L2007
}

const GATE_ICON: Record<OverviewGate['kind'], PhIconName> = {
  // Подстановка Lucide → Phosphor, а не совпадение глифов (§Assumptions: `shield` →
  // `shieldCheck`). Иконки только через `PhIcon` — критерий приёмки 11.
  verification: 'shieldCheck',
  membership: 'briefcase',
  documents: 'fileText',
}

type GateAction =
  | { label: string; go: 'tab'; tab: MpkProfileTab }
  | { label: string; go: 'turan' }

interface GateView {
  kind: OverviewGate['kind']
  tone: Tone
  value: string
  note: string | null
  /** Полоса рисуется ТОЛЬКО там, где под ней есть посчитанное состояние (`KEEP-12`). */
  filled: boolean
  action: GateAction
}

const OPEN_ADMISSION: GateAction = { label: 'Открыть допуск', go: 'tab', tab: 'adm' }   // прототип L1998
// `FR-014` + `KEEP-15`/`KEEP-16`: путь продления и путь к документам ведут в обращение в
// TURAN. Достижимый путь один — шторка «Обратиться в TURAN» в мобильном шелле (тема
// «Документы» в ней уже есть). Тот же приём, что у заглушки `appeals` в MP-3.1, и он
// покрыт тестом `M-011` (переход на `/mpk`), а не только прозой.
const WRITE_TURAN: GateAction = { label: 'Написать в TURAN', go: 'turan' }

function verificationView(g: VerificationGate): GateView {
  if (g.pending_field_count > 0) {
    const n = g.pending_field_count
    return {
      kind: 'verification',
      tone: g.tone,
      value: 'Проверка изменений',   // прототип L1995
      // §3.2: прототип собирает подпись из ИМЁН полей (`pr_pendTxt`), а гейт агрегата
      // отдаёт только счётчик — имена приходят в пункте «требует внимания» ниже.
      // Срок «2–5 раб. дней» — прототип L1996.
      note: `${n} ${plural(n, 'изменение', 'изменения', 'изменений')} на проверке · 2–5 раб. дней`,
      filled: false,
      action: OPEN_ADMISSION,
    }
  }
  if (g.status === 'approved') {
    const day = formatDay(g.approved_at)
    return {
      kind: 'verification',
      tone: g.tone,
      value: 'Подтверждена',   // прототип L1995
      // прототип L1996 — «12 мая 2026 · TURAN Compliance». Дата настоящая; без неё
      // остаётся только источник, выдуманной даты не появляется.
      note: day ? `${day} · TURAN Compliance` : 'TURAN Compliance',
      // Единственное состояние верификации с посчитанной полнотой. Частичной доли
      // прототипа (62%) под собой не имеет ничего — решение владельца 2026-09-09.
      filled: true,
      action: OPEN_ADMISSION,
    }
  }
  if (g.tone === 'unknown') {
    return {
      kind: 'verification',
      tone: 'unknown',
      value: 'Данных пока нет',
      note: 'TURAN ещё не проверял предприятие. Это не отказ.',
      filled: false,
      action: OPEN_ADMISSION,
    }
  }
  return {
    kind: 'verification',
    tone: g.tone,
    value: g.status === 'rejected' ? 'Не подтверждена'
      : g.status === 'expired' ? 'Истекла'
      : g.status === 'conditional' ? 'Подтверждена с условиями'
      : 'Проверка не завершена',
    // Круг правок итерации 2: здесь стояло «Что именно требуется, показано в разделе
    // "Допуск"» — обещание неверное, раздел `adm` ещё заглушка (`ARS-625`). Кнопка
    // «Открыть допуск» остаётся: это навигация самого прототипа (L1998), и вкладка честно
    // говорит о своём состоянии. Врала именно ПОДПИСЬ, а не переход.
    note: g.status === 'expired'
      ? 'Срок действия проверки закончился — нужна повторная.'
      : 'Причину можно уточнить в TURAN.',
    filled: false,
    action: OPEN_ADMISSION,
  }
}

function membershipView(g: MembershipGate): GateView {
  if (!g.is_active) {
    return {
      kind: 'membership',
      tone: g.tone,
      value: 'Членство неактивно',
      note: 'Без активного членства закупки закрыты.',
      filled: false,
      action: WRITE_TURAN,
    }
  }
  // `KEEP-19`: ноль — это «сегодня», а не отсчёт. «0 дней до конца» звучало бы как
  // истёкшее членство, которым оно ещё не стало.
  if (g.days_left === 0) {
    return {
      kind: 'membership',
      tone: g.tone,
      value: 'Истекает сегодня',
      // §3.2 ставит в этой строке «—»: подпись не нужна, значение сказало всё. Первая
      // редакция печатала здесь `plan_title` и расходилась с каноном (нашёл converge).
      note: null,
      filled: false,
      action: WRITE_TURAN,
    }
  }
  if (g.days_left !== null) {
    const end = formatDay(g.current_period_end)
    return {
      kind: 'membership',
      tone: g.tone,
      // прототип L2000 — «12 дней до конца»
      value: `${g.days_left} ${plural(g.days_left, 'день', 'дня', 'дней')} до конца`,
      // прототип L2001 — «Мясной союз Казахстана · до 07 авг 2026». Отсутствующая
      // половина просто не печатается.
      note: [g.plan_title, end ? `до ${end}` : null].filter(Boolean).join(' · ') || null,
      filled: false,
      // `KEEP-16` дословно: путь продления ведёт в TURAN, «то же при `cta = 'manage'`».
      // Первая редакция перевывода оставила здесь тернарник и воспроизвела дефект, из-за
      // которого был откат: при `cta = 'manage'` (живая подписка, `d13_billing.sql`)
      // ссылка уходила в заглушку `adm`. Когда раздел «Допуск» построят (`ARS-625`) —
      // пересмотреть: тогда у «управлять подпиской» появится настоящий дом.
      action: WRITE_TURAN,
    }
  }
  // Штатное состояние сегодняшнего прода: членство активно, срока нет вовсе
  // (`membership_subscription` пуста, все активные членства на легаси-уровне —
  // `DECISIONS_LOG` 2026-09-09). `null` — НЕ ошибка и НЕ ноль.
  return {
    kind: 'membership',
    tone: g.tone,
    value: 'Активно',   // MP-3.1 (`mem_label`), прототип L2225
    note: g.plan_title ? `${g.plan_title} · срок не указан` : 'Срок не указан — членство ведёт ассоциация.',
    filled: false,
    action: WRITE_TURAN,
  }
}

function documentsView(g: DocumentsGate): GateView {
  // Прототип рисует «5 из 5 приняты» (L2007) — этого состояния сегодня быть НЕ МОЖЕТ:
  // счётчика в контракте RPC-64 нет, читателя документов не существует (дом — ARS-363).
  // `KEEP-15`: путь обязан быть ДОСТИЖИМЫМ. Раздела документов в мобильном шелле НЕТ
  // (роуты `home`/`tsp`/`offers`/`profile`) — первый заход обещал его и врал.
  return {
    kind: 'documents',
    tone: 'unknown',
    value: 'Пока не ведётся',
    note: `Документы допуска в кабинете пока не показываются (${g.blocked_by}). Спросить о них можно в TURAN.`,
    filled: false,
    action: WRITE_TURAN,
  }
}

// `KEEP-14`: вид вне закрытого перечня ПРОПУСКАЕТСЯ, а не подписывается текстом соседнего
// вида. Перечень закрыт в контракте, но появление новых кодов — плановое событие: гейт
// `documents` ждёт ARS-363, а `attention` держит зарезервированный `appeal_open` под
// ARS-357/364. Первый заход отдавал `documentsView` на любой неизвестный вид и печатал
// «Документы · Пока не ведётся (undefined)».
function gateView(g: OverviewGate): GateView | null {
  switch (g.kind) {
    case 'verification': return verificationView(g)
    case 'membership': return membershipView(g)
    // Круг правок итерации 2: `KEEP-14` был закрыт только для неизвестного `kind`, а сам
    // гейт документов подписи не проверял — при `available: true` или без `blocked_by` он
    // печатал «Пока не ведётся (undefined)», то есть ровно тот дефект, который `KEEP-14`
    // объявлял починенным. Гейт без признака недоступности пропускается.
    case 'documents':
      return g.available === false && typeof g.blocked_by === 'string' ? documentsView(g) : null
    default: return null
  }
}

// ── «Требует внимания»

interface AttentionView {
  key: string
  icon: PhIconName
  tone: Tone
  title: string
  sub: string
  cta: { label: string; tab: MpkProfileTab } | null
  /** `M-019`, третья клаузула: недоступное действие объясняется, а не просто отсутствует. */
  denied: string | null
}

function attentionView(item: AttentionItem, canReview: boolean): AttentionView | null {
  const tab = ACTION_TAB[item.action?.type]
  switch (item.kind) {
    case 'membership_expiring':
      return {
        key: 'membership_expiring',
        icon: 'clock',   // прототип L2012
        tone: item.tone,
        // прототип L2012 — «Членство истекает через 12 дней»
        title: item.days_left === 0
          ? 'Членство истекает сегодня'
          : `Членство истекает через ${item.days_left} ${plural(item.days_left, 'день', 'дня', 'дней')}`,
        sub: 'Без активного членства закупки закрываются — заявки в работе сохранятся.',   // прототип L2012
        // `KEEP-16`: `FR-014` требует не только «не мутирует», но и «открывает обращение в
        // TURAN». Первый заход уводил в заглушку `adm`, где ни продления, ни пути в TURAN
        // нет — половина требования была не выполнена.
        cta: null,
        denied: null,
      }
    case 'pending_field_review': {
      // Фраза собирается ТЕМ ЖЕ словарём, что и раздел «Предприятие» (`PEND_FIELD_LABEL`,
      // ARS-624) — один дом подписи поля на обе поверхности (`P4`, `KEEP-5`).
      const names = (item.fields ?? []).map((f) => PEND_FIELD_LABEL[f]).filter(Boolean).join(', ')
      return {
        key: 'pending_field_review',
        icon: 'shieldCheck',   // прототип L2013 (`shield` → подстановка)
        tone: item.tone,
        title: 'Реквизиты на повторной проверке',   // прототип L2013
        // прототип L2013 — «{pr_pendTxt} · 2–5 рабочих дней. На закупки не влияет.»
        sub: names
          ? `На проверке: ${names} · 2–5 рабочих дней. На закупки не влияет.`
          : '2–5 рабочих дней. На закупки не влияет.',
        cta: tab ? { label: 'Посмотреть', tab } : null,   // прототип L2013
        denied: null,
      }
    }
    case 'hidden_review':
      // прототип L2014 — «Отзыв КХ «Береке-Восток» скрыт». Имя контрагента приходит
      // законно: пункт возникает только по СВОЕЙ сделке в `delivered`, то есть после
      // `confirmed`, когда раскрытие уже произошло (`FR-001`, D-M6-5/D-M6-12).
      return {
        key: 'hidden_review',
        icon: 'starOutline',   // прототип L2014 (`star` → подстановка)
        tone: item.tone,
        title: item.count > 1
          ? `${item.count} ${plural(item.count, 'отзыв', 'отзыва', 'отзывов')} поставщиков скрыты`
          : (item.counterparty_name ? `Отзыв ${item.counterparty_name} скрыт` : 'Отзыв поставщика скрыт'),
        sub: 'Оцените поставщика — отзывы откроются у обеих сторон.',   // прототип L2014
        cta: canReview && tab ? { label: 'Оценить', tab } : null,   // прототип L2014
        // `KEEP-17` / `M-019`: без права — данные видны, действие недоступно **с пояснением**.
        denied: canReview ? null : 'Оценить может сотрудник с правом на отзывы.',
      }
    default:
      return null
  }
}

// ── Факты. Четыре строки, не пять: пятая строка прототипа «Средний расчёт» (L2021) убрана
// из контракта решением по ARS-646 — платёжных данных у платформы нет и по ст. 171 быть не
// должно, рисовать нечего.
const FACT_ROWS: Array<{ key: keyof OverviewPayload['facts']; label: string }> = [
  { key: 'deals_closed', label: 'Закрытых сделок' },          // прототип L2018
  { key: 'heads_accepted', label: 'Принято голов' },           // прототип L2019
  { key: 'supplier_orgs', label: 'Хозяйств-поставщиков' },     // прототип L2020
  { key: 'staff_active', label: 'Сотрудников' },               // прототип L2022
]

// §3.2, форма `FR-008` и дом-паттерн `MoreTab` («Учёт остатков кормов пока не ведётся»).
// Ноль здесь был бы утверждением «сделок нет», которого система сделать не может.
const FACT_UNAVAILABLE = 'пока не ведётся'

export interface OverviewSectionProps {
  status: 'loading' | 'error' | 'ready'
  payload: OverviewPayload | null
  failure: LoadFailure | null
  organizationId: string | null
  onRetry: () => void
  onOpenTab: (tab: MpkProfileTab) => void
  /** Путь обращения в TURAN. Сегодня ведёт на `/mpk`, где живёт шторка (см. `WRITE_TURAN`). */
  onContactTuran: () => void
}

export function OverviewSection({
  status, payload, failure, organizationId, onRetry, onOpenTab, onContactTuran,
}: OverviewSectionProps) {
  // Организация не разрешена — сетевого вызова не было вовсе (оболочка его не делает,
  // зная локально, что звать не для кого): `p_organization_id = null` дал бы FORBIDDEN.
  if (!organizationId) {
    return (
      <div className="mpkc-stub">
        <div className="mpkc-stub-title">Организация не определена.</div>
      </div>
    )
  }

  // M-015: первый рендер — скелет, без белого провала.
  if (status === 'loading') return <ConsoleSkeleton />

  // M-014: честный текст + retry; сырой текст SDK наружу не идёт (`IDENTITY-14`).
  if (status === 'error' && failure) {
    // `KEEP-6`: `AUTH_REQUIRED` и `FORBIDDEN` — терминальные отказы, «Повторить» повторит
    // тот же отказ.
    if (failure.kind === 'rpc' && failure.code === 'AUTH_REQUIRED') {
      return (
        <div className="mpkc-stub">
          <PhIcon name="lock" size={40} />
          <div className="mpkc-stub-title">Нужно войти, чтобы увидеть сводку по предприятию</div>
        </div>
      )
    }
    if (failure.kind === 'rpc' && failure.code === 'FORBIDDEN') {
      return (
        <div className="mpkc-stub">
          <PhIcon name="lock" size={40} />
          <div className="mpkc-stub-title">Нет доступа к этой организации</div>
          <div className="mpkc-stub-note">Если это ошибка — обратитесь в TURAN.</div>
        </div>
      )
    }
    return (
      <div className="mpkc-stub">
        <PhIcon name="wifiSlash" size={40} />
        <div className="mpkc-stub-title">
          {failure.kind === 'local' ? failure.message : OVERVIEW_READ_FALLBACK}
        </div>
        <button type="button" className="mpkc-stub-act" onClick={onRetry}>Повторить</button>
      </div>
    )
  }

  if (!payload) return <ConsoleSkeleton />

  const { admission, gates, attention, reputation, facts, permissions } = payload
  const checked = formatChecked(admission.checked_at)
  const canReview = permissions['mpk.review.submit'] === true
  // `attention` — всегда массив (посчитанное «чисто» отличимо от «не считалось»).
  // Порядок задаёт `priority` контракта, а не позиция в массиве (`KEEP-4`).
  //
  // Круг правок итерации 2: пропуск неизвестного вида применялся к РЕНДЕРУ и не применялся
  // к счётчику и к пустому состоянию — при зарезервированном `appeal_open` экран показывал
  // «Требует внимания 1» при нуле строк и без «Ничего не требует действий». Фильтруем
  // ОДИН раз здесь, и всё ниже считает по одному и тому же списку.
  const todo = [...attention]
    .sort((a, b) => a.priority - b.priority)
    .map((item) => attentionView(item, canReview))
    .filter((v): v is AttentionView => v !== null)

  const runAction = (action: GateAction) => {
    if (action.go === 'turan') onContactTuran()
    else onOpenTab(action.tab)
  }

  return (
    <div className="mpkc-ov">
      {/* Статус допуска + три гейта — одна карточка (прототип L669-698) */}
      <section className={`mpkc-ov-card mpkc-ov-admission tone-${admissionTone(admission.status)}`}>
        <header className="mpkc-ov-adm-head">
          <span className="mpkc-ov-dot" aria-hidden="true" />
          <div className="mpkc-ov-adm-txt">
            <h2 className="mpkc-ov-adm-title">{admissionTitle(admission.status)}</h2>
            <p className="mpkc-ov-adm-sub">{admissionSub(admission.status, admission.has_pending_reviews)}</p>
          </div>
          {checked && <span className="mpkc-ov-checked">{checked}</span>}
        </header>

        <div className="mpkc-ov-gates">
          {gates.map(gateView).filter((v): v is GateView => v !== null).map((v) => (
            <div key={v.kind} className={`mpkc-ov-gate tone-${v.tone}`}>
              <div className="mpkc-ov-gate-head">
                <span className="mpkc-ov-gate-ico"><PhIcon name={GATE_ICON[v.kind]} size={14} /></span>
                <span className="mpkc-ov-gate-label">{GATE_LABEL[v.kind]}</span>
              </div>
              <div className="mpkc-ov-gate-body">
                <div className="mpkc-ov-gate-value">{v.value}</div>
                {v.note && <div className="mpkc-ov-gate-note">{v.note}</div>}
              </div>
              {/* Полосы нет там, где нет числа: у членства считать не от чего
                  (`days_left = null`), у документов счётчика в контракте нет. */}
              {v.filled && <div className="mpkc-ov-gate-bar" aria-hidden="true"><i /></div>}
              <button type="button" className="mpkc-ov-link" onClick={() => runAction(v.action)}>
                {v.action.label} →
              </button>
            </div>
          ))}
        </div>
      </section>

      <div className="mpkc-ov-mid">
        {/* Требует внимания — прототип L700-724 */}
        <section className="mpkc-ov-card mpkc-ov-todo">
          <header className="mpkc-ov-todo-head">
            <span className="mpkc-ov-todo-title">Требует внимания</span>
            <span className="mpkc-ov-count">{todo.length}</span>
          </header>
          {todo.map((v) => (
              <div key={v.key} className={`mpkc-ov-todo-row tone-${v.tone}`}>
                <span className="mpkc-ov-todo-ico"><PhIcon name={v.icon} size={15} /></span>
                <div className="mpkc-ov-todo-txt">
                  <div className="mpkc-ov-todo-t">{v.title}</div>
                  <div className="mpkc-ov-todo-s">{v.sub}</div>
                  {v.denied && <div className="mpkc-ov-todo-denied">{v.denied}</div>}
                </div>
                {v.key === 'membership_expiring' && (
                  <button type="button" className="mpkc-ov-btn" onClick={onContactTuran}>Продлить</button>
                )}
                {v.cta && (
                  <button type="button" className="mpkc-ov-btn" onClick={() => onOpenTab(v.cta!.tab)}>
                    {v.cta.label}
                  </button>
                )}
              </div>
            ))}
          {todo.length === 0 && (
            <div className="mpkc-ov-clean">
              <PhIcon name="check" size={16} />
              {/* прототип L722 */}
              <span>Ничего не требует действий — профиль в порядке.</span>
            </div>
          )}
        </section>

        {/* Сводка репутации — прототип L726-747. Решение владельца 2026-09-09: гейт FR-011
            («раздел "Репутация" не уходит в прод до ARS-358») читается как раздел /rep,
            сводка на «Обзоре» под него не попадает — данные уже на проде через
            задеплоенный агрегат, отдельной поверхности доступа не появляется. */}
        <section className="mpkc-ov-card mpkc-ov-rep">
          {reputation && reputation.review_count > 0 && hasScore(reputation.average_score) ? (
            <>
              <div className="mpkc-ov-rep-top">
                <span className="mpkc-ov-rep-num">{formatScore(reputation.average_score)}</span>
                <div className="mpkc-ov-rep-cap">
                  <div className="mpkc-ov-rep-of">из 5 · оценки фермеров</div>{/* прототип L731 */}
                  <div className="mpkc-ov-rep-n">
                    {formatNumber(reputation.review_count)}{' '}
                    {plural(reputation.review_count, 'оценка', 'оценки', 'оценок')}
                  </div>
                </div>
              </div>
              <div className="mpkc-ov-dims">
                <Dim label="Общая оценка" value={reputation.average_score} />{/* прототип L2239 */}
                {/* Вторая строка появляется только при своём числе (`KEEP-9`). Подпись — из
                    справочника `review_dimensions.name_ru` (d02_tsp.sql:1712), а не
                    прототипная «Приёмка и расчёт по договорённости»: это другой
                    показатель, и подставить его подпись значило бы соврать (`P8`). */}
                {hasScore(reputation.weight_accuracy_average) && (
                  <Dim label="Соответствие заявленному весу" value={reputation.weight_accuracy_average} />
                )}
              </div>
            </>
          ) : (
            // M-016 (правило): нет отзывов → «оценок пока нет», НЕ «0.0».
            <div className="mpkc-ov-rep-empty">
              <div className="mpkc-ov-rep-of">Оценки фермеров</div>
              <div className="mpkc-ov-rep-none">оценок пока нет</div>
              <div className="mpkc-ov-rep-n">Отзыв открывается, когда оценили обе стороны сделки.</div>
            </div>
          )}
          {/* прототип L746 — `goRep` ведёт на /mpk/profile/rep (D-MPK-NAV-01) */}
          <button type="button" className="mpkc-ov-link" onClick={() => onOpenTab('rep')}>
            Отзывы фермеров →
          </button>
        </section>
      </div>

      {/* Факты — прототип L749-757 */}
      <section className="mpkc-ov-facts">
        {FACT_ROWS.map((row) => {
          // Круг правок итерации 2: раньше здесь стояло `unavailable ? … : formatNumber(raw
          // as number)`, и приведение `as number` было единственной защитой. При
          // отсутствующем или переименованном ключе `isUnavailable` даёт `false`,
          // `formatNumber(undefined)` роняет `toLocaleString`, и вся консоль уходит в белый
          // экран. Ветвимся по НАЛИЧИЮ числа, а не по отсутствию признака; форму заодно
          // держит проверка в `loadOverview`.
          const raw = facts[row.key]
          const hasNumber = typeof raw === 'number'
          return (
            <div key={row.key} className={`mpkc-ov-fact${hasNumber ? '' : ' is-na'}`}>
              <div className="mpkc-ov-fact-label">{row.label}</div>
              <div className="mpkc-ov-fact-value">
                {hasNumber ? formatNumber(raw) : FACT_UNAVAILABLE}
              </div>
            </div>
          )
        })}
      </section>
    </div>
  )
}

function Dim({ label, value }: { label: string; value: number }) {
  return (
    <div className="mpkc-ov-dim">
      <div className="mpkc-ov-dim-row">
        <span className="mpkc-ov-dim-label">{label}</span>
        <span className="mpkc-ov-dim-v">{formatScore(value)}</span>
      </div>
      <div className="mpkc-ov-dim-bar" aria-hidden="true">
        <i style={{ width: `${Math.max(0, Math.min(100, (value / 5) * 100))}%` }} />
      </div>
    </div>
  )
}
