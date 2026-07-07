# 03 — Онбординг после регистрации (ONB-*)

> Реальность: экран Success + первые шаги, маршрутизация оболочек (pickShellPath),
> кабинет `src/pages/cabinet/shell/CabinetApp.tsx`, МПК-оболочка `mpk/MpkApp.tsx`.
> **Канон-примечание:** Microstep 5 (онбординг) НЕ проектировался — отложен
> (00-INDEX микростепов). Канон здесь = код + Dok6-слайсы; intent-экран /welcome
> по D-IDM-5 не построен (IDENTITY-11, deferred).
> Маппинг из концепта: E-01/E-02 → ONB-SUC/ONB-GATE; K-06 → ONB-ROUTE-03.

---

## ONB-SUC — экран Success и первые шаги

#### ONB-SUC-01 · HAPPY · Экран Success / первые шаги
`layer:ui` `canon:code` `impl:src/pages/registration` `auto:none` `status:active`
- **Деплой:** ONB-SUCCESS-ORPHAN-01 смёржен в main (PR #36, фронтенд-only) — экран подключён обратно в поток регистрации. Флаг копирайта ниже остаётся открытым (не решён).
- **Предусловие:** регистрация завершена.
- **Ожидание:** ролевые KPI-плитки (у фермера: 0 голов / 0 групп / — корма); список из 3 «первых шагов» роли; баннер «Заявка в ТУРАН · на рассмотрении. Обычно 1–3 дня»; CTA «В кабинет →» ведёт в кабинет.
- **Флаг:** баннер говорит «заявка на рассмотрении», хотя заявка автоматически НЕ подаётся (REG-SUB-03) — копирайт vs факт; проверить, не вводит ли в заблуждение (кандидат в дефект копирайта).

#### ONB-SUC-02 · EDGE · Demo-фолбэк при недоступном бэкенде
`layer:ui` `canon:code` `impl:src/pages/cabinet/shell/data` `auto:none` `status:mock`
- **Предусловие:** profile=null (бэкенд недоступен).
- **Ожидание:** кабинет открывается на seed-данных (demo-фолбэк), без падения; предупреждений пользователю нет (поведение MVP).

---

## ONB-ROUTE — маршрутизация оболочек

#### ONB-ROUTE-01 · HAPPY · Фермер попадает в /cabinet
`layer:ui` `canon:code` `impl:src/pages/auth/Login.tsx` `auto:tests/router-smoke` `status:active`
- **Ожидание:** после регистрации/входа фермер → /cabinet (v5-island Ionic оболочка, табы Главная/Рынок/…).

#### ONB-ROUTE-02 · HAPPY · МПК попадает в /mpk
`layer:ui` `canon:code` `impl:src/pages/cabinet/shell/mpk/MpkApp.tsx` `auto:candidate:browser` `status:active`
- **Ожидание:** пользователь только с mpk-организацией → /mpk (МПК-оболочка, S6/ARS-152).

#### ONB-ROUTE-03 · EDGE · Два типа организаций (farmer+mpk)
`layer:ui` `canon:MS1-D-IDM-2` `impl:src/pages/auth/Login.tsx` `auto:candidate:unit` `status:active`
- **Ожидание:** pickShellPath даёт приоритет farmer → /cabinet; профиль строится по preferType без падений.

---

## ONB-GATE — первый контакт с Рынком

#### ONB-GATE-01 · HAPPY · Новый пользователь — не член
`layer:ui` `canon:MS6-Step0;Dok6S5a` `impl:src/pages/cabinet/shell/screens/MarketScreen.tsx` `auto:none` `status:active`
- **Предусловие:** свежая регистрация фермера, членства нет.
- **Шаги:** открыть таб «Рынок».
- **Ожидание:** гейт «Продажа партий — для членов ассоциации TURAN» + список выгод + кнопка «Подать заявку на вступление»; кнопок создания партии нет (M6 Шаг 0).
