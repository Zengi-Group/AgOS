// AgOS · Slice10 MP-3.1 · SCR-P0 — роутер-тесты консоли профиля МПК.
// Критерии приёмки G3: 1 (шесть deep-link'ов + replace на overview), 2 (история),
// 3 (тема не протекает в /cabinet), 11 (иконки только Phosphor).
// Строки матрицы: M-001, M-002, M-003, M-004, M-015.
//
// Браузерный проект обязателен по той же причине, что и router-smoke: под /mpk живёт
// v5-остров Ionic (agos:ionic-v5-island), который node-окружение не воспроизводит.
// Запуск: npm run test:routers.

import { afterEach, beforeEach, expect, it, vi } from 'vitest'
import { page } from 'vitest/browser'
import { createRoot, type Root } from 'react-dom/client'
import App from '@/App'
import { MPK_PROFILE_TABS } from '@/pages/cabinet/shell/mpk/types'

// Тот же единственный мок, что в router-smoke: сетевая граница. Роутинг-стек настоящий.
// rpc-ошибка уводит loadAccountProfile в null — консоль обязана подняться и на этом
// (профиль не заполнен ≠ экран сломан).
vi.mock('@/lib/supabase', () => {
  const user = { id: 'mpk-profile-user', user_metadata: {}, phone: '' }
  const session = { access_token: 'smoke', refresh_token: 'smoke', token_type: 'bearer', expires_in: 3600, user }
  const noBackend = { message: 'mpk-profile-router: backend отключён' }
  const chain = (): unknown => {
    const q = Promise.resolve({ data: null, error: noBackend }) as Promise<unknown> & Record<string, unknown>
    for (const m of ['select', 'eq', 'order', 'limit', 'single', 'maybeSingle']) q[m] = () => q
    return q
  }
  return {
    supabase: {
      auth: {
        getSession: async () => ({ data: { session }, error: null }),
        getUser: async () => ({ data: { user }, error: null }),
        setSession: async () => ({ data: { session, user }, error: null }),
        signOut: async () => ({ error: null }),
        signInWithPassword: async () => ({ data: null, error: noBackend }),
        onAuthStateChange: () => ({ data: { subscription: { unsubscribe: () => {} } } }),
      },
      // Задержка нужна тесту M-015: без неё загрузка успевает завершиться до первого
      // опроса DOM, и скелет — состояние, ради которого строка матрицы написана —
      // нечем было бы наблюдать.
      rpc: async () => {
        await new Promise((r) => setTimeout(r, 120))
        return { data: null, error: noBackend }
      },
      from: () => chain(),
      channel: () => {
        const ch: Record<string, () => unknown> = {}
        for (const m of ['on', 'subscribe', 'unsubscribe']) ch[m] = () => ch
        return ch
      },
      removeChannel: async () => 'ok',
    },
  }
})

const initialUrl = window.location.pathname + window.location.search

let root: Root | null = null
let mountEl: HTMLElement | null = null

function mountAppAt(path: string) {
  window.history.replaceState(null, '', path)
  mountEl = document.createElement('div')
  document.body.appendChild(mountEl)
  root = createRoot(mountEl)
  root.render(<App />)
}

function unmount() {
  root?.unmount()
  root = null
  mountEl?.remove()
  mountEl = null
}

// Консоль поддерживается при ≥1024px (FR-012), а по умолчанию раннер этого проекта стоит
// на мобильной ширине (414px) — он собран под оболочки телефона. Ставим эталон приёмки
// консоли: 1440×900 (§0.2). Проверка ниже — страховка: если вьюпорт не применился, тесты
// упадут громко, а не начнут молча проверять узкую заставку вместо консоли.
beforeEach(async () => {
  await page.viewport(1440, 900)
  expect(window.innerWidth, 'ширина раннера < 1024px — консоль подменяется заставкой').toBeGreaterThanOrEqual(1024)
})

afterEach(() => {
  unmount()
  window.localStorage.clear()
  window.history.replaceState(null, '', initialUrl)
})

const T = { timeout: 15_000 }

const activeTabLabel = () =>
  document.querySelector('.agos-mpk-console [role="tab"][aria-selected="true"]')?.textContent?.trim() ?? null

const TAB_LABEL: Record<string, string> = {
  overview: 'Обзор', org: 'Предприятие', adm: 'Допуск',
  team: 'Команда', rep: 'Репутация', appeals: 'Обращения',
}

// M-001 · вход в консоль по прямой ссылке: cold-open любого из 6 табов открывает
// именно запрошенный раздел, а не overview.
it('M-001: шесть cold deep-link’ов открывают запрошенный подраздел', async () => {
  for (const tab of MPK_PROFILE_TABS) {
    mountAppAt(`/mpk/profile/${tab}`)
    await expect.poll(() => activeTabLabel(), T).toBe(TAB_LABEL[tab])
    expect(window.location.pathname).toBe(`/mpk/profile/${tab}`)
    unmount()
  }
})

// M-002 · неизвестный или отсутствующий таб → Redirect replace на overview.
// `replace`, а не `push`: назад из консоли должно вести на предыдущую страницу,
// а не обратно на битый URL.
it('M-002: неизвестный таб → replace на overview, битый URL не остаётся в истории', async () => {
  window.history.replaceState(null, '', '/mpk')
  window.history.pushState(null, '', '/mpk/profile/xyz')
  mountEl = document.createElement('div')
  document.body.appendChild(mountEl)
  root = createRoot(mountEl)
  root.render(<App />)

  await expect.poll(() => window.location.pathname, T).toBe('/mpk/profile/overview')
  await expect.poll(() => activeTabLabel(), T).toBe('Обзор')

  window.history.back()
  await expect.poll(() => window.location.pathname, T).toBe('/mpk')
})

it('M-002: /mpk/profile без сегмента таба → replace на overview', async () => {
  mountAppAt('/mpk/profile')
  await expect.poll(() => window.location.pathname, T).toBe('/mpk/profile/overview')
  await expect.poll(() => activeTabLabel(), T).toBe('Обзор')
})

// M-003 · навигация браузера: переход по табам кладёт записи в историю, back/forward
// возвращают экран, соответствующий URL; выход возвращает в мобильную оболочку МПК.
it('M-003: back/forward по табам и возврат на /mpk', async () => {
  mountAppAt('/mpk/profile/overview')
  await expect.poll(() => activeTabLabel(), T).toBe('Обзор')

  await page.getByRole('tab', { name: 'Команда' }).click()
  await expect.poll(() => window.location.pathname, T).toBe('/mpk/profile/team')
  await expect.poll(() => activeTabLabel(), T).toBe('Команда')

  window.history.back()
  await expect.poll(() => window.location.pathname, T).toBe('/mpk/profile/overview')
  await expect.poll(() => activeTabLabel(), T).toBe('Обзор')

  window.history.forward()
  await expect.poll(() => window.location.pathname, T).toBe('/mpk/profile/team')
  await expect.poll(() => activeTabLabel(), T).toBe('Команда')

  await page.getByRole('button', { name: /Вернуться в закупки/ }).click()
  await expect.poll(() => window.location.pathname, T).toBe('/mpk')
  // Поднялась именно мобильная оболочка закупок — консоль ушла (HS-2 / FR-005).
  await expect.poll(() => document.querySelector('.agos-mpk-console'), T).toBeNull()
  await expect.element(page.getByText('Статус типа МПК ещё не подтверждён'), T).toBeInTheDocument()
})

// M-015 · первый рендер раздела: скелет, без белого провала. Проверяем ИМЕННО скелет:
// сайдбар и табы рендерятся вне тела и присутствуют независимо от загрузки, поэтому
// утверждение о них пропустило бы регрессию `if (loading) return null`.
it('M-015: до загрузки профиля в теле раздела показан скелет', async () => {
  mountAppAt('/mpk/profile/overview')
  await expect.poll(() => document.querySelector('.agos-mpk-console .mpkc-skel'), T).not.toBeNull()
  // Оболочка при этом уже на месте — данные грузятся под ней, а не вместо неё.
  expect(document.querySelector('.agos-mpk-console .mpkc-side')).not.toBeNull()
  expect(document.querySelector('.agos-mpk-console .mpkc-tabs')).not.toBeNull()
  // И скелет — не навсегда: после загрузки тело раздела не остаётся пустым.
  await expect.poll(() => document.querySelector('.agos-mpk-console .mpkc-stub'), T).not.toBeNull()
})

// M-003 · подсказка «Раздел в разработке» принадлежит пункту сайдбара и НЕ подменяет экран:
// URL, активная вкладка и содержимое остаются прежними. Регрессия здесь — ровно тот случай,
// когда экран перестаёт соответствовать URL.
it('M-003: клик по непостроенному пункту сайдбара не меняет ни URL, ни вкладку', async () => {
  mountAppAt('/mpk/profile/team')
  await expect.poll(() => activeTabLabel(), T).toBe('Команда')
  // Дожидаемся конца загрузки: до неё в теле скелет, и сравнивать «до/после» нечего.
  await expect.poll(() => document.querySelector('.agos-mpk-console .mpkc-stub'), T).not.toBeNull()

  await page.getByRole('button', { name: 'Мои заявки' }).click()
  await expect.poll(() => document.querySelector('.agos-mpk-console .mpkc-soon')?.textContent?.trim(), T)
    .toBe('Раздел в разработке')
  // Экран не уехал: URL, подсветка вкладки и тело раздела те же.
  expect(window.location.pathname).toBe('/mpk/profile/team')
  expect(activeTabLabel()).toBe('Команда')
  expect(document.querySelector('.agos-mpk-console .mpkc-stub')).not.toBeNull()

  // Возврат на «Профиль МПК» снимает подсказку.
  await page.getByRole('button', { name: 'Профиль МПК' }).click()
  await expect.poll(() => document.querySelector('.agos-mpk-console .mpkc-soon'), T).toBeNull()
  expect(window.location.pathname).toBe('/mpk/profile/team')
})

// M-003 · клик по уже активной вкладке не плодит записи истории.
it('M-003: повторный клик по активной вкладке не добавляет запись в историю', async () => {
  window.history.replaceState(null, '', '/mpk')
  window.history.pushState(null, '', '/mpk/profile/org')
  mountEl = document.createElement('div')
  document.body.appendChild(mountEl)
  root = createRoot(mountEl)
  root.render(<App />)
  await expect.poll(() => activeTabLabel(), T).toBe('Предприятие')

  await page.getByRole('tab', { name: 'Предприятие' }).click()
  await page.getByRole('tab', { name: 'Предприятие' }).click()
  expect(window.location.pathname).toBe('/mpk/profile/org')

  // Один back должен вывести из консоли, а не «залипнуть» на той же вкладке.
  window.history.back()
  await expect.poll(() => window.location.pathname, T).toBe('/mpk')
})

// M-012 · узкий экран: застава вместо консоли, deep-link запрошенного раздела сохранён
// (D-MPK-NARROW-06), мутаций нет.
it('M-012: ниже 1024px рендерится застава, deep-link таба сохранён', async () => {
  await page.viewport(414, 896)
  mountAppAt('/mpk/profile/team')

  await expect.poll(() => document.querySelector('.agos-mpk-console .mpkc-narrow'), T).not.toBeNull()
  // Сжатого 272px-канваса нет.
  expect(document.querySelector('.agos-mpk-console .mpkc-side')).toBeNull()
  expect(document.querySelector('.agos-mpk-console .mpkc-tabs')).toBeNull()
  // Запрошенный раздел не переписан на overview — ни в URL, ни в тексте заставки.
  expect(window.location.pathname).toBe('/mpk/profile/team')
  expect(document.querySelector('.mpkc-narrow')?.textContent).toContain('Команда')
  expect(document.querySelector('.mpkc-narrow-link')?.textContent).toBe('/mpk/profile/team')
})

// M-004 · изоляция темы (FR-006, критерий 3). Токены консоли обязаны жить на её
// контейнере, а не на :root — иначе тёмная палитра и увеличенная тип-шкала протекут
// в фермерский кабинет и нарушат D-UI-FARMER-RULES-01.
it('M-004: токены консоли не сидят на :root', async () => {
  mountAppAt('/mpk/profile/overview')
  await expect.poll(() => document.querySelector('.agos-mpk-console'), T).not.toBeNull()

  const rootBg = getComputedStyle(document.documentElement).getPropertyValue('--bg').trim()
  expect(rootBg, '--bg консоли протёк на :root').toBe('')

  const el = document.querySelector('.agos-mpk-console') as HTMLElement
  expect(getComputedStyle(el).getPropertyValue('--bg').trim()).toBe('#070706')
})

it('M-004: после консоли /cabinet остаётся светлым и с прежними размерами шрифта', async () => {
  // Открываем консоль — её CSS попадает в документ и остаётся там (Vite инжектит стили
  // модуля один раз). Именно этот сценарий и опасен для фермерской зоны.
  mountAppAt('/mpk/profile/overview')
  await expect.poll(() => document.querySelector('.agos-mpk-console'), T).not.toBeNull()
  unmount()

  mountAppAt('/cabinet')
  await expect.poll(() => document.querySelector('.agos-cabinet-stage'), T).not.toBeNull()

  const el = document.querySelector('.agos-cabinet-stage') as HTMLElement
  const cs = getComputedStyle(el)
  // daylight-палитра фермерского кабинета (cabinet.css: --bg #f6f3ed).
  expect(cs.getPropertyValue('--bg').trim()).toBe('#f6f3ed')
  expect(cs.backgroundColor).toBe('rgb(246, 243, 237)')
  // Тип-шкала прототипа МПК (--fs-base) в фермерской зоне не определена.
  expect(cs.getPropertyValue('--fs-base').trim()).toBe('')
})

// Критерий 11 · иконки только Phosphor через PhIcon; lucide в зоне не появился.
it('критерий 11: в консоли только Phosphor-иконки (viewBox 256), lucide нет', async () => {
  mountAppAt('/mpk/profile/overview')
  await expect.poll(() => document.querySelector('.agos-mpk-console .mpkc-tabs'), T).not.toBeNull()

  const svgs = Array.from(document.querySelectorAll('.agos-mpk-console svg'))
  expect(svgs.length).toBeGreaterThan(0)
  const foreign = svgs.filter((s) => s.getAttribute('viewBox') !== '0 0 256 256')
  expect(foreign.map((s) => s.getAttribute('viewBox')), 'не-Phosphor svg в консоли').toEqual([])
  expect(document.querySelectorAll('.agos-mpk-console svg.lucide').length).toBe(0)
})

// M-011 · раздел без бэкенда: честная заглушка И достижимый путь «написать в TURAN».
// Проза, называющая путь, требованию не удовлетворяет — нужен объект перехода.
it('M-011: заглушка «Обращения» честна и даёт путь в TURAN', async () => {
  mountAppAt('/mpk/profile/appeals')
  await expect.poll(() => document.querySelector('.agos-mpk-console .mpkc-stub'), T).not.toBeNull()

  expect(document.querySelector('.mpkc-stub-title')?.textContent).toBe('Раздел пока не ведётся')
  // Ни одного выдуманного числа/обращения — только честное состояние (FR-008).
  await page.getByRole('button', { name: 'Написать в TURAN' }).click()
  await expect.poll(() => window.location.pathname, T).toBe('/mpk')
})

// M-002 · лишние сегменты — такой же неканонический адрес, как неизвестный таб.
it('M-002: /mpk/profile/org/лишнее → replace на overview', async () => {
  mountAppAt('/mpk/profile/org/anything')
  await expect.poll(() => window.location.pathname, T).toBe('/mpk/profile/overview')
  await expect.poll(() => activeTabLabel(), T).toBe('Обзор')
})

// M-004 · вторая тема консоли — тоже режим, и изоляция обязана держаться в НЁМ ТОЖЕ.
// Без этого критерий 3 подписан только для палитры по умолчанию.
it('M-004: светлая тема консоли включается и тоже не течёт на :root', async () => {
  mountAppAt('/mpk/profile/overview')
  await expect.poll(() => document.querySelector('.agos-mpk-console'), T).not.toBeNull()

  const el = () => document.querySelector('.agos-mpk-console') as HTMLElement
  expect(el().getAttribute('data-theme')).toBeNull()

  document.querySelector<HTMLElement>('.agos-mpk-console .mpkc-theme')?.click()
  await expect.poll(() => el().getAttribute('data-theme'), T).toBe('light')

  // Светлый набор применился на контейнере…
  expect(getComputedStyle(el()).getPropertyValue('--bg').trim()).toBe('#f6f3ed')
  // …и по-прежнему ничего не задал на :root (та самая протечка, которую ловит FR-006).
  expect(getComputedStyle(document.documentElement).getPropertyValue('--bg').trim()).toBe('')
})
