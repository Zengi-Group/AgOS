# 09 — Ферма: таб + мастер профиля + план (FARM-*)

> Реальность: таб «Ферма» `src/pages/cabinet/shell/screens/FarmScreen.tsx`, мастер
> `shell/farm/wizard/*`, данные `shell/farm/data/farm-profile.ts`.
> Канон: `Docs/AGOS-Dok6-Slice7-Farm-Wizard.md` (экраны/состояния),
> `Docs/AGOS-Farm-Module-FunctionalSpec-v0_1.md` (F-D11..14, порог, D78).
> Backend-контракт генерация→чтение — E2E-FARM-01 (08-backend-e2e.md).
> Требуют seed-аккаунт фермера (см. README §4a предпосылки) — без него SKIP.

---

## FARM-TAB — состояния таба «Ферма»

#### FARM-TAB-01 · HAPPY · SCR-F0a: профиль пуст → хук
`layer:ui` `canon:Slice7-SCR-F0a` `impl:src/pages/cabinet/shell/screens/FarmScreen.tsx` `auto:none` `status:active`
- **Предусловие:** фермер без herd_groups и без плана.
- **Ожидание:** hero «Расскажите, кто у вас в стаде» + CTA «Рассказать про стадо» + подпись «≈ 3 минуты…»; никаких fake-данных.

#### FARM-TAB-02 · HAPPY · SCR-F0b: состав есть, плана нет → resume
`layer:ui` `canon:Slice7-SCR-F0b` `impl:src/pages/cabinet/shell/screens/FarmScreen.tsx` `auto:none` `status:active`
- **Предусловие:** herd_groups с головами, плана нет.
- **Ожидание:** eyebrow «ВАШЕ СТАДО · N ГОЛОВ», сводка категорий (числа mk-mono), resume-CTA «Ещё N вопросов — план работ» (точное N по ветке) либо note для finishing; link «Поправить состав стада».

#### FARM-TAB-03 · HAPPY · State C: план есть → показ плана (ARS-215)
`layer:ui` `canon:Slice7-StateC` `impl:src/pages/cabinet/shell/screens/FarmScreen.tsx` `auto:none` `status:active`
- **Предусловие:** draft-ЦТК сгенерирован (E2E-FARM-01 без rollback / через мастер).
- **Ожидание:** eyebrow «ПЛАН РАБОТ НА ГОД»; карточка плана: имя, период (mono), чип «Черновик» (только draft); список фаз по start_date — название, даты + счётчик задач (mono), чип статуса (амбер только у active); ниже сводка стада + «Поправить состав». Без runtime-ошибок (регресс FARM-01/FARM-01-bis).
- **Edge (R4):** план без фаз (combined-шаблон пуст) → вместо списка note «Работы по месяцам появятся здесь…», не пустой бокс.

#### FARM-TAB-04 · HAPPY · SCR-F8: финал мастера «план готов» (ARS-215)
`layer:ui` `canon:Slice7-SCR-F8` `impl:src/pages/cabinet/shell/farm/wizard/FwResult.tsx` `auto:none` `status:active`
- **Предусловие:** мастер пройден с порогом (маточное>0 + ответ про отёл), генерация вернула `generated:true`.
- **Ожидание:** F6-лоадер (≥2.2 с, ротация фраз) → F8: иконка calendar tone-green, «План работ на год готов», ЕДИНСТВЕННЫЙ CTA «Посмотреть план» (без link «Ответить сейчас», R-14) → выход на таб «Ферма» = state C.
- **Unhappy:** генерация упала/недоступна/ниже порога → F7 «Стадо записано» (как раньше, D-FW-5); зависание RPC >10 с → хард-кап → F7.
