# AGOS — TSP Flow: микростепы и логика

Архив содержит цепочку микростепов, в рамках которых проектировался TSP-flow
(рыночная механика и UX) платформы AGOS ассоциации TURAN.

Дата сборки: 2026-06-03.

## Состав (читать в порядке M1 → M6)

| Файл | Что описывает | Статус |
|---|---|---|
| `AGOS-Microstep1-Identity-v0_2.md` | Identity: User / Organization / AssociationMembership | confirmed |
| `AGOS-Microstep2-AssociationMembership-FSM-v1_0.md` | FSM членства в ассоциации (6 состояний) | confirmed |
| `AGOS-Microstep3-FeatureGovernance-v1_0.md` | Feature Governance: FeatureGate / FeatureLimit / FeatureUsage | confirmed |
| `AGOS-Microstep4-BatchPoolOffer-v1_0.md` | **Логика TSP:** Batch / Pool / Offer — FSM, matching, ценообразование, антитраст | confirmed |
| `AGOS-Microstep6-TSPFlow-v1_0.md` | **UX Flow TSP:** полный flow фермера (M6-A) и МПК (M6-B) поверх M4 | WIP — закрыты M6-A и M6-B; остаётся M6-C (flow админа) |

## Зависимости

```
M1 Identity
  └─ M2 Membership FSM ──┐
M3 Feature Governance ───┼─ гейтит доступ к TSP
M4 TSP-логика (Batch/Pool/Offer) ── фундамент механики
        └─ M6 TSP Flow (UX поверх M4) ◄── результат текущей сессии
```

## Ключевое из M6 (этой сессии)

- Параметры TSP: offer_window 24ч, mpk_decision_window 24ч, шаг цены фикс 100 ₸/кг
  (стоп на minimum_price), matching по району, раскрытие покупателя при `confirmed`.
- Темпоральная модель: окно готовности `[ready_from, ready_to]`, спот и отложенная
  публикация — один механизм через `scheduled_publish_at`.
- Полный M6-A (фермер) и M6-B (МПК), включая контейнерную multi-category модель заявки
  МПК (общий тотал + категорийные строки, MAX опц., MIN нет).
- Двусторонние отзывы (double-blind), симметричное раскрытие личности.
- Решения D-M6-1…14. Детали и amends к M4 — внутри M6.

## Не вошло (вне рамок «микростепы + логика TSP»)

RPC-каталог (Dok3), Event Bus (Dok4), SQL (d0x_*.sql), архитектурные ADR — это
референс/имплементация, а не документы проектирования flow. M5 (онбординг) не
проектировался (отложен).
