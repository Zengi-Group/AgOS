-- ============================================================
-- d08_epidemic.sql
-- AGOS · TURAN Agricultural Operating System
-- ============================================================
-- Назначение: Эпидемическая разведка — автоматическое обнаружение
--   вспышек болезней на основе порогов из epidemic_thresholds.
--
-- Закрывает: C-3 (мета-анализ §3.2 Исправление #1)
-- Зависимости: d04_vet.sql (vet_cases, vet_diagnoses, epidemic_thresholds,
--                            epidemic_signals, proactive_alerts, diseases, farms)
--              d01_kernel.sql (platform_events, fn_set_updated_at)
--
-- Два триггера, одна задача:
--   trg_vet_case_epidemic_check     — AFTER INSERT на vet_cases
--     → считает случаи по РЕГИОНУ (disease_id неизвестен при создании кейса)
--     → использует дефолтный threshold (disease_id IS NULL)
--
--   trg_vet_diagnosis_epidemic_check — AFTER INSERT на vet_diagnoses
--     → считает случаи по БОЛЕЗНИ + РЕГИОНУ (disease_id уже известен)
--     → использует специфичный threshold (disease_id = $1) или дефолтный
--
-- Почему два триггера:
--   vet_cases при INSERT не содержит disease_id (диагноз ставится позже).
--   Региональный кластер (много случаев без диагноза) тоже сигнал.
--   При постановке диагноза — точная болезнная проверка.
--
-- Принцип P8 (Standards as Data):
--   Пороги хранятся в epidemic_thresholds (не в коде).
--   Изменение порога = UPDATE в таблице, не деплой.
--
-- D62: epidemic_warning требует expert approval.
--   proactive_alert создаётся со статусом 'draft',
--   requires_expert_approval = true.
--
-- Версия: 1.0 · Март 2026 · CTO/Architect
-- ============================================================


-- ============================================================
-- ЧАСТЬ 1: fn_check_epidemic_thresholds
-- ============================================================
-- Вызывается: AFTER INSERT на vet_cases
-- Логика:
--   1. Получить region_id фермы (vet_cases.farm_id → farms.region_id)
--   2. Если region_id IS NULL — выйти (кейс без геолокации, не считаем)
--   3. Найти дефолтный threshold (disease_id IS NULL, is_active = true)
--      Приоритет: applies_to_notifiable_only = false (общий) — первый SELECT
--   4. Считать vet_cases в регионе за days_window дней
--      (через farm_id → farms WHERE region_id = v_region_id)
--   5. Если COUNT >= threshold.case_count_threshold И нет активного сигнала:
--      INSERT epidemic_signals + platform_event + proactive_alert draft
-- ============================================================

create or replace function public.fn_check_epidemic_thresholds()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_region_id         uuid;
    v_threshold         record;
    v_case_count        int;
    v_signal_id         uuid;
    v_window_start      timestamptz;
    v_first_case_date   date;
    v_last_case_date    date;
begin
    -- ── 1. Resolve region via farm ───────────────────────────────────────────
    select f.region_id
    into   v_region_id
    from   public.farms f
    where  f.id = new.farm_id;

    -- Кейс без региона: сигнал невозможен (нет географической привязки)
    if v_region_id is null then
        return new;
    end if;

    -- ── 2. Найти активный дефолтный threshold ───────────────────────────────
    -- disease_id IS NULL = применяется к любой болезни
    -- applies_to_notifiable_only = false = общий (не только для особо опасных)
    -- Если нет дефолтного — система не настроена, выходим без ошибки
    select *
    into   v_threshold
    from   public.epidemic_thresholds
    where  disease_id is null
      and  applies_to_notifiable_only = false
      and  is_active = true
    order by case_count_threshold asc   -- наименьший порог = наиболее чувствительный
    limit 1;

    if v_threshold is null then
        return new;  -- нет настроенных порогов — нормально при первом запуске
    end if;

    -- ── 3. Считать кейсы в регионе за период ────────────────────────────────
    v_window_start := now() - (v_threshold.days_window || ' days')::interval;

    select count(*)
    into   v_case_count
    from   public.vet_cases vc
    join   public.farms f on f.id = vc.farm_id
    where  f.region_id  = v_region_id
      and  vc.created_at >= v_window_start;
    -- Включаем только что вставленный кейс (триггер AFTER INSERT)

    -- ── 4. Проверить порог ────────────────────────────────────────────────
    if v_case_count < v_threshold.case_count_threshold then
        return new;  -- порог не достигнут
    end if;

    -- ── 5. Проверить дедупликацию: нет ли уже активного сигнала ─────────────
    -- «Активный» = detected или confirmed, disease_id IS NULL (общий сигнал),
    -- созданный в пределах текущего окна наблюдения
    if exists (
        select 1
        from   public.epidemic_signals es
        where  es.region_id    = v_region_id
          and  es.disease_id   is null
          and  es.status       in ('detected', 'confirmed')
          and  es.detected_at >= v_window_start
    ) then
        return new;  -- сигнал уже зарегистрирован для этого региона в этом окне
    end if;

    -- ── 6. Собрать статистику для сигнала ────────────────────────────────────
    select
        min(vc.created_at::date),
        max(vc.created_at::date)
    into v_first_case_date, v_last_case_date
    from   public.vet_cases vc
    join   public.farms f on f.id = vc.farm_id
    where  f.region_id  = v_region_id
      and  vc.created_at >= v_window_start;

    -- ── 7. Создать EpidemicSignal ─────────────────────────────────────────────
    insert into public.epidemic_signals (
        region_id,
        disease_id,
        case_count,
        time_window_days,
        first_case_date,
        last_case_date,
        threshold_id,
        severity,
        status
    ) values (
        v_region_id,
        null,                           -- disease unknown at vet_case INSERT time
        v_case_count,
        v_threshold.days_window,
        v_first_case_date,
        v_last_case_date,
        v_threshold.id,
        v_threshold.severity_level,
        'detected'
    )
    returning id into v_signal_id;

    -- ── 8. Публикация Event Bus (D66: vet.signal.detected, event #14) ─────────
    insert into public.platform_events (
        event_type, entity_type, entity_id,
        organization_id, actor_type, payload
    ) values (
        'vet.signal.detected',
        'epidemic_signal',
        v_signal_id,
        new.organization_id,
        'system',
        jsonb_build_object(
            'region_id',       v_region_id,
            'disease_id',      null,
            'case_count',      v_case_count,
            'days_window',     v_threshold.days_window,
            'severity',        v_threshold.severity_level,
            'threshold_id',    v_threshold.id,
            'trigger_source',  'vet_case_insert'
        )
    );

    -- ── 9. ProactiveAlert draft (D62: epidemic_warning = expert approval required) ──
    insert into public.proactive_alerts (
        epidemic_signal_id,
        alert_type,
        target_region_id,
        severity,
        title_ru,
        message_ru,
        requires_expert_approval,
        status
    ) values (
        v_signal_id,
        'epidemic_warning',
        v_region_id,
        v_threshold.severity_level,
        'Возможная вспышка: ' || v_case_count || ' случаев за ' ||
            v_threshold.days_window || ' дней',
        'В регионе зарегистрировано ' || v_case_count ||
            ' ветеринарных обращений за ' || v_threshold.days_window ||
            ' дней. Болезнь уточняется. Требуется внимание ветеринарного эксперта.',
        true,       -- D62: ОБЯЗАТЕЛЬНО — epidemic_warning без одобрения не уходит
        'draft'     -- ждёт подтверждения эксперта
    );

    return new;

exception when others then
    -- Никогда не блокируем INSERT vet_cases из-за ошибки в эпид-контроле
    raise warning 'fn_check_epidemic_thresholds error (non-fatal): % — vet_case_id=%',
        sqlerrm, new.id;
    return new;
end;
$$;

comment on function public.fn_check_epidemic_thresholds() is
    'C-3: Эпидемическая разведка — региональный кластер.
     Вызывается AFTER INSERT на vet_cases.
     Алгоритм: region = farm.region_id → COUNT(vet_cases в регионе за days_window).
     Порог: epidemic_thresholds WHERE disease_id IS NULL (дефолтный, P8).
     Дедупликация: не создаёт дубликат если активный сигнал уже есть (region + окно).
     При превышении: epidemic_signals INSERT + vet.signal.detected + proactive_alert draft.
     D62: proactive_alert.requires_expert_approval = true (нельзя отправить без одобрения).
     NEVER BREAKS VET_CASES INSERT: exception handler, только raise warning.';


-- ============================================================
-- ЧАСТЬ 2: fn_check_epidemic_thresholds_on_diagnosis
-- ============================================================
-- Вызывается: AFTER INSERT на vet_diagnoses (disease_id теперь известен)
-- Логика:
--   1. Если disease_id IS NULL → выйти (диагноз без конкретной болезни)
--   2. Получить region_id через vet_cases.farm_id → farms.region_id
--   3. Найти threshold: специфичный для болезни (disease_id = $1)
--      или дефолтный (disease_id IS NULL) — специфичный приоритетнее
--   4. Если болезнь is_notifiable → дополнительно проверить экстренный порог
--      (applies_to_notifiable_only = true: 1 случай за 7 дней → emergency)
--   5. Считать vet_diagnoses с этим disease_id в регионе за days_window
--   6. INSERT epidemic_signal + event + alert если порог достигнут
-- ============================================================

create or replace function public.fn_check_epidemic_thresholds_on_diagnosis()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
    v_region_id         uuid;
    v_threshold         record;
    v_case_count        int;
    v_signal_id         uuid;
    v_window_start      timestamptz;
    v_first_case_date   date;
    v_last_case_date    date;
    v_is_notifiable     boolean;
    v_disease_name      text;
    v_org_id            uuid;
begin
    -- ── 1. Пропустить диагнозы без disease_id ────────────────────────────────
    if new.disease_id is null then
        return new;
    end if;

    -- ── 2. Получить контекст кейса: region + org + признак notifiable ────────
    select
        f.region_id,
        vc.organization_id,
        d.is_notifiable,
        coalesce(d.name_ru, d.code) as disease_name
    into
        v_region_id, v_org_id, v_is_notifiable, v_disease_name
    from   public.vet_cases vc
    join   public.farms f    on f.id  = vc.farm_id
    join   public.diseases d on d.id  = new.disease_id
    where  vc.id = new.vet_case_id;

    if v_region_id is null then
        return new;  -- ферма без региона — не считаем
    end if;

    -- ── 3. Найти подходящий threshold ─────────────────────────────────────────
    -- Приоритет: специфичный для болезни > дефолтный (D91)
    -- Если болезнь особо опасная — сначала ищем applies_to_notifiable_only порог
    select *
    into   v_threshold
    from   public.epidemic_thresholds
    where  (disease_id = new.disease_id
            or (disease_id is null
                and (applies_to_notifiable_only = false
                     or (applies_to_notifiable_only = true and v_is_notifiable = true))))
      and  is_active = true
    order by
        -- Специфичный для болезни: disease_id NOT NULL → приоритет 1
        case when disease_id = new.disease_id then 0 else 1 end,
        -- Среди дефолтных: для особо опасных (applies_to_notifiable_only=true) → приоритет 2
        case when applies_to_notifiable_only = true then 0 else 1 end,
        -- Наименьший порог (самый чувствительный)
        case_count_threshold asc
    limit 1;

    if v_threshold is null then
        return new;
    end if;

    -- ── 4. Считать диагнозы с этой болезнью в регионе за период ─────────────
    v_window_start := now() - (v_threshold.days_window || ' days')::interval;

    select count(*)
    into   v_case_count
    from   public.vet_diagnoses vd
    join   public.vet_cases vc on vc.id = vd.vet_case_id
    join   public.farms f      on f.id  = vc.farm_id
    where  vd.disease_id  = new.disease_id
      and  f.region_id    = v_region_id
      and  vd.created_at >= v_window_start;

    -- ── 5. Проверить порог ─────────────────────────────────────────────────
    if v_case_count < v_threshold.case_count_threshold then
        return new;
    end if;

    -- ── 6. Дедупликация ────────────────────────────────────────────────────
    if exists (
        select 1
        from   public.epidemic_signals es
        where  es.region_id   = v_region_id
          and  es.disease_id  = new.disease_id
          and  es.status      in ('detected', 'confirmed')
          and  es.detected_at >= v_window_start
    ) then
        return new;
    end if;

    -- ── 7. Собрать статистику ──────────────────────────────────────────────
    select
        min(vd.created_at::date),
        max(vd.created_at::date)
    into v_first_case_date, v_last_case_date
    from   public.vet_diagnoses vd
    join   public.vet_cases vc on vc.id = vd.vet_case_id
    join   public.farms f      on f.id  = vc.farm_id
    where  vd.disease_id  = new.disease_id
      and  f.region_id    = v_region_id
      and  vd.created_at >= v_window_start;

    -- ── 8. Создать EpidemicSignal ────────────────────────────────────────
    insert into public.epidemic_signals (
        region_id,
        disease_id,
        case_count,
        time_window_days,
        first_case_date,
        last_case_date,
        threshold_id,
        severity,
        status
    ) values (
        v_region_id,
        new.disease_id,
        v_case_count,
        v_threshold.days_window,
        v_first_case_date,
        v_last_case_date,
        v_threshold.id,
        v_threshold.severity_level,
        'detected'
    )
    returning id into v_signal_id;

    -- ── 9. Event Bus ──────────────────────────────────────────────────────
    insert into public.platform_events (
        event_type, entity_type, entity_id,
        organization_id, actor_type, payload
    ) values (
        'vet.signal.detected',
        'epidemic_signal',
        v_signal_id,
        v_org_id,
        'system',
        jsonb_build_object(
            'region_id',       v_region_id,
            'disease_id',      new.disease_id,
            'disease_name',    v_disease_name,
            'is_notifiable',   v_is_notifiable,
            'case_count',      v_case_count,
            'days_window',     v_threshold.days_window,
            'severity',        v_threshold.severity_level,
            'threshold_id',    v_threshold.id,
            'trigger_source',  'vet_diagnosis_insert'
        )
    );

    -- ── 10. ProactiveAlert draft (D62) ────────────────────────────────────
    insert into public.proactive_alerts (
        epidemic_signal_id,
        alert_type,
        target_region_id,
        severity,
        title_ru,
        message_ru,
        requires_expert_approval,
        status
    ) values (
        v_signal_id,
        'epidemic_warning',
        v_region_id,
        v_threshold.severity_level,
        'Вспышка: ' || v_disease_name || ' (' || v_case_count || ' случаев)',
        'Зарегистрировано ' || v_case_count || ' случаев «' || v_disease_name ||
            '» за ' || v_threshold.days_window || ' дней.' ||
            case when v_is_notifiable
                then ' Особо опасная болезнь — уведомление МСХ РК обязательно.'
                else ' Требуется оценка ветеринарного эксперта.'
            end,
        true,
        'draft'
    );

    return new;

exception when others then
    raise warning 'fn_check_epidemic_thresholds_on_diagnosis error (non-fatal): % — vet_diagnosis_id=%',
        sqlerrm, new.id;
    return new;
end;
$$;

comment on function public.fn_check_epidemic_thresholds_on_diagnosis() is
    'C-3 (дополнение): Болезне-специфичная эпидемическая разведка.
     Вызывается AFTER INSERT на vet_diagnoses (disease_id теперь известен).
     Алгоритм: COUNT(vet_diagnoses с disease_id в регионе за days_window).
     Threshold: специфичный для болезни > applies_to_notifiable_only > дефолтный (P8, D91).
     Особо опасные (is_notifiable): 1 случай за 7 дней → emergency (согласно seed данным d04).
     Дедупликация: region + disease_id + окно → не создаёт дубликаты.
     D62: proactive_alert.requires_expert_approval = true.
     NEVER BREAKS VET_DIAGNOSES INSERT: exception handler, только raise warning.';


-- ============================================================
-- ЧАСТЬ 3: ТРИГГЕРЫ
-- ============================================================

-- Триггер 1: Региональный кластер (любые случаи, болезнь неизвестна)
-- AFTER INSERT — кейс уже в таблице, считаем включая новый
drop trigger if exists trg_vet_case_epidemic_check on public.vet_cases;
create trigger trg_vet_case_epidemic_check
    after insert on public.vet_cases
    for each row
    execute function public.fn_check_epidemic_thresholds();

comment on function public.fn_check_epidemic_thresholds() is
    'C-3: AFTER INSERT vet_cases.
     Региональный кластер (disease_id неизвестен при создании кейса).
     Дефолтный threshold (disease_id IS NULL).';

-- Триггер 2: Болезне-специфичный сигнал (диагноз поставлен)
drop trigger if exists trg_vet_diagnosis_epidemic_check on public.vet_diagnoses;
create trigger trg_vet_diagnosis_epidemic_check
    after insert on public.vet_diagnoses
    for each row
    execute function public.fn_check_epidemic_thresholds_on_diagnosis();


-- ============================================================
-- ЧАСТЬ 4: ИНДЕКСЫ для производительности
-- ============================================================
-- Запрос COUNT по региону + временному окну — критичный путь при каждом INSERT

-- Поиск vet_cases по region (через JOIN с farms)
-- farms.region_id уже имеет idx в d01_kernel.sql (idx_farms_region)
-- vet_cases.farm_id уже имеет idx в d04_vet.sql (idx_vc_farm)

-- Дополнительный: epidemic_signals для дедупликации (region + disease + status + time)
create index if not exists idx_es_dedup
    on public.epidemic_signals (region_id, disease_id, status, detected_at)
    where status in ('detected', 'confirmed');

-- Для подсчёта vet_diagnoses по disease + vet_case → farms (join path)
create index if not exists idx_vd_disease_created
    on public.vet_diagnoses (disease_id, created_at)
    where disease_id is not null;


-- ============================================================
-- ЧАСТЬ 5: ОБНОВЛЕНИЕ rpc_name_registry
-- ============================================================

insert into public.rpc_name_registry (
    sql_name, dok3_name, dok5_tool_name, created_in, notes
) values
    ('fn_check_epidemic_thresholds',
     null, null,
     'd08_epidemic.sql',
     'C-3: AFTER INSERT trigger on vet_cases. Regional cluster detection. Default threshold (disease_id IS NULL).'),
    ('fn_check_epidemic_thresholds_on_diagnosis',
     null, null,
     'd08_epidemic.sql',
     'C-3 supplement: AFTER INSERT trigger on vet_diagnoses. Disease-specific detection. Notifiable diseases: 1 case = emergency.')
on conflict (sql_name) do update
    set notes      = excluded.notes,
        created_in = excluded.created_in;


-- ============================================================
-- ЧАСТЬ 6: SMOKE TEST (выполнить вручную в Supabase SQL Editor)
-- ============================================================
-- Тест 1: Функции созданы
--   SELECT proname FROM pg_proc
--   WHERE proname IN (
--       'fn_check_epidemic_thresholds',
--       'fn_check_epidemic_thresholds_on_diagnosis'
--   );
--   Ожидаем: 2 строки
--
-- Тест 2: Триггеры созданы
--   SELECT tgname FROM pg_trigger
--   WHERE tgname IN (
--       'trg_vet_case_epidemic_check',
--       'trg_vet_diagnosis_epidemic_check'
--   );
--   Ожидаем: 2 строки
--
-- Тест 3: Дефолтный threshold существует
--   SELECT * FROM epidemic_thresholds
--   WHERE disease_id IS NULL AND is_active = true;
--   Ожидаем: 3 строки (из seed в d04_vet.sql)
--
-- Тест 4: Имитация превышения порога (требует тестовых данных)
--   -- Создать 3 vet_cases в одном регионе за 14 дней
--   -- → epidemic_signals должны содержать 1 запись со status='detected'
--   -- → proactive_alerts должны содержать 1 запись draft + requires_expert_approval=true
--   -- → platform_events должны содержать 1 запись с event_type='vet.signal.detected'
-- ============================================================

-- ============================================================
-- Gate 0 checklist update:
-- ✅ d08_epidemic.sql создан
-- ✅ fn_check_epidemic_thresholds — AFTER INSERT на vet_cases
-- ✅ fn_check_epidemic_thresholds_on_diagnosis — AFTER INSERT на vet_diagnoses
-- ✅ Дедупликация epidemic_signals (region + disease + окно)
-- ✅ D62: proactive_alert.requires_expert_approval = true
-- ✅ P8: пороги в epidemic_thresholds (не в коде)
-- ✅ Event Bus: vet.signal.detected при каждом новом сигнале
-- ============================================================
