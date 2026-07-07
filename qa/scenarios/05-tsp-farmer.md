# 05 — TSP: продажа скота, сторона фермера (TSPF-*)

> Канон: **Microstep 4** (Batch/Pool/Offer FSM, переходы BT-01…BT-23) + **Microstep 6 §M6-A**
> (флоу фермера), Dok6-Slice5a. Реальность: `BatchWizard.tsx` (5 шагов), `BatchScreen.tsx`,
> self-serve adapter `rpc_self_*` (миграции) + canon-слой d02_tsp.sql; дробление партии —
> `batch_allocations` (Слайсы 8–9, кусок = сделка).
>
> Конфиг (standards-as-data, `tsp_config`): offer_window = 24 ч; mpk_decision_window = 24 ч;
> шаг снижения цены = 100 ₸/кг (стоп на защитной цене, D-M6-3); publish_lead = 7 дней
> (D-M6-9); лимит активных партий = 5; мин. кусок дробления = 5 голов (min_split_heads).
> Валидации: голов 1–500, вес 100–800 кг, возраст 3–120 мес.
>
> Словарь фермера (D-TSP-16): слова Pool/Offer/match/target/filled в UI НЕ появляются.
> Маппинг из концепта: блок F → TSPF-GATE/WIZ/PUB; блок G → TSPF-RES; блок H → TSPF-LIFE.

---

## TSPF-GATE — гейты входа в продажу

#### TSPF-GATE-01 · UNHAPPY · Не член пытается продать
`layer:ui+rpc` `canon:MS6-Step0` `impl:MembGateSheet` `auto:candidate:sql` `status:active`
- **Предусловие:** membership ∉ {active, expiring, grace, …}.
- **Ожидание:** MembGateSheet («Доступно членам TURAN» / «Заявка на рассмотрении» / «Членство истекло»), визард не открывается. RPC-уровень тоже отклоняет (SEC-GATE-01).

#### TSPF-GATE-02 · UNHAPPY · Лимит активных партий
`layer:ui+rpc` `canon:MS6-4a-Step1` `impl:LimitSheet` `auto:candidate:sql` `status:blocked:SEC-GATE-LIMIT-01`
- **Предусловие:** уже 5 активных партий.
- **Ожидание:** LimitSheet «Максимум 5 активных партий одновременно…»; визард не открывается; CTA «Мои партии». Значение лимита — из конфига.

---

## TSPF-WIZ — визард «Новая партия» (5 шагов)

#### TSPF-WIZ-01 · HAPPY · Шаг 1 «Животные»
`layer:ui` `canon:MS6-4a-Step1` `impl:WizStep1Animals.tsx` `auto:none` `status:active`
- **Шаги:** порода, голов 1–500, ср. вес 100–800 кг, возраст 3–120 мес, упитанность → «Далее».
- **Ожидание:** переход на шаг 2; вид зафиксирован «КРС»; регион read-only из профиля хозяйства («берётся из данных регистрации»).

#### TSPF-WIZ-02 · UNHAPPY · Шаг 1: не выбрана порода/упитанность
`layer:ui` `canon:code` `impl:WizStep1Animals.tsx` `auto:none` `status:active`
- **Ожидание:** кнопка «Далее» всегда активна, но: янтарная подсветка проблемного поля + скролл к нему («Выберите породу» / «Выберите упитанность»); переход блокируется.

#### TSPF-WIZ-03 · UNHAPPY · Шаг 1: голов вне 1–500
`layer:ui` `canon:MS6-4a-Step1` `impl:WizStep1Animals.tsx` `auto:candidate:unit` `status:active`
- **Ожидание:** ввод 0 или 501 → «Голов обычно от 1 до 500.»; «Далее» скроллит к полю.

#### TSPF-WIZ-04 · UNHAPPY · Шаг 1: вес вне 100–800
`layer:ui` `canon:MS6-4a-Step1` `impl:WizStep1Animals.tsx` `auto:candidate:unit` `status:active`
- **Ожидание:** напр. 8000 → «Вес обычно от 100 до 800 кг. Проверьте, не указали ли общий вес вместо среднего.»

#### TSPF-WIZ-05 · UNHAPPY · Шаг 1: возраст вне 3–120
`layer:ui` `canon:MS6-4a-Step1` `impl:WizStep1Animals.tsx` `auto:candidate:unit` `status:active`
- **Ожидание:** 1 или 200 → «Возраст — от 3 до 120 месяцев.»

#### TSPF-WIZ-06 · HAPPY · Шаг 2 «Окно готовности» — пресеты
`layer:ui` `canon:MS6-2.1;D-M6-6` `impl:WizStep2Window.tsx` `auto:none` `status:active`
- **Шаги:** «Готовы сейчас» / «В этом месяце» / «В следующем» / «Через 2 месяца».
- **Ожидание:** сводка «Окно отгрузки: <с> — <по>» (для «сейчас» — today…+14 дн); переход разрешён; бэкенд получает канонический интервал [ready_from, ready_to].

#### TSPF-WIZ-07 · UNHAPPY · Шаг 2: пресет не выбран
`layer:ui` `canon:code` `impl:WizStep2Window.tsx` `auto:none` `status:active`
- **Ожидание:** янтарная подсветка списка + «Выберите, когда животные будут готовы».

#### TSPF-WIZ-08 · UNHAPPY · Шаг 2: свои даты некорректны
`layer:ui` `canon:MS6-2.1` `impl:WizStep2Window.tsx` `auto:candidate:unit` `status:active`
- **Ожидание:** «по» раньше «с», «с» раньше вчера, пустая дата → «„По“ должно быть не раньше „с“, а „с“ — не раньше сегодня.» / «Укажите обе даты»; переход блокируется. Инвариант канона: ready_to ≥ ready_from.

#### TSPF-WIZ-09 · EDGE · Отложенная публикация — инфо-плашка
`layer:ui` `canon:MS6-2.2;D-M6-7;D-M6-9` `impl:WizStep2Window.tsx` `auto:none` `status:active`
- **Предусловие:** окно начинается более чем через 7 дней (publish_lead).
- **Ожидание:** плашка «ВЫХОД В ПРОДАЖУ: партия выйдет в продажу — за неделю до готовности».

#### TSPF-WIZ-10 · HAPPY · Шаг 3 «Категория» — автоопределение
`layer:ui` `canon:MS4-§6.1;D-TSP-12` `impl:WizStep3Category.tsx` `auto:none` `status:mock`
- **Ожидание:** лоадер «Определяем категорию…» (~1.4 с — фронтовый мок, не rpc_derive_category); категория авто (возраст ≤12 → молодняк; ≥60 → коровы; ≤36 → бычки; иначе тёлки); карточка read-only «Категорию нельзя выбрать вручную»; показан сорт для покупателя (Хорошая → Высшая/Премиум при элитной породе и весе ≥450; Средняя → Первая; Ниже средней → Вторая).
- **Канон-хвост:** классификатор в БД (livestock_category_rule по priority, версии с effective_from/to) — при переходе на серверный классификатор кейс переписать.

#### TSPF-WIZ-11 · UNHAPPY · Шаг 3: категория не определена
`layer:ui` `canon:MS6-4a-Step2` `impl:WizStep3Category.tsx` `auto:none` `status:active`
- **Предусловие:** порода «Смешанная/другая» (нет матча).
- **Ожидание:** «Не получилось определить категорию»; публикация недоступна; варианты «Вернуться к данным» (сброс категории, назад к шагу 2) / «Написать в TURAN»; подпись «черновик сохранён · публикация недоступна».

#### TSPF-WIZ-12 · HAPPY · Шаг 4 «Цена»
`layer:ui` `canon:MS6-4a-Step3;D-TSP-2;ст.171` `impl:WizStep4Price.tsx` `auto:none` `status:active`
- **Ожидание:** «Рекомендуемая цена по категории … ₸/кг» + дисклеймер «Справочная информация ассоциации. Не является обязательной…» (антитраст, SEC-ART-01); расчёт «≈ голов × вес × цена = сумма (ориентировочно)»; при цене ≥ защитной — переход разрешён.

#### TSPF-WIZ-13 · UNHAPPY · Шаг 4: цена не указана
`layer:ui` `canon:code` `impl:WizStep4Price.tsx` `auto:none` `status:active`
- **Ожидание:** янтарная ошибка «Укажите цену».

#### TSPF-WIZ-14 · EDGE · Шаг 4: цена ниже защитной — soft-warn
`layer:ui` `canon:MS4-D-TSP-4;MS6-4a-Step3` `impl:WizStep4Price.tsx` `auto:candidate:unit` `status:active`
- **Ожидание:** warning-панель «Цена ниже защитной цены ассоциации — X ₸/кг»; переход ТОЛЬКО после чекбокса «Понимаю и подтверждаю цену…»; без чекбокса — «Подтвердите цену, чтобы продолжить»; изменение цены сбрасывает подтверждение. Канон: фермеру — soft-warn (МПК — hard-block, TSPM-POOL-02); асимметрия D-TSP-4.

#### TSPF-WIZ-15 · HAPPY · Шаг 5 «Проверка»
`layer:ui` `canon:MS6-4a-Step4` `impl:WizStep5Review.tsx` `auto:none` `status:active`
- **Ожидание:** сводка животные/окно/категория/цена/итого с кнопками ✎ (шаги 1/2/4; категория без правки); строка «Выйдет в продажу: сразу / <дата> (за 7 дней до готовности)»; есть «Сохранить черновик и выйти».

#### TSPF-WIZ-16 · EDGE · Черновик визарда
`layer:ui` `canon:code` `impl:useBatchDraft` `auto:none` `status:active`
- **Ожидание:** закрыть визард / обновить страницу → состояние восстановлено из sessionStorage; после успешной публикации черновик очищен.

---

## TSPF-PUB — публикация и результат

#### TSPF-PUB-01 · HAPPY · Публикация — спот (BT-01/02/03)
`layer:ui+rpc` `canon:MS4-BT-01..03` `impl:rpc_create_batch+rpc_self_auto_match_batch` `auto:tests/tsp_happy_path` `status:active`
- **Предусловие:** окно ≤7 дней от сегодня.
- **Ожидание:** «Опубликовать партию» → `rpc_create_batch(p_scheduled=false)` → `rpc_self_auto_match_batch`; черновик очищен; экран результата (TSPF-RES).

#### TSPF-PUB-02 · HAPPY · Публикация — отложенная (BT-20)
`layer:ui+rpc` `canon:MS6-§3;D-M6-7` `impl:rpc_create_batch` `auto:candidate:sql` `status:active`
- **Предусловие:** окно >7 дней.
- **Ожидание:** `p_scheduled=true`; партия scheduled; результат — вариант D «Запланировано: выйдет в продажу <дата>».

#### TSPF-PUB-03 · EDGE · Backend недоступен при публикации
`layer:ui` `canon:code` `impl:BatchWizard` `auto:none` `status:mock`
- **Ожидание:** партия собирается локально (demo-фолбэк, id `local-…`), появляется в кабинете offering/scheduled с историей; публикация не «ломается». Поведение MVP — при реальном бэкенде убрать.

#### TSPF-PUB-04 · EDGE · Сбой автоматча не откатывает публикацию
`layer:ui+rpc` `canon:code` `impl:BatchWizard` `auto:none` `status:active`
- **Ожидание:** `rpc_self_auto_match_batch` падает → партия остаётся offering/published; предупреждение только в консоли.

#### TSPF-PUB-05 · UNHAPPY · Ошибка публикации (нелокальная)
`layer:ui` `canon:code` `impl:BatchWizard` `auto:none` `status:active`
- **Ожидание:** toast «Ошибка публикации»; пользователь на шаге 5, данные сохранены.

## TSPF-RES — экран результата (SCR-03, варианты A/B/C/D)

#### TSPF-RES-01 · HAPPY · Вариант A — автоматч (BT-01)
`layer:ui` `canon:MS4-§2.2;D-TSP-5;D-M6-5` `impl:BatchWizard result` `auto:none` `status:blocked:BUG-PUBRESULT-VARIANT-01`
- **Условие:** нашёлся пул с подходящей категорией/ценой/районом/окном.
- **Ожидание:** «Покупатель найден!»; цена сделки ≥ цены фермера (если выше — бейдж «на N ₸/кг выше вашей цены», best execution D-TSP-5); покупатель НЕ раскрыт (только при confirmed, D-M6-5); статус matched.

#### TSPF-RES-02 · HAPPY · Вариант B — broadcast (BT-02)
`layer:ui` `canon:MS4-§2.2;D-TSP-6` `impl:BatchWizard result` `auto:none` `status:active`
- **Условие:** автоматча нет, есть подходящие МПК.
- **Ожидание:** «Партия отправлена покупателям»; дедлайн ответа (окно 24 ч); фермер НЕ видит число офферов/адресатов; статус offering.

#### TSPF-RES-03 · HAPPY · Вариант C — нет покупателей (BT-03)
`layer:ui` `canon:MS4-BT-03` `impl:BatchWizard result` `auto:none` `status:active`
- **Ожидание:** «Партия в продаже» + успокаивающий копирайт; статус published; ждёт retry-match (TSPF-LIFE-12).

#### TSPF-RES-04 · HAPPY · Вариант D — запланировано (BT-20)
`layer:ui` `canon:MS6-§3` `impl:BatchWizard result` `auto:none` `status:active`
- **Ожидание:** «Запланировано: выйдет в продажу <дата> — за неделю до готовности. Делать ничего не нужно»; статус scheduled.

#### TSPF-RES-05 · HAPPY · Навигация с результата
`layer:ui` `canon:code` `impl:BatchWizard result` `auto:none` `status:active`
- **Ожидание:** «К партии» → карточка партии; «К моим партиям» → список.

---

## TSPF-LIFE — жизненный цикл партии

#### TSPF-LIFE-01 · UNHAPPY→OK · Окно оффера истекло без согласных (BT-09)
`layer:sql+ui` `canon:MS4-BT-09;D-M6-3` `impl:d02_tsp.sql` `auto:candidate:sql` `status:active`
- **Предусловие:** offering, окно истекло (конфиг `price_decision_after_minutes`; на staging = 1 мин тестовый дефолт, не 24ч — сверять с БД, не с этим текстом), акцептов нет.
- **Ожидание:** партия → decision (awaiting_price_decision); на Главной карточка «Покупатели не согласились по X ₸/кг» с действиями «Снизить до X−100 ₸/кг» (шаг из конфига) и «Другие варианты».

#### TSPF-LIFE-02 · HAPPY · Снижение цены и ребродкаст (BT-11)
`layer:ui+rpc` `canon:MS4-BT-11;D-TSP-8` `impl:rpc_lower_price` `auto:candidate:sql` `status:active`
- **Ожидание:** «Снизить до X−100» → цена обновлена, партия снова offering (повторная рассылка), новый дедлайн 24 ч.

#### TSPF-LIFE-03 · UNHAPPY · Стоп-правило снижения (клэмп на защитной)
`layer:ui` `canon:D-M6-3` `impl:BatchScreen decision` `auto:candidate:unit` `status:active`
- **Предусловие:** X−100 < защитной цены.
- **Ожидание:** кнопка авто-снижения disabled + пояснение; остаются: своя цена вручную (с soft-warn подтверждением), «оставить и ждать» (→ published), снять с продажи. Канон: система НЕ предлагает цену ниже пола.

#### TSPF-LIFE-04 · EDGE · Ручная смена цены (BatchPriceSheet)
`layer:ui` `canon:MS4-BT-06` `impl:BatchPriceSheet` `auto:none` `status:active`
- **Ожидание:** ниже защитной — «Сохранить цену» disabled + «Ниже защитного уровня»; валидная цена → сохранение и (для offering) ребродкаст.

#### TSPF-LIFE-05 · HAPPY · Ожидание в matched — всё залочено
`layer:ui` `canon:MS6-2.1;D-M6-5;D-M6-12` `impl:BatchScreen` `auto:none` `status:active`
- **Ожидание:** статус «покупатель найден · цена зафиксирована»; цена сделки ≥ цены фермера; покупатель и прогресс заполнения пула НЕ видны; цена и окно залочены (канон: farmer_price/ready_from/ready_to лочатся при matched).

#### TSPF-LIFE-06 · EDGE · Снятие до матча — свободно (BT-04/07/10/23)
`layer:ui+rpc` `canon:MS4-BT-04/07/10;MS6-§3.2` `impl:WithdrawSheet+rpc_cancel_batch` `auto:candidate:sql` `status:active`
- **Предусловие:** draft/published/offering/scheduled.
- **Ожидание:** снятие без предупреждений («Партию можно выставить заново в любой момент»); offering-офферы отзываются (withdrawn); партия → cancelled.

#### TSPF-LIFE-07 · EDGE · Снятие после матча — с пометкой (BT-15)
`layer:ui+rpc` `canon:MS4-BT-15;D-TSP-14` `impl:rpc_self_withdraw_batch` `auto:candidate:sql` `status:active`
- **Предусловие:** matched.
- **Ожидание:** предупреждение «Покупатель уже найден. Отмена будет отмечена и повлияет на рейтинг. Если пул уже заполнен — снять нельзя, свяжитесь с TURAN»; при подтверждении — партия cancelled, `pool.filled_volume` уменьшен, пул остаётся filling; событие cancelled_after_match записано (штрафа в MVP нет, D-TSP-14).

#### TSPF-LIFE-08 · EDGE · Снятие дроблёной партии (batch_allocations)
`layer:ui+rpc` `canon:BATCH-SPLIT-01(DECISIONS_LOG)` `impl:WithdrawSheet+d02 SECTION 9` `auto:candidate:sql` `status:active`
- **Предусловие:** часть голов продана (куски matched/confirmed).
- **Ожидание:** три исхода: «Снять остаток (N гол.)» — бесплатно, проданные куски остаются; «Снять остаток и отменить проданное» — с пометкой о рейтинге; confirmed-куски (пул заполнен) снять нельзя — блокирует RPC/RLS. Правило минимума куска: ≥ min_split_heads (5), остаток 0 или ≥ min.

#### TSPF-LIFE-09 · UNHAPPY · Отмена после confirmed — только через админа (BT-17)
`layer:ui+rpc` `canon:MS4-BT-17;D-TSP-15` `impl:BatchScreen` `auto:candidate:sql` `status:active`
- **Предусловие:** confirmed/dispatched.
- **Ожидание:** кнопки отмены нет — только «Нужно отменить? Свяжитесь с TURAN»; RPC фермера отклоняет отмену (INVALID_STATUS).

#### TSPF-LIFE-10 · HAPPY · Пул закрылся → confirmed + раскрытие (BT-13)
`layer:sql+ui` `canon:MS4-BT-13;D-TSP-11;D-M6-5` `impl:d02_tsp.sql auto-close` `auto:tests/tsp_happy_path` `status:active`
- **Ожидание:** партия → confirmed; покупатель РАСКРЫВАЕТСЯ («Сделка подтверждена. Покупатель: <МПК>. Цена: Z ₸/кг»); на Главной «Отметьте отгрузку». Для дроблёной партии раскрытие — per-кусок по закрытию ЕГО пула.

#### TSPF-LIFE-11 · UNHAPPY→OK · Underfill: МПК вернул партии (BT-14)
`layer:sql+ui` `canon:MS4-BT-14;D-TSP-10` `impl:d02_tsp.sql` `auto:candidate:sql` `status:blocked:TSP-FLOW-10`
- **Ожидание:** партия matched → published, deal_price сброшен; уведомление «Покупатель не набрал нужный объём — ваша партия снова в продаже. Это не связано с вашей партией»; партия снова участвует в matching.

#### TSPF-LIFE-12 · HAPPY · Retry-match: published-партия матчится с новым пулом (BT-05)
`layer:sql` `canon:MS4-BT-05;Q-TSP-RETRY-MATCH` `impl:rpc_self_activate_pool_request` `auto:candidate:sql` `status:active`
- **Предусловие:** партия published; МПК публикует подходящий пул.
- **Ожидание:** партия автоматически → matched (или offering через оффер). Примечание: свип published-партий при активации пула — фикс TSP-FLOW-08; перед прогоном проверить деплой миграции 20260625*.

#### TSPF-LIFE-13 · HAPPY · Частичный приём МПК — для фермера как обычный confirmed
`layer:ui` `canon:MS4-PT-06` `impl:BatchScreen` `auto:none` `status:active`
- **Ожидание:** со стороны фермера идентично TSPF-LIFE-10.

#### TSPF-LIFE-14 · HAPPY · Отгрузка (BT-16, D-M6-10)
`layer:ui+rpc` `canon:MS4-BT-16;D-M6-10` `impl:DispatchSheet+rpc_dispatch_batch/rpc_self_dispatch_ready` `auto:candidate:sql` `status:active`
- **Предусловие:** confirmed.
- **Ожидание:** «Партия отгружена» → DispatchSheet: категория, число голов (для дроблёной — только confirmed-куски), цена сделки; подтверждение → dispatched («В пути»), покупатель уведомлён; дроблёный батч — по-кусковая отгрузка.

#### TSPF-LIFE-15 · HAPPY · Приёмка покупателем → delivered (BT-18)
`layer:sql+ui` `canon:MS4-BT-18;D-M6-10` `impl:d02_tsp.sql` `auto:candidate:sql(E2E-TSP-02)` `status:active`
- **Ожидание:** МПК подтверждает приёмку → партия delivered (терминальный успех); открывается окно отзыва.

#### TSPF-LIFE-16 · HAPPY · Отзыв о сделке (D-M6-11)
`layer:ui+rpc` `canon:MS6-§4c;D-M6-11` `impl:rpc_self_review_due_batches` `auto:candidate:sql` `status:blocked:GAP-REVIEW-MOCK-01`
- **Предусловие:** delivered, отзыва нет.
- **Ожидание:** один отзыв на батч на направление (overall 1–5 + ключевая размерность «Честное взвешивание» + текст опц.); после отправки «Ваш отзыв сохранён», кнопка исчезает; отзыв double-blind — виден контрагенту после взаимной подачи или истечения окна (visible_at); отзыв неизменяем после подачи.

#### TSPF-LIFE-17 · HAPPY · Scheduled: авто-выход в продажу (BT-21)
`layer:sql+ui` `canon:MS6-§3.2` `impl:d02_tsp.sql job` `auto:candidate:sql` `status:blocked:TSP-FLOW-02`
- **Предусловие:** scheduled, наступил publish_at.
- **Ожидание:** системный джоб прогоняет matching → matched/offering/published; фермеру уведомление «Ваша партия вышла в продажу» (событие auto_published).

#### TSPF-LIFE-18 · EDGE · Scheduled: правка/отмена до выхода (BT-22/23)
`layer:ui` `canon:MS6-§3.2` `impl:BatchScreen` `auto:none` `status:active`
- **Ожидание:** правка возвращает в draft-семантику (publish_at пересчитывается при смене ready_from); отмена — свободно, без пометок. Примечание: редактирование scheduled в UI отложено (хвост из мозга) — если кнопки нет, фиксировать как gap, не как pass.

#### TSPF-LIFE-19 · EDGE · Таймер снижения цены (poll-driven)
`layer:ui` `canon:DECISIONS_LOG:BATCH-SPLIT-01(price_decision_after_minutes)` `impl:tsp_config` `auto:none` `status:active`
- **Ожидание:** переход offering → decision управляется конфигом `price_decision_after_minutes` (poll-driven); прогон сверяет фактическое значение конфига, не хардкод 24 ч.
