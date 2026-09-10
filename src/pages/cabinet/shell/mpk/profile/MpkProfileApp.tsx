// AgOS · Slice10 · MP-3.1 — SCR-P0, оболочка десктопной консоли «Профиль МПК».
//
// АДДИТИВНОСТЬ (FR-004/FR-005, HS-2). Консоль — sibling-поверхность рядом с Ionic-оболочкой
// закупок, а НЕ переписывание MpkApp. Точно: `MpkApp.tsx` и его экраны/модалки/шторка
// (`/mpk`, `/mpk/tsp`, `/mpk/offers`, 8 подключённых rpc_self_*) не изменены ни строкой;
// общие модули `../nav.ts` и `../types.ts` расширены АДДИТИВНО — у роутов home/tsp/offers
// прежние URL, ключи и глубина, менялись только ветки для `profile`. Что это не задело
// шелл — держат router-smoke и router-tabstack, а не обещание в комментарии.
// Общее с ним — аутентификация, выбранная организация, типизированные клиенты данных
// (`loadAccountProfile`). Профиль-owned — лейаут, CSS-scope, навигация по табам (§1.2).
// Маршрут монтируется v6-роутером App.tsx: консоль десктопная, ей не нужен ни IonApp,
// ни телефонный каркас `.phone`, ни анимации Ionic-стека.
//
// Карта URL↔маршрут одна на обе поверхности — `../nav.ts` (P4/P6, D-MPK-NAV-01).

import { useCallback, useEffect, useState } from 'react'
import { Navigate, useLocation, useNavigate } from 'react-router-dom'
import { loadAccountProfile, type AccountProfile } from '@/lib/account'
import { mpkProfileTabFromUrl, mpkRouteToUrl } from '../nav'
import type { MpkProfileTab } from '../types'
import { ProfileSidebar } from './ProfileSidebar'
import { ProfileTabs, profileTabLabel } from './ProfileTabs'
import { ConsoleError, ConsoleSkeleton, SectionStub } from './SectionStub'
import { OrgSection, type LoadFailure } from './OrgSection'
import { OverviewSection } from './OverviewSection'
import { admissionBadgeFromVerdict, loadOverview, type OverviewPayload } from './overview-model'
import './profile-console.css'

// §1.4 / FR-012: полная консоль поддерживается при ≥1024px.
const WIDE_QUERY = '(min-width: 1024px)'

// БЕЙДЖ ШАПКИ БОЛЬШЕ НЕ ВЫВОДИТ ВЕРДИКТ САМ (§3.0 спеки, решение владельца 2026-09-09).
//
// Здесь стояли `hasMembershipAccess` и `admissionBadge` — клиентский вывод «можем ли мы
// закупать прямо сейчас» из `verification.status` + членства (MP-3.1). Они удалены, а не
// оставлены без вызова (`HS-4`): вердикт считает база и отдаёт готовым в
// `admission.status` агрегата, а вторая интерпретация статусов на клиенте — это второй дом
// одного факта (`P4`) и нарушение `FR-003` («авторизация проверяется в базе»).
//
// Что это не «упрощение UX» и не потеря функции: бейдж остался на месте и продолжает
// отвечать на тот же вопрос Intent — он берёт ту же строку из того же словаря, что и
// заголовок «Обзора» (`admissionBadgeFromVerdict` в `overview-model.ts`). Строки матрицы
// `M-013` держат его по-прежнему, но фикстуры их тестов переехали с `loadAccountProfile` на
// ответ агрегата — вместе с домом факта.
//
// Почему это понадобилось: словарь MP-3.1 переиспользовали, а вывод — нет, и при
// `verification = conditional` шапка говорила «Допуск не подтверждён» рядом с заголовком
// «Допущен с условиями». На тогдашних прод-данных расхождение было недостижимо по ДАННЫМ,
// а не по коду. Маршрут `bad_spec` на якоре 7, откат, §3.0.
//
// Мобильный шелл закупок не затронут (`FR-005`, `HS-2`): у него своя цепочка
// `MpkApp.deriveMpkMembership`, агрегата там нет, и ни одна её строка не менялась.

// Организационно-правовые формы: их буква в монограмму не идёт — иначе «ТОО Агрофирма
// Восток» даёт «ТА», где «Т» не о предприятии, а о форме собственности. Русские и
// казахские варианты вперемешку, как они и встречаются в реестре.
const LEGAL_FORMS = new Set([
  'ТОО', 'АО', 'ЗАО', 'ОАО', 'ПАО', 'ИП', 'КХ', 'КФХ', 'ПК', 'СПК', 'ТД', 'ЧП',
  'ЖШС', 'АҚ', 'ЖК', 'ШҚ',
])

// Монограмма: «МК «Семей Ет»» → «СЕ», «ТОО QA-Тест МПК» → «QМ».
// Два правила, в этом порядке:
//   1) кавычки в казахстанских наименованиях выделяют собственно имя (ТОО «X») —
//      если они есть, инициалы берутся изнутри них;
//   2) иначе отбрасываются ведущие организационно-правовые формы.
// Найдено прогоном против реальной базы 2026-09-03: сид-организация «ТОО QA-Тест МПК»
// давала монограмму «ТQ» — первая буква из формы собственности. Кавычек в реальных
// названиях может не быть, и это обычный случай, а не исключение.
function initials(source: string | null | undefined, fallback: string): string {
  if (!source) return fallback
  const quoted = source.match(/[«"]([^»"]+)[»"]/)?.[1]
  const all = (quoted ?? source).split(/\s+/).filter(Boolean)
  // Отбрасываем форму только когда после неё что-то остаётся — «ТОО» в одиночку
  // лучше показать как «ТО», чем свести монограмму к пустоте.
  const trimmed = all.filter((w) => !LEGAL_FORMS.has(w.toUpperCase().replace(/[«».,"]/g, '')))
  const words = trimmed.length > 0 ? trimmed : all
  // §2 требует монограмму из двух букв. Два слова и больше — по первой букве от двух
  // первых; одно слово — две его первые буквы, иначе «Агрофирма» схлопнулась бы в «А».
  const letters = words.length >= 2
    ? words.slice(0, 2).map((w) => w[0]).join('')
    : (words[0] ?? '').slice(0, 2)
  return (letters || fallback).toUpperCase()
}

// FR-008: показываем только то, что реально пришло. Прототипный `pr_sub` — это
// «БИН {bin} · {юр.адрес} · допуск TURAN с {дата}»; источника ни для юр. адреса, ни для
// даты допуска в текущих RPC нет, они придут со своим разделом (MP-3.3/MP-3.4).
// Район организации сюда НЕ подставляется: во второй позиции читатель ждёт юр. адрес и
// принял бы район за него — молчание честнее правдоподобной подмены.
function headerSubtitle(profile: AccountProfile | null): string {
  return profile?.bin ? `БИН ${profile.bin}` : ''
}

// Тексты заглушек — строительные леса на время нарезки MP-3: каждый раздел заменит свой
// текст собственным содержимым. Формулировка «Раздел в разработке» — FR-013.
// `mpkAction` — подпись кнопки, уводящей в мобильный кабинет МПК. Ставится там, где
// строка матрицы требует не только честного текста, но и достижимого пути.
const SECTION_STUB: Record<MpkProfileTab, { title: string; note: string; mpkAction?: string }> = {
  overview: {
    // MP-3.7 (ARS-628): текст ниже БОЛЬШЕ НЕ показывается — ветка `tab === 'overview'` в
    // body() рендерит `OverviewSection` раньше. Запись остаётся мёртвой, а не удалена, по
    // той же причине, что и `org`: `Record<MpkProfileTab, …>` требует ключ для каждого
    // таба, и порядок веток в body() однажды может измениться.
    title: 'Раздел в разработке',
    note: 'Сводка допуска и списка дел появится здесь. Пока статус допуска виден на главной мобильного кабинета МПК.',
  },
  org: {
    // B.8 (круг правок ARS-624, 08.09.2026): текст ниже НЕ показывается — ветка
    // `tab === 'org'` в body() рендерит `OrgSection` раньше, чем эта заглушка. Запись
    // остаётся мёртвой, а не удалена: `Record<MpkProfileTab, …>` требует ключ для каждого
    // таба, и порядок веток в body() однажды может измениться, снова выведя её на экран.
    // Прежний текст («изменить реквизиты можно только через обращение в TURAN») к этому
    // моменту утверждал неправду дважды: реквизиты уже редактировались напрямую, а затем
    // круг правок B убрал часть той самой правки (см. комментарий в OrgSection.tsx, раздел
    // A) — заглушка обязана быть нейтральной, а не подтверждать то, что уже другое на
    // экране. Превью карточки для фермера (§4.2) по-прежнему не построено — дом ARS-666.
    title: 'Раздел в разработке',
    note: 'Превью карточки для фермера появится здесь.',
  },
  adm: {
    title: 'Раздел в разработке',
    note: 'Верификация, членство и документы допуска появятся здесь. Пока статус допуска виден на главной мобильного кабинета МПК.',
  },
  team: {
    title: 'Раздел в разработке',
    note: 'Состав команды и приглашение сотрудников появятся здесь. Сейчас состав организации в кабинете не показан.',
  },
  rep: {
    title: 'Раздел в разработке',
    note: 'Оценки фермеров и распределение по звёздам появятся здесь. Сейчас репутация в кабинете не показана.',
  },
  appeals: {
    // FR-011: раздел не строится до закрытия ARS-357 (модель) и ARS-364 (RPC).
    // M-011 требует не только честной заглушки, но и ПУТИ «написать в TURAN» — поэтому
    // здесь кнопка, а не упоминание пути прозой: названный, но недостижимый путь — не путь.
    title: 'Раздел пока не ведётся',
    note: 'Обращения в TURAN в кабинете пока не хранятся. Написать в TURAN можно из мобильного кабинета МПК.',
    mpkAction: 'Написать в TURAN',
  },
}

export function MpkProfileApp() {
  const navigate = useNavigate()
  const location = useLocation()

  // URL — источник истины подраздела. Неизвестный/отсутствующий сегмент → null,
  // ниже это превращается в `Redirect replace` на overview (M-002, D-MPK-DESKTOP-01).
  const tab = mpkProfileTabFromUrl(location.pathname)

  const [profile, setProfile] = useState<AccountProfile | null>(null)
  const [loading, setLoading] = useState(true)
  const [failed, setFailed] = useState(false)
  const [reloadToken, setReloadToken] = useState(0)

  // §3.0: агрегат «Обзора» читается ЗДЕСЬ, на уровне оболочки, а не внутри вкладки —
  // потому что его `admission.status` нужен и бейджу шапки, и заголовку «Обзора». Один
  // вызов на монтирование консоли; `EngSpec §8` («one typed initial read per tab») этим не
  // нарушается: «Обзор» — вкладка по умолчанию, второго чтения у неё нет.
  const [overview, setOverview] = useState<OverviewPayload | null>(null)
  const [overviewStatus, setOverviewStatus] = useState<'loading' | 'error' | 'ready'>('loading')
  const [overviewFailure, setOverviewFailure] = useState<LoadFailure | null>(null)
  const [overviewToken, setOverviewToken] = useState(0)
  const [theme, setTheme] = useState<'dark' | 'light'>('dark')
  // id пункта сайдбара, по которому показана подсказка «Раздел в разработке» (FR-013).
  // Это подсказка САМОГО ПУНКТА, а не состояние экрана: контент, ptabs и URL она не
  // трогает. Иначе ломается M-003 («экран соответствует URL»): состояние без маршрута
  // не пережило бы ни browser-back, ни reload, а ptabs подсвечивал бы одно при другом
  // содержимом. Маршрутов этим разделам слайс не выдаёт — он их не строит (FR-009).
  const [soonHint, setSoonHint] = useState<string | null>(null)

  const [wide, setWide] = useState(() =>
    typeof window === 'undefined' ? true : window.matchMedia(WIDE_QUERY).matches)

  useEffect(() => {
    const mq = window.matchMedia(WIDE_QUERY)
    const onChange = () => setWide(mq.matches)
    mq.addEventListener('change', onChange)
    setWide(mq.matches)
    return () => mq.removeEventListener('change', onChange)
  }, [])

  useEffect(() => {
    let alive = true
    setLoading(true)
    setFailed(false)
    loadAccountProfile('mpk')
      .then((p) => { if (alive) { setProfile(p); setLoading(false) } })
      .catch((error) => {
        // M-014: техническая деталь — в консоль, пользователю честный текст + retry.
        console.error('MpkProfileApp: loadAccountProfile failed:', error)
        if (alive) { setFailed(true); setLoading(false) }
      })
    return () => { alive = false }
  }, [reloadToken])

  // `KEEP-21`: флаг отмены обязателен — без него второй запрос (повтор после отказа или
  // смена организации) может завершиться раньше первого, и поздний ответ перезапишет
  // свежий. Организация известна только после профиля, поэтому чтение последовательное:
  // `p_organization_id = null` дал бы FORBIDDEN, а честнее не звать вовсе.
  const orgId = profile?.orgId ?? null
  useEffect(() => {
    if (!orgId) return
    let alive = true
    setOverviewStatus('loading')
    void loadOverview(orgId).then((result) => {
      if (!alive) return
      if ('failure' in result) {
        setOverviewFailure(result.failure)
        setOverviewStatus('error')
      } else {
        setOverview(result.payload)
        setOverviewStatus('ready')
      }
    })
    return () => { alive = false }
  }, [orgId, overviewToken])

  const goTab = useCallback((next: MpkProfileTab) => {
    setSoonHint(null)
    // Клик по уже активной вкладке не кладёт запись в историю: иначе browser-back
    // «залипает» на том же экране столько раз, сколько по нему кликнули (M-003).
    if (next === tab) return
    navigate(mpkRouteToUrl({ name: 'profile', tab: next }))
  }, [navigate, tab])

  const backToMpk = useCallback(() => { navigate('/mpk') }, [navigate])

  if (!tab) return <Navigate to={mpkRouteToUrl({ name: 'profile', tab: 'overview' })} replace />

  // Пока профиль не загружен, имя организации неизвестно — подставлять сюда что-либо
  // правдоподобное нельзя (FR-008). «Предприятие» — родовая подпись поверхности, а не
  // выданное за данные значение.
  const orgLoaded = !loading && !failed && profile?.name
  const orgName = profile?.name ?? 'Предприятие'
  // §3.0 п.2: пока вердикт не пришёл, бейджа НЕТ вовсе. Нейтральной подписи-заполнителя
  // здесь тоже не появляется: любая строка в этом месте была бы утверждением о статусе,
  // которого мы ещё не знаем (`FR-008`), а вычислять его на клиенте больше нельзя.
  const badge = overviewStatus === 'ready' && overview
    ? admissionBadgeFromVerdict(overview.admission.status)
    : null

  // FR-012: ниже 1024px консоль не сжимается. Полноценный Ionic-мост со сводкой допуска —
  // отдельная задача MP-3.2 (её overview-RPC ещё в бэклоге, ARS-362); до неё здесь стоит
  // минимальная застава, которая соблюдает три обязательства «Never»: не рисует сжатый
  // 272px-канвас, ничего не мутирует и НЕ перезаписывает deep-link запрошенного раздела
  // на overview (D-MPK-NARROW-06) — URL остаётся тем, по которому пришли.
  if (!wide) {
    return (
      <div className="agos-mpk-console narrow" data-theme={theme === 'light' ? 'light' : undefined}>
        <div className="mpkc-narrow">
          {/* Заголовок — имя организации только когда оно действительно загружено;
              ошибку чтения показываем и здесь, а не молчаливой родовой подписью. */}
          <div className="mpkc-narrow-title">{orgLoaded ? orgName : 'Профиль предприятия'}</div>
          {failed && (
            <div className="mpkc-narrow-note">
              Данные предприятия не загрузились. Название и статус допуска здесь не показаны.
            </div>
          )}
          <div className="mpkc-narrow-note">
            Раздел «{profileTabLabel(tab)}» профиля предприятия открывается на экране шириной
            от 1024 пикселей. Ссылка сохранена — откройте её на компьютере.
          </div>
          <div className="mpkc-narrow-link">{location.pathname}</div>
          <button type="button" className="mpkc-stub-act" onClick={backToMpk}>Назад в МПК</button>
        </div>
      </div>
    )
  }

  const body = () => {
    if (loading) return <ConsoleSkeleton />
    if (failed) return <ConsoleError onRetry={() => setReloadToken((n) => n + 1)} />
    // ARS-624 (KEEP-11): ветка ВЫШЕ SECTION_STUB[tab] — аддитивно, ни одной строки
    // существующей заглушки не удалено; пять прочих табов продолжают отдавать SectionStub.
    if (tab === 'org') return <OrgSection organizationId={profile?.orgId ?? null} />
    // MP-3.7 (ARS-628): тем же приёмом — ветка ВЫШЕ заглушки, аддитивно. Раздел получает
    // состояние чтения, а не читает сам (§3.0): дом факта один, и он в оболочке.
    // Навигация передаётся пропсами — карта URL↔маршрут одна на обе поверхности
    // (`../nav.ts`, `P4`/`P6`). `onContactTuran` ведёт на `/mpk`, где живёт шторка
    // «Обратиться в TURAN» — тот же достижимый путь, что у заглушки `appeals`.
    if (tab === 'overview') {
      return (
        <OverviewSection
          status={overviewStatus}
          payload={overview}
          failure={overviewFailure}
          organizationId={orgId}
          onRetry={() => setOverviewToken((n) => n + 1)}
          onOpenTab={goTab}
          onContactTuran={backToMpk}
        />
      )
    }
    const stub = SECTION_STUB[tab]
    return (
      <SectionStub
        title={stub.title}
        note={stub.note}
        action={stub.mpkAction ? { label: stub.mpkAction, onClick: backToMpk } : undefined}
      />
    )
  }

  return (
    <div className="agos-mpk-console" data-theme={theme === 'light' ? 'light' : undefined}>
      <ProfileSidebar
        orgName={orgName}
        farmName="Turan Standard Pool · закупки"
        userName={profile?.ownerName ?? 'Сотрудник'}
        monogram={initials(profile?.ownerName, 'МПК')}
        theme={theme}
        soonHint={soonHint}
        onSelect={(item) => setSoonHint(item.id === 'profile' ? null : item.id)}
        onThemeToggle={() => setTheme((t) => (t === 'dark' ? 'light' : 'dark'))}
        onBackToMpk={backToMpk}
      />

      <main className="mpkc-main">
        <div className="mpkc-head">
          <div className="mpkc-head-mono" aria-hidden="true">{initials(profile?.name, 'МК')}</div>
          <div className="mpkc-head-txt">
            <div className="mpkc-head-row">
              <span className="mpkc-head-name">{orgName}</span>
              {badge && <span className={`mpkc-badge ${badge.tone}`}>{badge.label}</span>}
            </div>
            <div className="mpkc-head-sub">{headerSubtitle(profile)}</div>
          </div>
        </div>

        <ProfileTabs active={tab} onChange={goTab} />

        <div className="mpkc-body">
          <div className="mpkc-body-inner">{body()}</div>
        </div>
      </main>
    </div>
  )
}
