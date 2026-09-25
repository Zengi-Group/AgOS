// AgOS · ARS-822 · «Продать» над меню, экран результата — конец флоу («На главную»,
// «К партии»/«‹ Рынок»), ни один «назад»/«вперёд» не поднимает завершённую публикацию.
//
// Предмет — Docs/AGOS-TSP-SellFlowNav-DockAndPubExit-ARS-822.md, <frozen-after-approval>
// I/O & Edge-Case Matrix. Один `it` = одна или несколько связанных M-строк (M-id в названии).
// Модель по router-tabstack.browser.test.tsx: реальный v5-остров в chromium, сеть замокана,
// mount/poll/visible-хелперы и afterEach-очистка те же (+ sessionStorage — черновик визарда,
// useBatchDraft.ts, живёт в session-скоупе платформенного адаптера).
//
// Как дойти до публикации без backend: rpc_create_batch всегда ошибка → BatchWizard.handlePublish
// собирает партию ЛОКАЛЬНО (buildLocalBatch) и зовёт onDone → экран результата. Черновик визарда
// (WizState) сеется напрямую в sessionStorage ('agos.tsp.draft.v1', useBatchDraft.load()) на нужном
// шаге — так же, как форма пережила бы reload у реального фермера; шаги 1–4 не проходятся руками,
// кроме отдельного M-018-теста (там нужен именно живой переход между шагами мастера).
// windowPreset='now' → publishInfo(...).delayed=false → вариант НЕ 'D': локальная партия не
// заматчена (buildLocalBatch не зовёт автоматч) → вариант 'B' (пауза-поиск реально идёт, SEARCH_MS).
//
// Вход в мастер — тем же путём, что фермер: кнопка «Продать»/«Новая партия» на вкладке «Рынок»
// (MarketScreen.onNew → CabinetApp go({name:'batchwiz'})). В список заранее кладём одну
// ЗАВЕРШЁННУЮ партию (state 'delivered', вне лимита 5 активных и вне пустого состояния) —
// это даёт основной док-футер-вход «Продать» (а не подстановочную кнопку пустого списка).

import { afterEach, expect, it, vi } from 'vitest'
import { createRoot, type Root } from 'react-dom/client'
import App from '@/App'

vi.mock('@/lib/supabase', () => {
  const user = { id: 'ars822-farmer', user_metadata: {}, phone: '' }
  const session = { access_token: 't', refresh_token: 't', token_type: 'bearer', expires_in: 3600, user }
  const noBackend = { message: 'ars822: backend off' }
  const chain = (): unknown => {
    const q = Promise.resolve({ data: null, error: null }) as Promise<unknown> & Record<string, unknown>
    for (const m of ['select', 'eq', 'order', 'limit', 'single', 'maybeSingle']) q[m] = () => q
    return q
  }
  const ok = (data: unknown) => ({ data, error: null })
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
      rpc: async (name: string) => {
        switch (name) {
          case 'rpc_get_my_context':
            return ok({
              user_id: 'ars822-farmer',
              organizations: [{
                id: 'org-822', legal_name: 'КХ Тест ARS-822', bin_iin: '123456789012',
                region_id: null, phone: null, role: 'owner', is_primary: true, org_types: ['farmer'],
              }],
              // G3 (гео-проверка «Записать событие»): ферма с primary-фермой — loadFarmCtx
              // находит farm+org, зовёт rpc_get_farm_summary (кейс ниже) → hasHerd=true →
              // captureFooter рендерится (FarmScreen.tsx: !empty && organizationId && farmId).
              farms: [{ id: 'farm-822', organization_id: 'org-822', name: 'Ферма ARS-822', region_id: null, is_primary: true }],
              // level !== 'registered' → deriveMembership даёт 'active' (store.ts §2), сразу
              // открывая Рынок — независимо от subscription/verification RPC (обе ниже — noBackend).
              memberships: [{ id: 'memb-822', organization_id: 'org-822', org_type: 'farmer', level: 'observer' }],
            })
          case 'rpc_get_farm_summary':
            return ok({
              herd_groups: [{ animal_category_code: 'COW', head_count: 12 }],
              farm: { calving_system: null, shelter_type: null },
            })
          // rpc_get_org_batches всегда noBackend — useBatches.ts падает в localStorage-кеш
          // (см. seedBatchesCache() ниже). Так же ведёт себя фоновый silent-рефетч после
          // addBatch: он читает кеш, который addBatch уже обновил синхронно (saveLocal ДО
          // фонового fetch) — иначе рефетч стирал бы только что опубликованную партию.
          default:
            return { data: null, error: noBackend }
        }
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

// Одна завершённая партия — вне лимита 5 активных, вне пустого состояния: даёт основной
// док-футер-вход «Продать» (canSell && nAll>0), а не подстановочную кнопку пустого списка.
// Кладём её ПРЯМО в localStorage-кеш useBatches.ts (ключ скоупится по userId из
// rpc_get_my_context) — RPC-строка не участвует (rpc_get_org_batches — всегда noBackend).
const SEED_BATCHES = [{
  id: 'seed-delivered-1', cat: 'bychki', breed: 'Ангус', heads: 10, avgWeight: 380, age: 24,
  fatness: 'Средняя', district: 'Сайрамский район', price: 1400, dealPrice: 1400,
  state: 'delivered', history: [{ t: 'Доставлена', d: '1 сен' }],
}]
const BATCHES_CACHE_KEY = 'agos.cabinet.batches.v1.ars822-farmer'
function seedBatchesCache(): void {
  window.localStorage.setItem(BATCHES_CACHE_KEY, JSON.stringify(SEED_BATCHES))
}

let root: Root | null = null
let mountEl: HTMLElement | null = null
afterEach(() => {
  root?.unmount(); root = null; mountEl?.remove(); mountEl = null
  window.localStorage.clear()
  window.sessionStorage.clear()
  window.history.replaceState(null, '', '/')
})

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms))
const poll = async (fn: () => boolean, ms = 12000) => {
  const t0 = Date.now(); while (Date.now() - t0 < ms) { if (fn()) return true; await sleep(50) } return false
}
const visible = (sel: string): boolean => {
  const el = document.querySelector<HTMLElement>(sel)
  if (!el) return false
  const page = el.closest('.ion-page') as HTMLElement | null
  const t = page ?? el
  return !t.classList.contains('ion-page-invisible') && !t.classList.contains('ion-page-hidden') && t.getAttribute('aria-hidden') !== 'true'
}
// Клик по элементу с ТОЧНЫМ текстом (без вложенных пробелов/переводов строк) — избегаем
// хрупких CSS-селекторов там, где текст сам является контрактом (FR-004/FR-007).
function clickByText(selector: string, text: string): void {
  const el = Array.from(document.querySelectorAll<HTMLElement>(selector))
    .find((e) => (e.textContent ?? '').trim() === text)
  if (!el) throw new Error(`clickByText: не найден "${selector}" с текстом "${text}"`)
  el.click()
}
const hasText = (selector: string, text: string): boolean =>
  Array.from(document.querySelectorAll<HTMLElement>(selector)).some((e) => (e.textContent ?? '').trim() === text)

// ---------- селекторы экранов (data-screen-label — контракт слайса) ----------
const MARKET_SEL = '[data-screen-label^="Рынок"]'
const HOME_SEL = '[data-screen-label^="Главная"]'
const BATCH_SEL = '[data-screen-label^="Партия · "]'
const LIST_SEL = '[data-screen-label="Мои партии"]'
const FARM_SEL = '[data-screen-label="Ферма"]'
const wizSel = (step: number) => `[data-screen-label="SCR-02 · мастер · шаг ${step}"]`
const SEARCH_SEL = '[data-screen-label^="SCR-03 · публикация · поиск"]'
// windowPreset='now' → variant='B' (см. заголовок файла).
const RESULT_SEL = '[data-screen-label="SCR-03 · публикация · вариант B"]'

const DRAFT_KEY = 'agos.tsp.draft.v1'
// Черновик на шаге 5: windowPreset='now' → не отложено → variant='B' (не 'A'/'D' — автоматч
// не зовётся в локальной сборке, поиск покупателя реально идёт SEARCH_MS≈2.2с).
function seedDraft(step: 1 | 2 | 3 | 4 | 5): void {
  const draft = {
    step, breed: 'Казахская белоголовая', heads: 20, avgWeight: 400, age: 18,
    fatness: 'Средняя', district: 'Сайрамский район', windowPreset: 'now',
    customFrom: '', customTo: '', catKey: 'bychki', catUnknown: false, catLoading: false,
    price: '1500', lowOk: false, draftId: null,
  }
  window.sessionStorage.setItem(DRAFT_KEY, JSON.stringify(draft))
}

function mountApp(path: string, under: string[] = []): void {
  seedBatchesCache()
  // Как в проде (и как N-7 в router-tabstack): под кабинетом лежат записи auth-фаннела, а не
  // страница тест-раннера — иначе серия «назад» (M-021) уводит вкладку с раннера и рвёт
  // соединение vitest. Возврат с /welcome в кабинет делает ShellBackGuard.
  window.history.replaceState(null, '', '/welcome')
  for (let i = 0; i < 6; i++) window.history.pushState(null, '', '/welcome')
  for (const u of under) window.history.pushState(null, '', u)
  window.history.pushState(null, '', path)
  mountEl = document.createElement('div'); document.body.appendChild(mountEl)
  root = createRoot(mountEl); root.render(<App />)
}
// Промежуточный unmount ВНУТРИ одного `it` (M-018 монтирует «Рынок» заново трижды —
// разные шаги черновика). Отдельная функция, а не инлайн `root?.unmount(); root = null` —
// TS иначе теряет тип `root` (narrows to `never`) при повторном присваивании в одной строке.
function unmountApp(): void {
  root?.unmount(); root = null
  mountEl?.remove(); mountEl = null
  window.history.replaceState(null, '', '/')
}

/** Маунт на «Рынке» → «Продать» → черновик шага 5 уже в sessionStorage → «Опубликовать
 * партию» → пауза-поиска (SCR-03 · поиск) → экран результата (variant B). Оставляет
 * приложение смонтированным на экране результата (не searching). */
async function publishToResult(): Promise<void> {
  seedDraft(5)
  mountApp('/cabinet/market')
  expect(await poll(() => visible(MARKET_SEL))).toBe(true)

  clickByText('.mk-cta.primary', 'Продать')
  expect(await poll(() => visible(wizSel(5)))).toBe(true)
  await sleep(750)   // NAV_ANIM_MS (650) осесть, как в router-tabstack.browser.test.tsx

  clickByText('.mk-cta.primary', 'Опубликовать партию')
  expect(await poll(() => visible(SEARCH_SEL))).toBe(true)
  // SEARCH_MS=2200 — ждём естественного завершения паузы-поиска (не трогаем таймер).
  expect(await poll(() => visible(RESULT_SEL), 6000)).toBe(true)
}

/** G1: вход в мастер НЕ с «Рынка», а с «Мои партии» (/cabinet/market/list, entry под экраном
 * результата ≠ '/cabinet/market') — тот же CTA-текст «Новая партия», ListScreen.onNew. Проверяет
 * FR-006: вердикт onPop('market') не зависит от того, откуда именно вошли в мастер. */
async function publishFromListEntry(): Promise<void> {
  seedDraft(5)
  mountApp('/cabinet/market/list')
  expect(await poll(() => visible(LIST_SEL))).toBe(true)

  clickByText('.mk-cta.primary', 'Новая партия')
  expect(await poll(() => visible(wizSel(5)))).toBe(true)
  await sleep(750)

  clickByText('.mk-cta.primary', 'Опубликовать партию')
  expect(await poll(() => visible(SEARCH_SEL))).toBe(true)
  expect(await poll(() => visible(RESULT_SEL), 6000)).toBe(true)
}

// ── M-010/M-011/M-012 ────────────────────────────────────────────────────────

it('M-010 M-011 M-012: экран результата — «К партии» + «На главную», без «К моим партиям»; «На главную» → Главная; «Рынок» в меню → список с новой партией', async () => {
  await publishToResult()

  // M-010: док только «К партии» + «На главную», «К моих партиям» нет нигде на экране.
  expect(hasText('.sh-foot .mk-cta', 'К партии')).toBe(true)
  expect(hasText('.sh-foot .mk-link', 'На главную')).toBe(true)
  expect(document.querySelector('[data-screen-label="SCR-03 · публикация · вариант B"]')?.textContent)
    .not.toMatch(/К моим партиям/)
  expect(hasText('.sh-foot *', 'К моим партиям')).toBe(false)

  // M-011: «На главную» одним нажатием → Главная, меню видно, экран результата не остаётся.
  clickByText('.sh-foot .mk-link', 'На главную')
  expect(await poll(() => visible(HOME_SEL) && window.location.pathname === '/cabinet/home')).toBe(true)
  expect(visible(RESULT_SEL)).toBe(false)
  expect(visible('ion-tab-bar')).toBe(true)

  // M-012: «Рынок» в меню → список партий, новая партия среди них (не результат, не мастер).
  document.querySelector<HTMLElement>('ion-tab-button[tab="market"]')!.click()
  expect(await poll(() => visible(MARKET_SEL) && window.location.pathname === '/cabinet/market')).toBe(true)
  expect(visible(RESULT_SEL)).toBe(false)
  expect(visible(wizSel(5))).toBe(false)
  expect(document.querySelectorAll('.mk-listgroups .mk-stack8 > *').length).toBeGreaterThanOrEqual(2)   // сид + новая
})

// ── M-013 ─────────────────────────────────────────────────────────────────────

it('M-013: «К партии» → подпись «‹ Рынок»; кнопка назад и системный «назад» оба ведут на «Рынок», не на экран результата', async () => {
  await publishToResult()

  clickByText('.sh-foot .mk-cta', 'К партии')
  expect(await poll(() => visible(BATCH_SEL))).toBe(true)
  expect(document.querySelector('.sub-back-l')?.textContent?.trim()).toBe('Рынок')
  await sleep(750)   // navBusy-окно форвард-перехода

  document.querySelector<HTMLElement>('.sub-back')!.click()
  expect(await poll(() => visible(MARKET_SEL) && window.location.pathname === '/cabinet/market')).toBe(true)
  await sleep(700)   // дать Ionic доиграть pop-анимацию (старый экран помечается hidden не мгновенно)
  expect(visible(RESULT_SEL)).toBe(false)
  expect(visible(BATCH_SEL)).toBe(false)
})

it('M-013b: системный/браузерный «назад» на партии, открытой «К партии» — тоже на «Рынок»', async () => {
  await publishToResult()

  clickByText('.sh-foot .mk-cta', 'К партии')
  expect(await poll(() => visible(BATCH_SEL))).toBe(true)
  await sleep(750)

  window.history.back()
  expect(await poll(() => visible(MARKET_SEL) && window.location.pathname === '/cabinet/market')).toBe(true)
  await sleep(700)
  expect(visible(BATCH_SEL)).toBe(false)
})

// ── M-014 / M-015 ────────────────────────────────────────────────────────────

it('M-014: системный «назад» прямо на экране результата → «Рынок»; шаг «Проверим перед публикацией.» не показан', async () => {
  await publishToResult()

  window.history.back()
  expect(await poll(() => visible(MARKET_SEL) && window.location.pathname === '/cabinet/market')).toBe(true)
  await sleep(700)
  expect(visible(RESULT_SEL)).toBe(false)
  expect(visible(wizSel(5)), 'мастер на шаге 5 («Проверим перед публикацией.») не должен всплыть').toBe(false)
})

it('M-015: «назад» во время паузы-поиска → «Рынок»; партия уже опубликована', async () => {
  seedDraft(5)
  mountApp('/cabinet/market')
  expect(await poll(() => visible(MARKET_SEL))).toBe(true)
  clickByText('.mk-cta.primary', 'Продать')
  expect(await poll(() => visible(wizSel(5)))).toBe(true)
  await sleep(750)
  clickByText('.mk-cta.primary', 'Опубликовать партию')
  expect(await poll(() => visible(SEARCH_SEL))).toBe(true)

  // назад ПОКА идёт пауза-поиска (SEARCH_MS=2200 ещё не истёк)
  window.history.back()
  expect(await poll(() => visible(MARKET_SEL) && window.location.pathname === '/cabinet/market')).toBe(true)
  await sleep(700)
  expect(visible(SEARCH_SEL)).toBe(false)
  expect(visible(wizSel(5)), 'шаг проверки мастера не показан').toBe(false)
  // партия опубликована (addBatch сработал синхронно ДО пуша на экран результата)
  expect(document.querySelectorAll('.mk-listgroups .mk-stack8 > *').length).toBeGreaterThanOrEqual(2)
})

// ── M-018 (до публикации — этим слайсом не меняется, FR-011) ───────────────────

it('M-018: до публикации — ‹ в шапке шага 3 → шаг 2; ‹ на шаге 1 → «Рынок»; системный «назад» на шаге 3 → «Рынок»', async () => {
  // (а) шаг 3 → ‹ в шапке → шаг 2
  seedDraft(3)
  mountApp('/cabinet/market')
  expect(await poll(() => visible(MARKET_SEL))).toBe(true)
  clickByText('.mk-cta.primary', 'Продать')
  expect(await poll(() => visible(wizSel(3)))).toBe(true)
  await sleep(750)
  document.querySelector<HTMLElement>('.mk-wiz-back')!.click()
  expect(await poll(() => visible(wizSel(2)))).toBe(true)
  unmountApp()

  // (б) шаг 1 → ‹ → «Рынок»
  seedDraft(1)
  mountApp('/cabinet/market')
  expect(await poll(() => visible(MARKET_SEL))).toBe(true)
  clickByText('.mk-cta.primary', 'Продать')
  expect(await poll(() => visible(wizSel(1)))).toBe(true)
  await sleep(750)
  document.querySelector<HTMLElement>('.mk-wiz-back')!.click()
  expect(await poll(() => visible(MARKET_SEL) && window.location.pathname === '/cabinet/market')).toBe(true)
  unmountApp()

  // (в) шаг 3 → системный «назад» → «Рынок»
  seedDraft(3)
  mountApp('/cabinet/market')
  expect(await poll(() => visible(MARKET_SEL))).toBe(true)
  clickByText('.mk-cta.primary', 'Продать')
  expect(await poll(() => visible(wizSel(3)))).toBe(true)
  await sleep(750)
  window.history.back()
  expect(await poll(() => visible(MARKET_SEL) && window.location.pathname === '/cabinet/market')).toBe(true)
})

// ── M-020 ─────────────────────────────────────────────────────────────────────

it('M-020: браузерный «вперёд» после ухода с завершённой публикации не открывает экран результата', async () => {
  await publishToResult()
  window.history.back()
  expect(await poll(() => visible(MARKET_SEL) && window.location.pathname === '/cabinet/market')).toBe(true)

  window.history.forward()
  await sleep(600)
  expect(visible(RESULT_SEL)).toBe(false)
  expect(visible(SEARCH_SEL)).toBe(false)
  expect(window.location.pathname).toBe('/cabinet/market')
})

// ── M-021 ─────────────────────────────────────────────────────────────────────

it('M-021: пять «назад» подряд после ухода с публикации — ни экран результата, ни шаги мастера не появляются', async () => {
  await publishToResult()
  window.history.back()
  expect(await poll(() => visible(MARKET_SEL) && window.location.pathname === '/cabinet/market')).toBe(true)
  await sleep(700)

  for (let i = 0; i < 5; i++) {
    window.history.back()
    await sleep(700)
    expect(visible(RESULT_SEL), `back #${i + 1}: экран результата не должен появиться`).toBe(false)
    expect(visible(SEARCH_SEL), `back #${i + 1}: пауза-поиск не должна появиться`).toBe(false)
    for (let s = 1; s <= 5; s++) {
      expect(visible(wizSel(s)), `back #${i + 1}: шаг мастера ${s} не должен появиться`).toBe(false)
    }
  }
})

// ── G1 (верификационный разбор): вердикт 'market' не зависит от того, откуда вошли в мастер ──
// Записи ПОД экраном результата/партии в этих сценариях — НЕ '/cabinet/market' (а
// '/cabinet/market/list'), поэтому onPop('market') обязан явно увести на таб-корень, а не
// просто «пропустить» pop (иначе фермер вернулся бы на «Мои партии» — тоже валидный экран
// «Рынка» по FR-006 месту, но НЕ тот, что требует матрица: «Рынок» = таб-корень).

it('M-013 M-014 FR-006: вход из «Мои партии» — системный «назад» с экрана результата уводит на «Рынок» (таб-корень), не на «Мои партии»', async () => {
  await publishFromListEntry()

  window.history.back()
  expect(await poll(() => visible(MARKET_SEL) && window.location.pathname === '/cabinet/market')).toBe(true)
  await sleep(700)
  expect(visible(LIST_SEL), '«Мои партии» — экран входа, не должен остаться/переоткрыться').toBe(false)
  expect(visible(RESULT_SEL)).toBe(false)
  expect(visible(wizSel(5))).toBe(false)
})

it('M-013 FR-006 (вариант «К партии»): вход из «Мои партии» → «К партии» → «‹ Рынок» → таб-корень «Рынок», не «Мои партии»', async () => {
  await publishFromListEntry()

  clickByText('.sh-foot .mk-cta', 'К партии')
  expect(await poll(() => visible(BATCH_SEL))).toBe(true)
  expect(document.querySelector('.sub-back-l')?.textContent?.trim()).toBe('Рынок')
  await sleep(750)

  document.querySelector<HTMLElement>('.sub-back')!.click()
  expect(await poll(() => visible(MARKET_SEL) && window.location.pathname === '/cabinet/market')).toBe(true)
  await sleep(700)
  expect(visible(LIST_SEL), '«Мои партии» — экран входа, не должен остаться/переоткрыться').toBe(false)
  expect(visible(BATCH_SEL)).toBe(false)
})

// M-016 (вход из мастера фермы, «Продать через TURAN», sellFromFarm в CabinetApp.tsx) —
// НЕ добавлен. sellFromFarm требует пройти реальные шаги FarmWizard до экрана цен (Payoff-1),
// который сам требует загруженного профиля фермы + сгенерированного годового плана
// (rpc_generate_plan_from_profile) — на порядок дороже замокать, чем «одна RPC-ветка» у
// остальных сценариев этого файла (пришлось бы воспроизводить весь FarmWizard-флоу шаг за
// шагом, а не просто засеять черновик). Механика выхода (goFlow/onPop) у farmwiz→batchwiz общая
// с market→batchwiz (тот же go({name:'batchwiz'}) из CabinetApp.sellFromFarm), так что M-013/
// M-014/M-017 выше уже покрывают ветвление onPop по флагу flowExitRef независимо от входа —
// но сам вход из «Ферма» этим файлом не проверен. Открытый пробел, не тихо закрытый.

// ── G2 ────────────────────────────────────────────────────────────────────────

it('M-017: «На главную» → никуда не переходя с «Главной» → «назад» уводит на «Рынок» (таб-корень), не выбрасывает из кабинета', async () => {
  await publishToResult()

  clickByText('.sh-foot .mk-link', 'На главную')
  expect(await poll(() => visible(HOME_SEL) && window.location.pathname === '/cabinet/home')).toBe(true)
  await sleep(700)

  window.history.back()
  expect(await poll(() => visible(MARKET_SEL) && window.location.pathname === '/cabinet/market')).toBe(true)
  await sleep(700)
  expect(visible(HOME_SEL)).toBe(false)
  expect(visible(RESULT_SEL)).toBe(false)
  expect(visible(wizSel(5))).toBe(false)
})

// ── G3 (M-001/M-008/M-009 — геометрия дока над таб-баром, FR-001/FR-002) ──────────

it('M-001: «Продать» на «Рынке» — целиком над таб-баром (bottom кнопки ≤ top меню, зазор < 40px), .sh-foot.has-tabbar', async () => {
  mountApp('/cabinet/market')
  expect(await poll(() => visible(MARKET_SEL))).toBe(true)
  expect(await poll(() => !!document.querySelector('.sh-foot button'))).toBe(true)
  await sleep(300)   // осесть layout (safe-area/шрифты) — как в паттернах анимации выше

  const foot = document.querySelector('.sh-foot') as HTMLElement
  const btn = document.querySelector('.sh-foot button') as HTMLElement
  const tabbar = document.querySelector('ion-tab-bar') as HTMLElement
  expect(foot, 'должен быть .sh-foot').toBeTruthy()
  expect(btn, 'должна быть кнопка дока («Продать»)').toBeTruthy()
  expect(tabbar, 'должен быть ion-tab-bar').toBeTruthy()
  expect(foot.classList.contains('has-tabbar'), 'FR-002: правило рамки — .sh-foot.has-tabbar').toBe(true)

  const btnRect = btn.getBoundingClientRect()
  const barRect = tabbar.getBoundingClientRect()
  expect(btnRect.bottom, 'FR-001: низ кнопки не ниже верха меню').toBeLessThanOrEqual(barRect.top)
  expect(btnRect.bottom, 'зазор тот же, что у «Фермы» — не «плавает» далеко от меню').toBeGreaterThan(barRect.top - 40)
})

it('M-008: «Записать событие» на «Ферме» — целиком над таб-баром, .sh-foot.has-tabbar (прежнее частное правило по data-screen-label снято)', async () => {
  mountApp('/cabinet/farm')
  expect(await poll(() => visible(FARM_SEL))).toBe(true)
  // captureFooter рендерится, только когда loadFarmCtx нашёл farm+org И hasHerd=true
  // (rpc_get_farm_summary — см. мок выше); без этого пропуск был бы честной причиной, не молчанием.
  const gotFooter = await poll(() => !!document.querySelector('.fm-cap-cta'), 6000)
  expect(gotFooter, 'мок фермы (farms[0] + rpc_get_farm_summary с поголовьем) должен дать captureFooter').toBe(true)
  await sleep(300)

  const foot = document.querySelector('.sh-foot') as HTMLElement
  const btn = document.querySelector('.fm-cap-cta') as HTMLElement
  const tabbar = document.querySelector('ion-tab-bar') as HTMLElement
  expect(foot.classList.contains('has-tabbar')).toBe(true)

  const btnRect = btn.getBoundingClientRect()
  const barRect = tabbar.getBoundingClientRect()
  expect(btnRect.bottom).toBeLessThanOrEqual(barRect.top)
  expect(btnRect.bottom).toBeGreaterThan(barRect.top - 40)
})

it('M-009: «Мои партии» — .sh-foot БЕЗ has-tabbar (детальный экран, меню скрыто, отступа не даёт)', async () => {
  mountApp('/cabinet/market/list')
  expect(await poll(() => visible(LIST_SEL))).toBe(true)
  expect(await poll(() => !!document.querySelector('.sh-foot'))).toBe(true)

  const foot = document.querySelector('.sh-foot') as HTMLElement
  expect(foot.classList.contains('has-tabbar'), 'FR-003: детальный экран — без резерва под меню').toBe(false)
})

// ── G4 (B1.1 — перезагрузка посреди мастера: остров не знает ключ записи «Рынка» под ним) ─────
// Другой случай — мастер ПЕРВОЙ записью кабинета (deep-link, под ним /welcome) — сюда НЕ входит:
// «назад» уходит ниже кабинета, ShellBackGuard (backGuard.ts) возвращает на lastShell внешнего
// v6-роутера, а тот переходов острова не видит и помнит мастер. Воспроизведено 2026-09-25
// (history.replace из ShellBackGuard.onPop на /cabinet/market/new) — долг
// TSP-FLOWEXIT-OUTER-ROUTER-POP-01 в IMPL_DEBT.md.
it('B1.1: перезагрузка на /cabinet/market/new (запись «Рынка» под мастером острову неизвестна) → публикация → «назад» всё равно уводит на «Рынок» (fallback-таймер revertPop, 400мс)', async () => {
  seedDraft(5)
  // Перезагрузка посреди мастера: под ним в браузере запись «Рынка», которую остров после
  // перезагрузки не знает (ключа нет в allKeys → revertPop не откатывает → работает таймер).
  mountApp('/cabinet/market/new', ['/cabinet/market'])
  expect(await poll(() => visible(wizSel(5)))).toBe(true)
  await sleep(750)

  clickByText('.mk-cta.primary', 'Опубликовать партию')
  expect(await poll(() => visible(SEARCH_SEL))).toBe(true)
  expect(await poll(() => visible(RESULT_SEL), 6000)).toBe(true)

  window.history.back()
  await sleep(600)   // ≥ 400мс fallback-таймера IonBridge
  expect(window.location.pathname, 'URL должен сойтись на «Рынке»').toBe('/cabinet/market')
  expect(visible(MARKET_SEL), 'экран должен совпасть с URL — «Рынок» виден').toBe(true)
  expect(visible(RESULT_SEL)).toBe(false)
  expect(visible(wizSel(5))).toBe(false)
})
