# 01 — Регистрация (REG-*)

> Флоу: `/register` → контакт+OTP → PIN → роль → детали роли → согласия → сабмит.
> Реальность: `src/pages/registration/`, edge-функция `supabase/functions/bird-otp/`,
> `rpc_register_organization` (d01_kernel.sql).
> Маппинг из концепта: блок A → REG-OTP, блок B → REG-PIN, блок C → REG-ROLE/DET/SUB.

**Известные расхождения канон ↔ код (флаг, не баг):**
- Канон D-IDM-6 (MS1): регистрация = 3 отдельных RPC (`rpc_register_user` → `rpc_create_organization` → `rpc_submit_membership_application`). Код: единый `rpc_register_organization`, заявка на членство НЕ подаётся автоматически. Кейсы описывают код; расхождение — MEMBERSHIP-02/04 в IMPL_DEBT.
- Канон D-IDM-5 (MS1): `/register` роль НЕ спрашивает (intent — на /welcome). Код: роль — шаг визарда. Долг IDENTITY-11.
- Канон D-IDM-7: `requires_approval` у типа организации (mpk=true). Код: нет (IDENTITY-06).

Конфиг-значения (standards-as-data, сверять с БД, не с хардкодом): OTP TTL = 5 мин,
попыток = 3, resend-кулдаун = 60 с.

---

## REG-OTP — контакт и код подтверждения

#### REG-OTP-01 · HAPPY · Отправка OTP на валидные данные
`layer:ui+rpc` `canon:code` `impl:supabase/functions/bird-otp` `auto:none` `status:active`
- **Предусловие:** не авторизован, открыт /register.
- **Шаги:** имя ≥2 символа, телефон 10 цифр после +7 → «Получить код».
- **Ожидание:** bird-otp `action=send`; экран кода; маска +7 (XXX) XXX-••-••; таймер 60 с; в `otp_codes` запись (TTL 5 мин, attempts=0); SMS «Код подтверждения TURAN: XXXXXX» через Mobizon.

#### REG-OTP-02 · UNHAPPY · Пустое/короткое имя
`layer:ui` `canon:code` `impl:src/pages/registration` `auto:none` `status:active`
- **Шаги:** имя пустое или 1 символ → «Получить код».
- **Ожидание:** ошибка «Введите ваше имя»; запрос OTP не уходит.

#### REG-OTP-03 · UNHAPPY · Неполный телефон
`layer:ui` `canon:code` `impl:src/pages/registration` `auto:none` `status:active`
- **Шаги:** <10 цифр → «Получить код».
- **Ожидание:** ошибка «Введите номер телефона»; запрос не уходит.

#### REG-OTP-04 · EDGE · Нормализация номера с 8
`layer:ui` `canon:code` `impl:src/pages/registration` `auto:candidate:unit` `status:active`
- **Шаги:** ввести номер, начинающийся с 8 (8771…).
- **Ожидание:** маска приводит к +7 771…; на бэкенд уходит E.164 `+7XXXXXXXXXX`.

#### REG-OTP-05 · UNHAPPY · Ошибка SMS-провайдера
`layer:ui+rpc` `canon:code` `impl:supabase/functions/bird-otp` `auto:none` `status:active`
- **Предусловие:** Mobizon недоступен / вернул code≠0.
- **Ожидание:** toast с текстом ошибки («Ошибка отправки кода» или сообщение провайдера); пользователь остаётся на форме контакта.

#### REG-OTP-06 · HAPPY · Ввод верного кода
`layer:ui+rpc` `canon:code` `impl:supabase/functions/bird-otp` `auto:none` `status:active`
- **Предусловие:** OTP отправлен.
- **Шаги:** ввести 6 верных цифр (автопроверка или «Подтвердить»).
- **Ожидание:** bird-otp `action=check` → `verified:true`; запись `otp_codes` удалена; переход на «Придумайте PIN-код».

#### REG-OTP-07 · UNHAPPY · Неверный код (1–2 попытки)
`layer:ui+rpc` `canon:code` `impl:supabase/functions/bird-otp` `auto:none` `status:active`
- **Ожидание:** toast «Неверный код — попробуйте ещё раз»; поле очищено; на бэкенде attempts+1; пользователь остаётся на экране кода.

#### REG-OTP-08 · UNHAPPY · Исчерпание попыток
`layer:rpc` `canon:code` `impl:supabase/functions/bird-otp` `auto:candidate:sql` `status:active`
- **Предусловие:** 3 неверных попытки по коду.
- **Шаги:** 4-я попытка (любой код, включая верный).
- **Ожидание:** «Превышено число попыток — запросите новый код»; запись удалена; верный код после этого не проходит.

#### REG-OTP-09 · UNHAPPY · Истёкший код
`layer:rpc` `canon:code` `impl:supabase/functions/bird-otp` `auto:candidate:sql` `status:active`
- **Предусловие:** >5 мин с отправки (TTL из конфига).
- **Ожидание:** «Код истёк — запросите новый»; запись удалена; переход не выполняется даже при верном коде.

#### REG-OTP-10 · EDGE · Повторная отправка кода
`layer:ui+rpc` `canon:code` `impl:supabase/functions/bird-otp` `auto:none` `status:active`
- **Ожидание:** «Отправить снова» недоступна пока countdown>0; после нажатия — новый код (upsert по phone → старый код недействителен), поле очищено, таймер снова 60 с.

#### REG-OTP-11 · EDGE · «Изменить номер»
`layer:ui` `canon:code` `impl:src/pages/registration` `auto:none` `status:active`
- **Ожидание:** возврат к форме имени/телефона; введённый код сброшен; `otp_sent=false`.

#### REG-OTP-12 · EDGE · Кнопка «Назад» шапки на фазе OTP
`layer:ui` `canon:code` `impl:src/pages/registration` `auto:none` `status:active`
- **Ожидание:** возврат к фазе ввода телефона (не выход из регистрации); goBack при `otp_sent` сбрасывает только `otp_sent`.

---

## REG-PIN — создание PIN

#### REG-PIN-01 · HAPPY · Создание аккаунта по PIN
`layer:ui+rpc` `canon:code` `impl:supabase/functions/bird-otp` `auto:none` `status:active`
- **Предусловие:** OTP подтверждён.
- **Шаги:** 6-значный PIN → повторить тот же.
- **Ожидание:** bird-otp `action=register` создаёт Supabase-пользователя (phone_confirm=true, password=PIN); сразу `signInWithPassword` — сессия активна; переход на выбор роли.

#### REG-PIN-02 · UNHAPPY · PIN не совпал при подтверждении
`layer:ui` `canon:code` `impl:src/pages/registration/CreatePin` `auto:none` `status:active`
- **Ожидание:** «PIN-коды не совпадают — попробуйте снова»; оба значения сброшены; возврат на первый ввод; аккаунт НЕ создаётся.

#### REG-PIN-03 · UNHAPPY · Номер уже зарегистрирован
`layer:rpc` `canon:code` `impl:supabase/functions/bird-otp` `auto:candidate:sql` `status:active`
- **Предусловие:** в auth уже есть пользователь с этим телефоном.
- **Ожидание:** «Этот номер уже зарегистрирован»; аккаунт не создан; пользователь остаётся на шаге (ожидаемое развитие — уход на /login).

#### REG-PIN-04 · UNHAPPY · Аккаунт создан, автологин не прошёл
`layer:ui` `canon:code` `impl:src/pages/registration` `auto:none` `status:active`
- **Предусловие:** register прошёл, signIn вернул ошибку.
- **Ожидание:** toast «Аккаунт создан — войдите через /login»; перехода на выбор роли нет.

#### REG-PIN-05 · UNHAPPY · Сетевая ошибка
`layer:ui` `canon:code` `impl:src/pages/registration` `auto:none` `status:active`
- **Ожидание:** toast «Ошибка сети — проверьте соединение»; состояние формы сохранено.

#### REG-PIN-06 · EDGE · PIN не персистится в черновике
`layer:ui` `canon:code` `impl:src/pages/registration` `auto:candidate:unit` `status:active`
- **Шаги:** обновить страницу после создания PIN.
- **Ожидание:** в sessionStorage (`agos_reg_form`) нет `password`/`verification_id` — чувствительные поля исключены из сохранения.

---

## REG-ROLE / REG-DET — роль и детали

#### REG-ROLE-01 · HAPPY · Выбор роли
`layer:ui` `canon:code` `impl:src/pages/registration` `auto:none` `status:active`
- **Шаги:** выбрать одну из 5 ролей (Фермер / МПК / Сервисная / Кормопроизводитель / Эксперт).
- **Ожидание:** бенефит-экран роли → форма деталей роли; от роли зависят поля и итоговый org_type (farmer/mpk/supplier/supplier/consultant — маппинг IDENTITY-07/REG-EXPERT-01).

#### REG-ROLE-02 · EDGE · Тип с обязательным одобрением (канон)
`layer:rpc` `canon:MS1-D-IDM-7` `impl:—` `auto:none` `status:blocked:IDENTITY-06`
- **Канон:** mpk/education_provider/government имеют `requires_approval=true` → создаётся OrganizationTypeApplication (submitted→under_review→approved|rejected), тип активен только после одобрения; farmer/service_provider — self-service, активны сразу.
- **Код:** requires_approval нет, все типы активны сразу. Прогонять после закрытия IDENTITY-06.

#### REG-DET-01 · HAPPY · Детали фермера — happy
`layer:ui` `canon:code` `impl:src/pages/registration` `auto:none` `status:active`
- **Шаги:** название хозяйства, размер поголовья, область (+район, если у области есть районы); опционально БИН (12 цифр), правовая форма, порода, готовность к продаже → «Далее».
- **Ожидание:** валидация проходит; переход на «Согласия».

#### REG-DET-02 · UNHAPPY · Фермер: пустое название
`layer:ui` `canon:code` `impl:src/pages/registration` `auto:none` `status:active`
- **Ожидание:** «Введите название хозяйства»; переход блокируется.

#### REG-DET-03 · UNHAPPY · Фермер: БИН ≠ 12 цифр
`layer:ui` `canon:code` `impl:src/pages/registration` `auto:candidate:unit` `status:active`
- **Ожидание:** «БИН/ИИН должен содержать 12 цифр»; поле принимает только цифры, максимум 12.

#### REG-DET-04 · UNHAPPY · Фермер: нет поголовья/области/района
`layer:ui` `canon:code` `impl:src/pages/registration` `auto:none` `status:active`
- **Ожидание:** «Укажите размер поголовья» / «Укажите область» / «Укажите район» (район обязателен только если у области есть список районов).

#### REG-DET-05 · EDGE · Смена области сбрасывает район
`layer:ui` `canon:code` `impl:src/pages/registration` `auto:none` `status:active`
- **Ожидание:** `district_id` очищен; кнопка района снова «Район *»; при пустой области кнопка района disabled («Сначала выберите область»).

#### REG-DET-06 · UNHAPPY · МПК: обязательные поля
`layer:ui` `canon:code` `impl:src/pages/registration` `auto:none` `status:active`
- **Ожидание:** «Введите название компании», «БИН должен содержать 12 цифр», «Выберите тип компании», «Укажите объём закупок».

#### REG-DET-07 · UNHAPPY · Сервисная компания: нет услуг
`layer:ui` `canon:code` `impl:src/pages/registration` `auto:none` `status:active`
- **Ожидание:** «Выберите хотя бы один вид услуг».

#### REG-DET-08 · UNHAPPY · Кормопроизводитель: нет видов кормов
`layer:ui` `canon:code` `impl:src/pages/registration` `auto:none` `status:active`
- **Ожидание:** «Выберите хотя бы один вид кормов».

#### REG-DET-09 · UNHAPPY · Эксперт: обязательные поля + шаг документов
`layer:ui` `canon:code` `impl:src/pages/registration` `auto:none` `status:active`
- **Ожидание:** «Выберите хотя бы одну специализацию», «Укажите опыт», «Укажите регион»; после деталей — дополнительный шаг документов (ExpertDocs). Канон-примечание: по MS1 D-IDM-8 эксперт = атрибут User, орг-типа expert нет; код маппит expert→consultant (REG-EXPERT-01, backend CHECK не расширен).

---

## REG-SUB — согласия и сабмит

#### REG-SUB-01 · UNHAPPY · Согласия не отмечены
`layer:ui` `canon:code` `impl:src/pages/registration` `auto:none` `status:active`
- **Ожидание:** «Необходимо согласие» у обоих чекбоксов (условия + обработка данных); RPC не вызывается.

#### REG-SUB-02 · HAPPY · Сводка на шаге согласий
`layer:ui` `canon:code` `impl:src/pages/registration` `auto:none` `status:active`
- **Ожидание:** имя, телефон +7 (XXX) XXX-XX-XX; фермер — хозяйство/БИН/поголовье; МПК — компания/БИН/тип/объём.

#### REG-SUB-03 · HAPPY · Финальный сабмит
`layer:ui+rpc` `canon:code` `impl:d01_kernel.sql:rpc_register_organization` `auto:candidate:sql` `status:active`
- **Ожидание:** `rpc_register_organization` (org_type по маппингу, phone +7…, role_data + full_name + how_heard); `auth.updateUser` пишет full_name (и legal_form фермера) в метаданные; `users.full_name` дописан по auth_id; sessionStorage очищен; редирект mpk → /mpk, остальные → /cabinet. Заявка на членство автоматически НЕ подаётся — организация «не член».

#### REG-SUB-04 · UNHAPPY · Дубликат БИН
`layer:rpc` `canon:MS1-D-IDM-3` `impl:d01_kernel.sql` `auto:candidate:sql` `status:active`
- **Предусловие:** организация с этим БИН уже есть (БИН — уникальный ключ, D-IDM-3).
- **Ожидание:** toast «Организация с таким БИН уже зарегистрирована»; форма не очищена.

#### REG-SUB-05 · UNHAPPY · Прочая ошибка RPC / сеть
`layer:ui` `canon:code` `impl:src/pages/registration` `auto:none` `status:active`
- **Ожидание:** toast с текстом ошибки или «Ошибка регистрации»; данные сохранены, повторная отправка возможна.

#### REG-SUB-06 · EDGE · Восстановление черновика
`layer:ui` `canon:code` `impl:src/pages/registration` `auto:none` `status:active`
- **Шаги:** прервать на любом шаге, обновить страницу / вернуться на /register.
- **Ожидание:** форма восстановлена из sessionStorage (кроме password/verification_id/otp-флагов — OTP заново); при закрытии вкладки после первого шага — beforeunload-предупреждение.

#### REG-SUB-07 · EDGE · Один пользователь — несколько организаций (канон)
`layer:rpc` `canon:MS1-D-IDM-2` `impl:d01_kernel.sql` `auto:candidate:sql` `status:active`
- **Канон:** User↔Organization = M:N (UserOrganizationRole); пользователь может состоять в фермерской и МПК-организации одновременно.
- **Ожидание:** повторная регистрация организации под тем же auth-пользователем не ломает первую; `rpc_get_my_context` возвращает обе; маршрутизация — см. ONB-ROUTE-03.
