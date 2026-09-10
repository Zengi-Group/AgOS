// AgOS · Slice10 · SCR-P2 «Предприятие» (`org`) — левая половина (ARS-624, MP-3.3).
// Круг правок по итогам ревью второй итерации (08.09.2026) — точечные правки поверх
// перевывода, не пересборка. Источник текстов и состава — Docs/AGOS-Dok6-Slice10-MPK-Profile.md
// §4.1/§4.1.1 (FR-015: дословно из прототипа) и §4.1.2 (тексты состояний, которых в
// прототипе нет). Читатель — rpc_get_org_profile (ARS-362, задеплоен 07.09.2026); контракт
// ответа — Docs/AGOS-Dok3-RPC-Catalog-v1_5.md RPC-63 / Docs/AGOS-MPK-Profile-ReadRPC-ARS-362.md
// «Design contract». Закрывает M-007 / M-008 / M-018 (Slice10 I/O-матрица).
//
// Решение владельца этого круга правок (раздел A задания): УБРАНА редактируемость трёх
// блоков, ни один из которых не нужен закрываемым id — «Руководитель» (rpc_update_mpk_org_details),
// три строки «Площадка приёмки» (rpc_save_mpk_primary_site), форма банка
// (rpc_append_org_bank_account). Причина у каждого разная (площадку нельзя создать из
// пустого состояния ни в каком порядке правок; банк без p_is_primary/актуального
// p_previous_account_id достижимо создаёт вторую живую лестницу; правка «Руководителя»
// перезаписывает ВСЕ параметры RPC и способна затереть телефон/e-mail/сайт), но исход
// один — эти три RPC отсюда больше не вызываются. ПОКАЗ сохранён полностью (HS-2): историю
// банка с пометкой «действующий»/«до <дата>», счётчик «показано N из M», текст
// «Реквизиты доступны бухгалтеру и администратору.» при отказе чтения, пустые состояния
// §4.1.2. Редактируемыми остаются только `legal_name`/`address_text`/`bin_iin`
// (rpc_propose_org_field_change) и публичное описание (rpc_upsert_mpk_profile).
//
// Что НЕ строит этот файл (границы ARS-624, §4.1.1 «Что из этих четырёх карточек…»):
//   — карточка 4 «Контакт для фермеров» (мета «раскрывается после сделки») — дом ARS-666;
//   — §4.2 «Превью карточки для фермера» (pv_*, pvPost) — та же ARS-666, ст. 171 ПК РК;
//   — «Часы приёмки» — отменены решением Аршидина 08.09.2026, колонки не существует.
//
// Круг правок B (продуктовый код, см. по месту ниже): FR-016 объяснение read-only на
// КАЖДОЙ карточке (не только у описания) · блок «История правок» (`field_reviews.resolved_recent`,
// был прочитан читателем, но не выведен — теперь построен по образцу истории банка) ·
// try/catch на всех save*-хелперах · IME-composition guard на Enter · blur-отмена строки ·
// contract_version guard на все ключи payload'а, не только на organization · маркеры строк
// «входит в допуск»/«видно фермеру» (источник — сам прототип, `fRow()`/`CRIT`, L1970-1988) ·
// нейтральная заглушка SECTION_STUB.org.
//
// Круг правок C (итерация 3, 08.09.2026, converge): FR-008 — «правка не заведена»
// (`READ_ONLY_NOT_BUILT_NOTE`) больше не печатается безусловно в подвале карточки
// «Предприятие» (врала бы о правах на кликабельных Наименование/БИН/Юр.адрес и дублировала
// «нет права» при !canEdit); перенесена на строку «Руководитель» через `note`-проп
// `StaticRow` — единственную строку, для которой она верна. §4.1.2 канон для пустого
// описания («Профиль предприятия ещё не заполнен. Заполните описание — его увидят
// фермеры.») — раньше стояла неполная фраза, только вторая половина M-018. M-007 — кнопки
// «Сохранить»/«Отмена» (прототип L806-807) в `EditableRow`: раньше сохранить правку можно
// было только Enter, мышью — нечем; `onMouseDown` c `preventDefault` на кнопках не даёт
// клику вызвать `onBlur`-отмену раньше `onClick`. Карандаш (`PhIcon name="pencil"`,
// opacity 0.4) у кликабельного значения — легенда обещала подсказку, строка её не несла.

import { useCallback, useEffect, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { supabase } from '@/lib/supabase'
import { PhIcon } from '../../components/icons/PhIcon'
import { ConsoleSkeleton } from './SectionStub'

const CONTRACT_VERSION = 1

// ── Контракт ответа rpc_get_org_profile (Dok3 RPC-63 / ReadRPC-ARS-362 «Design contract»).
// Имена ключей — 1:1 с jsonb_build_object в d01_kernel.sql (ARS-362 / MP-2.1);
// новых полей UI не выдумывает (FR-008).
interface OrgProfileOrganization {
  id: string
  legal_name: string | null
  bin_iin: string | null
  legal_form: string | null
  region_id: string | null
  region_name: string | null
  district_id: string | null
  address_text: string | null
  phone: string | null
  email: string | null
  website: string | null
  head_full_name: string | null
  head_title: string | null
  is_active: boolean
  org_types: string[]
  created_at: string
  updated_at: string
}

interface OrgProfileMpkProfile {
  public_description: string | null
  logo_path: string | null
  created_at: string
  updated_at: string
}

interface OrgProfileSite {
  id: string
  site_name: string
  region_id: string | null
  region_name: string | null
  address_text: string
  processing_capacity_heads_per_day: number
  phone: string | null
  email: string | null
  is_primary: boolean
  is_active: boolean
  created_at: string
  updated_at: string
}

interface OrgBankAccountRow {
  account_id: string
  logical_account_id: string
  version_no: number
  bank_name: string
  bik: string
  iban: string
  account_holder_name: string
  currency_code: string
  is_primary: boolean
  valid_from: string
  valid_to: string | null
  created_by_user_id: string | null
  created_at: string
}

// MP-3.7 (`KEEP-5`): `export` добавлен аддитивно — «Обзор» собирает ту же фразу
// «На проверке: наименование, БИН» из ТОГО ЖЕ словаря `PEND_FIELD_LABEL` (`P4`, один дом
// подписи поля), а не из второй таблицы переводов. Ни одна строка ниже не менялась.
export type CriticalFieldName = 'legal_name' | 'address_text' | 'bin_iin'

interface OrgFieldReviewPending {
  id: string
  field_name: CriticalFieldName
  previous_value: string
  proposed_value: string
  status: 'pending'
  requested_by_user_id: string | null
  requested_at: string
}

// Блок B.2 — «История правок». Форма 1:1 с jsonb_build_object в d01_kernel.sql
// (rpc_get_org_profile, v_reviews_recent): resolved_recent фильтруется
// `status in ('approved','rejected')` на сервере — `pending` здесь недостижим
// (KEEP-9 Implementation Notes, не заводить ветку под него — HS-4).
interface OrgFieldReviewResolved {
  id: string
  field_name: CriticalFieldName
  previous_value: string
  proposed_value: string
  status: 'approved' | 'rejected'
  requested_by_user_id: string | null
  requested_at: string
  reviewed_by_user_id: string | null
  reviewed_at: string | null
  review_note: string | null
  // Implementation Notes KEEP-1: для legal_name/address_text заполнено ВСЕГДА (значение
  // применяется сразу, до решения TURAN); для bin_iin — только если правку одобрили. Значит
  // `rejected` по legal_name/address_text не означает «ничего не изменилось» — старое
  // значение осталось прод-значением уже с момента отправки, а не с момента решения.
  production_value_applied_at: string | null
}

interface OrgProfilePayload {
  contract_version: number
  organization: OrgProfileOrganization | null
  profile: OrgProfileMpkProfile | null
  primary_site: OrgProfileSite | null
  bank: {
    access: 'granted' | 'denied'
    current: OrgBankAccountRow | null
    history: OrgBankAccountRow[]
    history_total: number
  }
  field_reviews: {
    pending: OrgFieldReviewPending[]
    resolved_recent: OrgFieldReviewResolved[]
    resolved_total: number
  }
  permissions: {
    'mpk.profile.edit': boolean
    'mpk.bank.manage': boolean
  }
}

type SaveResult = { ok: true } | { ok: false; message: string }

export type LoadFailure =
  | { kind: 'rpc'; code: string }
  | { kind: 'local'; message: string }

// FR-018 / M-011: наружу приходит только код, без человекочитаемого текста — тексты
// живут на клиенте (`AGOS-MPK-Profile-ReadRPC-ARS-362.md` «UI contract»). Сравнение —
// по коду ДО ДВОЕТОЧИЯ: путь FORBIDDEN несёт машинный хвост
// («FORBIDDEN: not a member of organization <id>»), сравнивать строку целиком нельзя.
export function parseRpcCode(message: string | null | undefined): string {
  return ((message ?? '').split(':')[0] ?? '').trim()
}

// KEEP-4: тексты ошибок ЧТЕНИЯ и ЗАПИСИ — разные фолбэки, а не общая фраза «Не удалось
// сохранить изменение» на отказ загрузки.
const READ_FALLBACK = 'Не удалось загрузить данные предприятия. Проверьте соединение и повторите.'
const WRITE_FALLBACK = 'Не удалось сохранить изменение. Повторите позже.'

// KEEP-5: собственные (не-RPC) ошибки — например, несовпадение contract_version — НЕ
// пропускаются через парсер кода: `readErrorText` для `kind: 'local'` возвращает текст
// как есть, минуя сравнение по коду до двоеточия.
function readErrorText(failure: LoadFailure): string {
  if (failure.kind === 'local') return failure.message
  if (failure.code === 'PROFILE_READ_FAILED') return READ_FALLBACK
  return READ_FALLBACK
}

// Тексты отказов ПИСАТЕЛЕЙ, оставшихся после круга правок A (rpc_propose_org_field_change +
// rpc_upsert_mpk_profile — оба ARS-359) — по коду до двоеточия, тот же приём, что у читателя.
// Коды, принадлежавшие ТОЛЬКО трём убранным писателям (rpc_update_mpk_org_details:
// INVALID_EMAIL; rpc_save_mpk_primary_site: CAPACITY_MUST_BE_POSITIVE/SITE_NOT_FOUND/
// INVALID_EMAIL; rpc_append_org_bank_account: INVALID_BIK/INVALID_IBAN/
// BANK_ACCOUNT_NOT_FOUND/BANK_ACCOUNT_VERSION_NOT_CURRENT) удалены — они больше недостижимы
// из этого файла (HS-4), сверено по телам функций в d01_kernel.sql.
const WRITE_ERROR_TEXT: Record<string, string> = {
  AUTH_REQUIRED: 'Сессия истекла. Войдите заново, чтобы сохранить изменение.',
  FORBIDDEN: 'У вас нет права на это изменение.',
  ORG_NOT_ACTIVE_MPK: 'Организация не активна как МПК — изменение не сохранено.',
  INVALID_REVIEW_FIELD: 'Это поле нельзя предложить на проверку.',
  FIELD_VALUE_REQUIRED: 'Значение не может быть пустым.',
  INVALID_BIN_IIN: 'БИН должен состоять из 12 цифр.',
  LEGAL_NAME_TOO_LONG: 'Наименование слишком длинное.',
  ADDRESS_TOO_LONG: 'Адрес слишком длинный.',
  FIELD_VALUE_UNCHANGED: 'Значение не изменилось.',
  FIELD_REVIEW_ALREADY_PENDING: 'По этому полю уже есть правка на проверке.',
}
function writeErrorText(code: string): string {
  return WRITE_ERROR_TEXT[code] ?? WRITE_FALLBACK
}

// B.1 / FR-016 (§4.1.2, «нет права на правку», дословно) — единственный текст, объясняющий
// read-only по каждой карточке, у которой сейчас нет ни одного редактируемого поля.
// Раньше стоял только у карточки описания (своей фразой, не канонической) — остальные три
// карточки при !canEdit молчали: сотрудник видел значения без объяснения, почему их нельзя
// менять (нарушение самого FR-016 — «read-only, а не скрыто, то есть сотрудник должен
// понимать»). Текст один и тот же везде, канон не варьируется по карточке.
const NO_EDIT_RIGHT_NOTE = 'На изменение этих данных нет права. Данные видны, править их может администратор предприятия.'
// §4.1.2: ДРУГАЯ причина read-only — правка не заведена на этом экране, а не отсутствие права.
// Разделять обязательно: подпись «нет права» на карточке, где пользователь править МОЖЕТ,
// утверждает о правах ложь (FR-008) — найдено на экране владельцем 08.09.
const READ_ONLY_NOT_BUILT_NOTE = 'Пока только просмотр: изменение этих данных на этом экране ещё не заведено.'

// pr_pendTxt (§4.1.1, L1990-1991) — русские подписи ИМЕННО в этом регистре, дословно.
export const PEND_FIELD_LABEL: Record<CriticalFieldName, string> = {
  legal_name: 'наименование',
  bin_iin: 'БИН',
  address_text: 'юридический адрес',
}

// B.2 — подписи для блока «История правок». Не то же самое, что PEND_FIELD_LABEL (тот
// собирает фразу «На проверке: наименование, БИН» строчными и через запятую) — здесь
// каждое поле стоит отдельной строкой списка, поэтому регистр — как в заголовках строк
// карточки 1 («Наименование», «БИН», «Юридический адрес»), а не как в pr_pendTxt.
const RESOLVED_FIELD_LABEL: Record<CriticalFieldName, string> = {
  legal_name: 'Наименование',
  bin_iin: 'БИН',
  address_text: 'Юридический адрес',
}

function formatDate(iso: string): string {
  try { return new Date(iso).toLocaleDateString('ru-RU') } catch { return iso }
}

async function loadOrgProfile(
  organizationId: string,
): Promise<{ payload: OrgProfilePayload } | { failure: LoadFailure }> {
  let data: unknown
  let error: { message?: string } | null
  try {
    const res = await supabase.rpc('rpc_get_org_profile', { p_organization_id: organizationId })
    data = res.data
    error = res.error
  } catch (e) {
    // Сетевой/JS-сбой — НЕ код RPC (KEEP-5): не пропускаем через parseRpcCode.
    console.error('OrgSection: rpc_get_org_profile threw:', e)
    return { failure: { kind: 'local', message: READ_FALLBACK } }
  }
  if (error) {
    console.error('OrgSection: rpc_get_org_profile error:', error)
    return { failure: { kind: 'rpc', code: parseRpcCode(error.message) } }
  }
  const payload = data as OrgProfilePayload | null
  // KEEP-7 / D-RPC-CONTRACT-SYNC-01: несовпадение contract_version — честный отказ,
  // а не полупустой экран по устаревшей форме ответа.
  // Круг правок B.5: version=1 сам по себе не гарантирует форму — раньше проверялось
  // только `organization`, и отсутствие bank/field_reviews/permissions в ответе давало
  // TypeError при первом же обращении к payload.bank.access и т.п. Проверяем все четыре
  // ключа, которые компонент читает ниже, а не один.
  if (
    !payload
    || payload.contract_version !== CONTRACT_VERSION
    || !payload.organization
    || !payload.bank
    || !payload.field_reviews
    || !payload.permissions
  ) {
    console.error('OrgSection: unexpected rpc_get_org_profile payload shape', payload)
    return { failure: { kind: 'local', message: 'Контракт ответа не распознан. Обновите страницу.' } }
  }
  return { payload }
}

// Маркеры строк (§4.1.1 «Легенда», L777-782 · разметка строк L787-793). Источник — сам
// прототип, не догадка: `fRow(key, label, pub)` в Кабинет МПК v4.dc.html:1970-1988 отдаёт
// `crit = this.CRIT.indexOf(key) >= 0` (L1971, `CRIT = ["name","bin","jaddr"]`, L1492 — те
// же три поля, что D-MPK-CRIT-03) и `pub = !!pub` — третий аргумент вызова fRow. Card 1:
// name(1,1) bin(1,1) jaddr(1,0) head(0,0); Card 2 (после отмены «Часов приёмки»):
// place(0,1) capacity(0,0) placePhone(0,1); Card 3: bank/iik/bik все (0,0).
function RowMarkers({ crit, pub }: { crit?: boolean; pub?: boolean }) {
  if (!crit && !pub) return null
  return (
    <span className="mpkc-req-markers">
      {crit && <PhIcon name="shieldCheck" size={14} color="var(--amber)" />}
      {pub && <PhIcon name="eye" size={14} color="var(--fg3)" />}
    </span>
  )
}

// ── Строка с правкой по клику (§4.1.1 «Взаимодействие», L1978): клик по значению начинает
// правку, Enter сохраняет, Escape отменяет. FR-016/M-019: без права поля читаются, но не
// кликабельны — `<span>`, а не задизейбленная кнопка (значение видно, а не спрятано).
function EditableRow({
  label, value, displayValue, canEdit, pending, hint, maxLength, filter, crit, pub, onSave,
}: {
  label: string
  value: string
  displayValue: string
  canEdit: boolean
  pending?: boolean
  hint?: string
  maxLength?: number
  filter?: (raw: string) => string
  crit?: boolean
  pub?: boolean
  onSave: (next: string) => Promise<SaveResult>
}) {
  const [editing, setEditing] = useState(false)
  const [draft, setDraft] = useState(value)
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => { if (!editing) setDraft(value) }, [value, editing])

  const startEdit = () => {
    if (!canEdit || pending || saving) return
    setDraft(value)
    setError(null)
    setEditing(true)
  }
  const cancel = () => { setEditing(false); setError(null); setDraft(value) }

  const commit = async () => {
    if (saving) return
    const next = draft.trim()
    if (next === '') { setError('Поле не может быть пустым.'); return }
    setSaving(true)
    setError(null)
    const res = await onSave(next)
    setSaving(false)
    if (res.ok) setEditing(false)
    else setError(res.message)
  }

  return (
    <div className="mpkc-req-row">
      <div className="mpkc-req-row-head">
        <span className="mpkc-req-label">{label}</span>
        <RowMarkers crit={crit} pub={pub} />
      </div>
      {/* Правая ячейка сетки (§4.1.1 «Структура карточки») — режим правки ИЛИ строка
          чтения (значение · Badge · карандаш), а не отдельные grid-элементы: тогда
          двухколоночная сетка `.mpkc-req-row` осталась бы ровно с двумя детьми. */}
      <div className="mpkc-req-row-value">
        {editing ? (
        <div className="mpkc-req-edit">
          <input
            className="mpkc-req-input"
            value={draft}
            autoFocus
            disabled={saving}
            maxLength={maxLength}
            onChange={(e) => setDraft(filter ? filter(e.target.value) : e.target.value)}
            onKeyDown={(e) => {
              if (e.key === 'Enter') {
                // B.4: Enter, зафиксировавший IME-композицию (кириллица/казахский набор
                // через составные раскладки), сохранял бы недособранный текст — тот же
                // символ Enter сначала подтверждает композицию, потом должен ввести строку.
                if ((e.nativeEvent as KeyboardEvent).isComposing) return
                e.preventDefault(); void commit()
              } else if (e.key === 'Escape') { e.preventDefault(); cancel() }
            }}
            // B.6: клик мимо строки раньше оставлял её в режиме правки бессрочно — Enter/
            // Escape (прототип, §4.1.1) не ломаются: они не вызывают blur сами по себе,
            // отмена по ним срабатывает раньше через cancel()/commit() в onKeyDown. Во время
            // сохранения onBlur не отменяет — иначе сетевой ответ придёт в уже закрытую форму.
            // Круг правок C / M-007: клик мышью по кнопке «Сохранить» ниже тоже переносит
            // фокус и вызвал бы этот же onBlur ДО клика — см. onMouseDown на кнопках, который
            // это предотвращает; сам onBlur не трогаем, он по-прежнему обязан отменять правку
            // при уходе фокуса куда угодно ЕЩЁ (клик вне строки).
            onBlur={() => { if (!saving) cancel() }}
          />
          {/* Круг правок C / M-007: единственный способ сохранить правку раньше — Enter,
              мышью сохранить было нечем (прототип, `Кабинет МПК v4.dc.html:806-807`, variant
              cta/ghost). Клавиатурный путь не заменён — Enter/Escape делают то же самое.
              Класс `.mpkc-req-actions` уже был в CSS (мёртвый, из убранной формы) — не заводим
              новый. Кнопки переиспользуют `.mpkc-stub-act` — тот же класс, что у «Сохранить»
              в PublicDescriptionCard ниже, единый стиль действия внутри консоли. */}
          <div className="mpkc-req-actions">
            <button
              type="button"
              className="mpkc-stub-act"
              disabled={saving}
              data-testid="mpkc-req-save"
              // Без preventDefault здесь mousedown переносит фокус с input на кнопку ДО
              // click — onBlur успевает отменить правку (setEditing(false)), и click иногда
              // попадает уже в закрытую/переразмеченную форму: находка владельца 08.09,
              // «клик по значению — правка», но сохранить мышью было нечем. preventDefault
              // не даёт input потерять фокус при mousedown по кнопке — blur не возникает,
              // click гарантированно доходит до commit().
              onMouseDown={(e) => e.preventDefault()}
              onClick={() => void commit()}
            >
              {saving ? 'Сохраняю…' : 'Сохранить'}
            </button>
            <button
              type="button"
              className="mpkc-stub-act"
              disabled={saving}
              data-testid="mpkc-req-cancel"
              onMouseDown={(e) => e.preventDefault()}
              onClick={cancel}
            >
              Отмена
            </button>
          </div>
          {/* Подсказка критического поля (§4.1.1, L810) — дословно, только для трёх
              полей допуска (legal_name/address_text/bin_iin передают `hint`). */}
          {hint && <div className="mpkc-req-hint">{hint}</div>}
          {error && <div className="mpkc-req-error">{error}</div>}
        </div>
      ) : (
        // Строка чтения (§4.1.1 «Структура карточки», прототип L814-822): значение ·
        // Badge «На проверке» · карандаш — в ОДНОЙ строке правой ячейки, Badge ПОСЛЕ
        // значения (прототип L816: `041240004987 · На проверке`), а не после подписи.
        <div className="mpkc-req-row-value-inline">
          {canEdit ? (
            <button type="button" className="mpkc-req-value" onClick={startEdit} disabled={!!pending}>
              {displayValue || '—'}
            </button>
          ) : (
            <span className="mpkc-req-value readonly">{displayValue || '—'}</span>
          )}
          {pending && <span className="mpkc-badge amber">На проверке</span>}
          {/* Круг правок C — карандаш у значения (прототип: бледная иконка-подсказка «по
              значению можно кликнуть», opacity ~0.4). Только когда правка доступна — легенда
              обещает «клик по значению — правка» именно здесь. Раньше сидел внутри кнопки
              (marginLeft/verticalAlign вручную) — теперь сосед по flex-строке, отступ даёт
              `gap:8px` контейнера, ручное позиционирование убрано как избыточное. */}
          {canEdit && <PhIcon name="pencil" size={15} color="var(--fg3)" style={{ opacity: 0.4 }} />}
        </div>
        )}
      </div>
    </div>
  )
}

// Строка без правки вообще — «Руководитель» (карточка 1) и все три строки карточки
// «Площадка приёмки»: круг правок A убрал их писатели (rpc_update_mpk_org_details /
// rpc_save_mpk_primary_site) как источник дефектов, поэтому здесь нет ни `canEdit`-ветки,
// ни мёртвого `onSave` — HS-4 запрещает держать колбэк, который никогда не вызывается.
// Визуально — тот же `.readonly`, что и у EditableRow без права, так что глаз не видит
// разницы между «сейчас нет права» и «здесь править нельзя вообще».
// `note` (круг правок C, FR-008): причина read-only, привязанная к ЭТОЙ строке, а не к
// карточке целиком — используется только «Руководителем» (единственная строка карточки 1,
// у которой причина read-only — «не заведено», а не отсутствие права). Строки «Площадки
// приёмки» этот проп не передают: там причина верна на уровне карточки (см. правку ниже).
function StaticRow({ label, value, crit, pub, note }: { label: string; value: string; crit?: boolean; pub?: boolean; note?: string }) {
  return (
    <div className="mpkc-req-row">
      <div className="mpkc-req-row-head">
        <span className="mpkc-req-label">{label}</span>
        <RowMarkers crit={crit} pub={pub} />
      </div>
      {/* Правая ячейка сетки — тот же `.mpkc-req-row-value`, что и у EditableRow, чтобы
          двухколоночная сетка `.mpkc-req-row` (§4.1.1) видела ровно два grid-элемента. */}
      <div className="mpkc-req-row-value">
        <span className="mpkc-req-value readonly">{value || '—'}</span>
        {note && <div className="mpkc-req-hint">{note}</div>}
      </div>
    </div>
  )
}

// ── Карточка 3 «Банковские реквизиты» — только показ (круг правок A убрал форму:
// rpc_append_org_bank_account без `p_is_primary` достижимо создаёт вторую живую лестницу
// счетов, а `p_previous_account_id` уходил `null` на устаревшем payload — обе находки
// ревью). KEEP-2: (а) счётчик не называет историю «закрытых» версий — history_total
// считает ВСЕ строки кроме current, а живые лестницы, не ставшие current, проходят мимо
// среза (BANK-MULTI-LIVE-ACCOUNT-01); (б) подпись истории не рисуется, если ни одна строка
// не пришла; (в) история не вложена в ветку `current` — своя проверка.
function BankBlock({ bank }: { bank: OrgProfilePayload['bank'] }) {
  // FR-004/M-003: доступ закрыт — блок ПОКАЗАН с честным пояснением, а не скрыт
  // (тот же принцип, что M-019). §6.1: текст дословно из спеки. Своя, более точная фраза —
  // не общий NO_EDIT_RIGHT_NOTE (тот про «нет права ПРАВИТЬ», этот про «нет права ЧИТАТЬ»).
  if (bank.access === 'denied') {
    return (
      <div className="mpkc-req-card-body">
        <div className="mpkc-req-note">Реквизиты доступны бухгалтеру и администратору.</div>
      </div>
    )
  }

  return (
    <div className="mpkc-req-card-body">
      {!bank.current && (
        <div className="mpkc-req-empty">Банковские реквизиты ещё не добавлены.</div>
      )}
      {bank.current && (
        <>
          <div className="mpkc-req-row">
            <span className="mpkc-req-label">Банк</span>
            <span className="mpkc-req-static">{bank.current.bank_name}</span>
          </div>
          <div className="mpkc-req-row">
            <span className="mpkc-req-label">ИИК</span>
            <span className="mpkc-req-static mono">{bank.current.iban}</span>
          </div>
          <div className="mpkc-req-row">
            <span className="mpkc-req-label">БИК</span>
            <span className="mpkc-req-static mono">{bank.current.bik}</span>
          </div>
        </>
      )}
      {/* Чтение разрешено (мы в ветке access==='granted'), а правка банка убрана из этого
          экрана кругом правок A — то есть причина НЕ в правах, и текст про права здесь врал бы. */}
      <div className="mpkc-req-note">{READ_ONLY_NOT_BUILT_NOTE}</div>
      {/* KEEP-2а/б: не «закрытых» — history_total включает и живые лестницы, не ставшие
          current; подпись рисуется только когда реально есть что показать. */}
      {bank.history.length > 0 && (
        <div className="mpkc-req-history">
          <div className="mpkc-req-history-cap">
            История версий: показано {bank.history.length} из {bank.history_total}
          </div>
          <ul className="mpkc-req-history-list">
            {bank.history.map((h) => (
              <li key={h.account_id}>
                <span className="mono">{h.bank_name} · {h.iban}</span>
                <span className="mpkc-req-history-meta">
                  {h.valid_to ? `до ${formatDate(h.valid_to)}` : 'действующий'}
                </span>
              </li>
            ))}
          </ul>
        </div>
      )}
    </div>
  )
}

// ── Пятый блок — публичное описание (mpk_profiles). В прототипе §4.1.1 нет отдельного
// pr_card под это поле (`описание/логотип` — реквизит §9 карты данных, не один из четырёх
// pr_cards); логотип (mpk_profiles.logo_path) не редактируется здесь — загрузки файла в
// скоупе нет (HS-4). M-018 «профиль ещё не заполнен» проверяется именно этим блоком:
// `profile === null` → пустое состояние + поле доступно на ввод.
// KEEP-3: Save закрыт по `saving` И по непустоте черновика — иначе клик по пустому полю
// создаёт строку mpk_profiles с NULL и пустое состояние M-018 исчезает необратимо.
function PublicDescriptionCard({
  profile, canEdit, onSave,
}: {
  profile: OrgProfileMpkProfile | null
  canEdit: boolean
  onSave: (text: string) => Promise<SaveResult>
}) {
  const [draft, setDraft] = useState(profile?.public_description ?? '')
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => { setDraft(profile?.public_description ?? '') }, [profile?.public_description])

  const dirty = draft.trim() !== (profile?.public_description ?? '')

  const commit = async () => {
    if (saving || draft.trim() === '') return
    setSaving(true)
    setError(null)
    const res = await onSave(draft.trim())
    setSaving(false)
    if (!res.ok) setError(res.message)
  }

  return (
    <section className="mpkc-req-card">
      <div className="mpkc-req-card-head">
        <h3 className="mpkc-req-card-title">О предприятии</h3>
      </div>
      <div className="mpkc-req-card-body">
        {/* §4.1.2 канон (дословно) — приглашающая половина фразы часть M-018, её отсутствие
            держало M-018 выполненным наполовину (круг правок C). */}
        {/* §4.1.2: обещание «его увидят фермеры» убрано 08.09 — фермерской выдачи описания
            НЕ существует (карточка фермера решена закрытым списком из пяти строк, ARS-666),
            единственные потребители `public_description` — писатель, читатель и этот экран.
            Подпись обещала аудиторию, которой нет, — это FR-008. */}
        {!profile && <div className="mpkc-req-empty">Профиль предприятия ещё не заполнен. Заполните описание предприятия.</div>}
        <textarea
          className="mpkc-req-textarea"
          value={draft}
          maxLength={4000}
          disabled={!canEdit || saving}
          onChange={(e) => setDraft(e.target.value)}
        />
        {error && <div className="mpkc-req-error">{error}</div>}
        {canEdit ? (
          // KEEP-3: непустота черновика — обязательное условие, наравне с `saving`.
          <button
            type="button"
            className="mpkc-stub-act"
            disabled={saving || draft.trim() === '' || !dirty}
            onClick={() => void commit()}
          >
            Сохранить
          </button>
        ) : (
          // B.1/FR-016: раньше здесь стояла собственная фраза, не §4.1.2-канон — теперь
          // тот же текст, что и у остальных трёх карточек (единый источник).
          <div className="mpkc-req-note">{NO_EDIT_RIGHT_NOTE}</div>
        )}
      </div>
    </section>
  )
}

export function OrgSection({ organizationId }: { organizationId: string | null }) {
  const navigate = useNavigate()
  const [status, setStatus] = useState<'loading' | 'error' | 'ready'>('loading')
  const [payload, setPayload] = useState<OrgProfilePayload | null>(null)
  const [failure, setFailure] = useState<LoadFailure | null>(null)
  const [reloadToken, setReloadToken] = useState(0)

  const load = useCallback(async (orgId: string) => {
    setStatus('loading')
    const result = await loadOrgProfile(orgId)
    if ('failure' in result) {
      setFailure(result.failure)
      setStatus('error')
    } else {
      setPayload(result.payload)
      setStatus('ready')
    }
  }, [])

  useEffect(() => {
    if (!organizationId) return
    void load(organizationId)
    // reloadToken намеренно в зависимостях — только он двигает повторный запрос.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [organizationId, reloadToken])

  // Организация ещё не разрешена (профиль не загружен/аноним) — RPC не дёргаем вовсе:
  // p_organization_id=null дал бы FORBIDDEN, но честнее не делать сетевой вызов, зная
  // локально, что вызывать не для кого.
  if (!organizationId) {
    return (
      <div className="mpkc-stub">
        <div className="mpkc-stub-title">Организация не определена.</div>
      </div>
    )
  }

  if (status === 'loading') return <ConsoleSkeleton />

  if (status === 'error' && failure) {
    // KEEP-6: AUTH_REQUIRED и FORBIDDEN при чтении — терминальные отказы. «Повторить»
    // повторит тот же отказ: для первого нужен путь входа, для второго — объяснение без retry.
    if (failure.kind === 'rpc' && failure.code === 'AUTH_REQUIRED') {
      return (
        <div className="mpkc-stub">
          <PhIcon name="lock" size={40} />
          <div className="mpkc-stub-title">Нужно войти, чтобы увидеть данные предприятия</div>
          <button type="button" className="mpkc-stub-act" onClick={() => navigate('/login')}>Войти</button>
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
        <div className="mpkc-stub-title">{readErrorText(failure)}</div>
        <button type="button" className="mpkc-stub-act" onClick={() => setReloadToken((n) => n + 1)}>Повторить</button>
      </div>
    )
  }

  if (!payload || !payload.organization) {
    // Не должно быть достижимо (SQL всегда либо кидает исключение, либо отдаёт organization) —
    // защитный честный фолбэк, а не белый экран (FR-008).
    return (
      <div className="mpkc-stub">
        <div className="mpkc-stub-title">Данные предприятия не пришли.</div>
        <button type="button" className="mpkc-stub-act" onClick={() => setReloadToken((n) => n + 1)}>Повторить</button>
      </div>
    )
  }

  const { organization, profile, primary_site, bank, field_reviews, permissions } = payload
  const canEdit = permissions['mpk.profile.edit']
  // KEEP-1: различитель «применено / ждёт одобрения» — ИМЕННО field_name (наличие
  // pending-записи по имени поля), а НЕ сравнение значений. legal_name/address_text
  // применяются сразу (production_value_applied_at всегда заполнен), bin_iin — нет:
  // сравнение значений спутало бы «применено» с «совпало случайно».
  const pendingByField = new Map(field_reviews.pending.map((r) => [r.field_name, r]))

  // B.3: отказ промиса supabase.rpc (офлайн, CORS — сеть рвётся ДО ответа сервера, error
  // в деструктуризации не появляется, сам await бросает) раньше не перехватывался ни в
  // одном save*-хелпере. `commit()` вызывающих компонентов делает `setSaving(false)` СРАЗУ
  // ПОСЛЕ `await onSave(...)` — если onSave бросает, этот вызов не выполняется, и строка
  // остаётся в состоянии «сохраняю» бессрочно, без единой подсказки об ошибке. Обёртка
  // здесь гарантирует, что save*-хелперы возвращают SaveResult всегда, никогда не бросают.
  const saveCriticalField = async (fieldName: CriticalFieldName, value: string): Promise<SaveResult> => {
    try {
      const { error } = await supabase.rpc('rpc_propose_org_field_change', {
        p_organization_id: organizationId,
        p_field_name: fieldName,
        p_proposed_value: value,
      })
      if (error) {
        console.error('OrgSection: rpc_propose_org_field_change error:', error)
        return { ok: false, message: writeErrorText(parseRpcCode(error.message)) }
      }
      await load(organizationId)
      return { ok: true }
    } catch (e) {
      console.error('OrgSection: rpc_propose_org_field_change threw:', e)
      return { ok: false, message: WRITE_FALLBACK }
    }
  }

  const savePublicDescription = async (text: string): Promise<SaveResult> => {
    try {
      const { error } = await supabase.rpc('rpc_upsert_mpk_profile', {
        p_organization_id: organizationId,
        p_public_description: text,
        p_logo_path: profile?.logo_path ?? null,
      })
      if (error) {
        console.error('OrgSection: rpc_upsert_mpk_profile error:', error)
        return { ok: false, message: writeErrorText(parseRpcCode(error.message)) }
      }
      await load(organizationId)
      return { ok: true }
    } catch (e) {
      console.error('OrgSection: rpc_upsert_mpk_profile threw:', e)
      return { ok: false, message: WRITE_FALLBACK }
    }
  }

  const pendingLabels = field_reviews.pending.map((r) => PEND_FIELD_LABEL[r.field_name])
  const critHint = 'Поле в допуске: после сохранения уйдёт на повторную проверку TURAN. Закупки не блокируются.'

  return (
    <div className="mpkc-req">
      {/* Баннер pr_pend (§4.1.1, L766-772) — рисуется только когда есть что показать.
          ПОРЯДОК ВАЖЕН: баннер ВЫШЕ легенды. В прототипе он L766-772, легенда L773-783 —
          найдено владельцем на экране 08.09, до этого §4.1.1 место легенды не фиксировала. */}
      {pendingLabels.length > 0 && (
        <div className="mpkc-req-pend">
          {/* §4.1.1: clock, --amber, размер на 2px больше макета по решению владельца. */}
          <PhIcon name="clock" size={18} color="var(--amber)" />
          <div className="mpkc-req-pend-txt">
            <div className="mpkc-req-pend-title">Изменения на повторной проверке TURAN</div>
            <div className="mpkc-req-pend-body">
              На проверке: {pendingLabels.join(', ')} · 2–5 рабочих дней. Закупки, заявки и приёмка работают как обычно.
            </div>
          </div>
        </div>
      )}

      {/* Легенда (§4.1.1, L773-783) — три пункта дословно, ПОД баннером.
          Иконки — часть контракта, а не украшение: те же shield/eye стоят маркерами у строк,
          и без них легенда не объясняет, что означают маркеры. Третий пункт уезжает в правый
          угол (`margin-left:auto` в прототипе L780) — класс `.last` ниже. */}
      <ul className="mpkc-req-legend">
        <li><PhIcon name="shieldCheck" size={15} color="var(--amber)" />входит в допуск</li>
        <li><PhIcon name="eye" size={15} color="var(--fg3)" />видно фермеру</li>
        <li className="last"><PhIcon name="pencil" size={15} color="var(--fg3)" />клик по значению — правка</li>
      </ul>

      <section className="mpkc-req-card">
        <div className="mpkc-req-card-head">
          {/* Заголовок карточки несёт иконку прототипа (§4.1.1 pr_cards, L1983: icon:"building"),
              15/var(--fg3) как в L787 — ARS-624, точечный круг. */}
          <PhIcon name="building" size={17} color="var(--fg3)" />
          <h3 className="mpkc-req-card-title">Предприятие</h3>
          {/* Распорка (§4.1.1 «Структура карточки», прототип L788) — уносит meta вправо. */}
          <div className="mpkc-req-card-spacer" />
          <span className="mpkc-req-card-meta">входит в допуск</span>
        </div>
        <div className="mpkc-req-card-body">
          {/* Маркеры — источник fRow() в прототипе (см. RowMarkers выше): Наименование и
              БИН несут оба (входят в допуск, видны фермеру), Юр. адрес — только допуск,
              Руководитель — ни одного. */}
          <EditableRow
            label="Наименование"
            value={organization.legal_name ?? ''}
            displayValue={organization.legal_name ?? ''}
            canEdit={canEdit}
            pending={pendingByField.has('legal_name')}
            maxLength={500}
            hint={critHint}
            crit
            pub
            onSave={(v) => saveCriticalField('legal_name', v)}
          />
          <EditableRow
            label="БИН"
            value={organization.bin_iin ?? ''}
            displayValue={organization.bin_iin ?? ''}
            canEdit={canEdit}
            pending={pendingByField.has('bin_iin')}
            // KEEP-8: чистка нецифр в onChange — писатель сам делает regexp_replace,
            // без фильтра вставка с пробелами обрежется по maxLength до невалидного значения.
            filter={(raw) => raw.replace(/\D+/g, '').slice(0, 12)}
            hint={critHint}
            crit
            pub
            onSave={(v) => saveCriticalField('bin_iin', v)}
          />
          <EditableRow
            label="Юридический адрес"
            value={organization.address_text ?? ''}
            displayValue={organization.address_text ?? ''}
            canEdit={canEdit}
            pending={pendingByField.has('address_text')}
            maxLength={1000}
            hint={critHint}
            crit
            onSave={(v) => saveCriticalField('address_text', v)}
          />
          {/* Круг правок A: «Руководитель» больше не пишется отсюда (rpc_update_mpk_org_details
              перезаписывал ВСЕ параметры RPC разом — риск затереть телефон/e-mail/сайт).
              Круг правок C / FR-008: причина «правка не заведена» относится к ЭТОЙ строке,
              а не к карточке — «Наименование»/«БИН»/«Юр. адрес» выше кликабельны при
              canEdit===true, и подпись на подвале карточки утверждала бы о них ложь. Текст
              передан через `note`, рисуется под значением строки, а не в подвале. */}
          <StaticRow label="Руководитель" value={organization.head_full_name ?? ''} note={READ_ONLY_NOT_BUILT_NOTE} />
          {/* Единственная причина read-only КАРТОЧКИ целиком — отсутствие права (FR-016);
              «правка не заведена» больше не печатается вторым текстом того же уровня. */}
          {!canEdit && <div className="mpkc-req-note">{NO_EDIT_RIGHT_NOTE}</div>}
        </div>
      </section>

      <section className="mpkc-req-card">
        <div className="mpkc-req-card-head">
          {/* §4.1.1 pr_cards, L1984: icon:"mapPin" — как у «Предприятие» выше. */}
          <PhIcon name="mapPin" size={17} color="var(--fg3)" />
          <h3 className="mpkc-req-card-title">Площадка приёмки</h3>
          <div className="mpkc-req-card-spacer" />
          <span className="mpkc-req-card-meta">одна площадка</span>
        </div>
        <div className="mpkc-req-card-body">
          {/* «Часы приёмки» умышленно пропущены — единственное отступление от прототипа
              (§4.1.1, отменено решением Аршидина 08.09.2026). Круг правок A: три строки
              ниже больше не пишутся отсюда (rpc_save_mpk_primary_site — площадку нельзя
              создать из пустого состояния ни в каком порядке правок, найдено ревью). */}
          {!primary_site && <div className="mpkc-req-empty">Площадка приёмки ещё не заполнена.</div>}
          <StaticRow label="Адрес" value={primary_site?.address_text ?? ''} pub />
          <StaticRow
            label="Мощность приёмки"
            value={primary_site ? `${primary_site.processing_capacity_heads_per_day} гол/сут` : ''}
          />
          <StaticRow label="Телефон площадки" value={primary_site?.phone ?? ''} pub />
          {/* Площадка целиком выведена из правки кругом A — причина не в правах. */}
          <div className="mpkc-req-note">{READ_ONLY_NOT_BUILT_NOTE}</div>
        </div>
      </section>

      <section className="mpkc-req-card">
        <div className="mpkc-req-card-head">
          {/* §4.1.1 pr_cards, L1985: icon:"briefcase" — как у «Предприятие» выше. */}
          <PhIcon name="briefcase" size={17} color="var(--fg3)" />
          <h3 className="mpkc-req-card-title">Банковские реквизиты</h3>
          <div className="mpkc-req-card-spacer" />
          <span className="mpkc-req-card-meta">идут в документ сделки</span>
        </div>
        <BankBlock bank={bank} />
      </section>

      {/* B.2 / частичное закрытие FR-017: field_reviews.resolved_recent читался и нигде не
          выводился — построено по образцу истории банка (та же форма «показано N из M»,
          подпись не рисуется на пустом списке). §4.1.2 «История правок». */}
      {field_reviews.resolved_recent.length > 0 && (
        <section className="mpkc-req-card">
          <div className="mpkc-req-card-head">
            <h3 className="mpkc-req-card-title">История правок</h3>
          </div>
          <div className="mpkc-req-card-body">
            <div className="mpkc-req-history">
              <div className="mpkc-req-history-cap">
                История правок: показано {field_reviews.resolved_recent.length} из {field_reviews.resolved_total}
              </div>
              <ul className="mpkc-req-history-list">
                {field_reviews.resolved_recent.map((r) => {
                  // Implementation Notes KEEP-1: `rejected` по legal_name/address_text не
                  // означает «ничего не изменилось» — прод-значение применяется СРАЗУ при
                  // отправке, решение TURAN его не откатывает. production_value_applied_at
                  // читается, а не игнорируется — ровно то, о чём предупреждал KEEP.
                  const staleNote = r.status === 'rejected' && r.production_value_applied_at
                    ? ' (значение уже применено)'
                    : ''
                  return (
                    <li key={r.id}>
                      <span>
                        {RESOLVED_FIELD_LABEL[r.field_name]}: {r.previous_value} → {r.proposed_value}
                      </span>
                      <span className="mpkc-req-history-meta">
                        {(r.status === 'approved' ? 'одобрено' : 'отклонено') + staleNote}
                        {' · '}
                        {formatDate(r.reviewed_at ?? r.requested_at)}
                      </span>
                    </li>
                  )
                })}
              </ul>
            </div>
          </div>
        </section>
      )}

      {/* M-018 закрывается здесь: `profile === null` → пустое состояние + поле на ввод. */}
      <PublicDescriptionCard profile={profile} canEdit={canEdit} onSave={savePublicDescription} />
    </div>
  )
}
