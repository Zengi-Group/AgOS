-- ARS-646 / MP-2.2 — rpc_get_mpk_profile_overview: транспортная копия.
--
-- КАНОНИЧЕСКИЙ ДОМ DDL — d01_kernel.sql. Этот файл только транспорт: порядок деплоя
-- d-файлы → supabase/migrations/, поэтому в прод ложится последним ИМЕННО ОН.
-- Правишь d01_kernel.sql и заново извлекаешь блок. ПАТЧИТЬ ЭТОТ ФАЙЛ ОТДЕЛЬНО НЕЛЬЗЯ:
-- миграция вне SQL_FILES cross_check.sh, снапшот CHECK 11 снимается с d01_kernel.sql, а
-- исполняется эта копия — правка только здесь пройдёт зелёной и уедет в прод
-- (IMPL_DEBT MIGRATION-COPY-OUTSIDE-CROSSCHECK-01, тот же класс, что L-1).
--
-- Ниже — байт-идентичная копия блока ARS-646 из d01_kernel.sql, извлечена скриптом,
-- сверена diff при сборке (не перепечатана руками — ровно то, на чём долг сработал).

-- =============================================================================
create or replace function public.rpc_get_mpk_profile_overview(
    p_organization_id uuid
)
returns jsonb
language plpgsql
security definer
stable
set search_path = public, pg_temp
as $$
declare
    v_actor_id        uuid := public.fn_current_user_id();
    v_is_admin        boolean;
    v_my_orgs         uuid[];
    v_can_review      boolean;
    v_org_found       boolean := false;
    v_mv              jsonb;
    v_membership      jsonb;
    v_verification    jsonb;
    v_is_active       boolean := false;
    v_source          text;
    v_vstatus         text;
    v_period_end      timestamptz;
    v_days_left       int;
    v_approved_at     timestamptz;
    v_pending_count   int    := 0;
    v_pending_fields  jsonb  := '[]'::jsonb;
    v_hidden_count    int    := 0;
    v_hidden_name     text;
    v_staff_active    int    := 0;
    v_admission       text;
    v_no_evidence     boolean := false;
    v_verif_tone      text;
    v_memb_tone       text;
    v_gates           jsonb;
    v_attention       jsonb  := '[]'::jsonb;
    v_reputation      jsonb;
    v_payload         jsonb;
begin
    -- M-003 / FR-005: нет пользовательской сессии — типизированный отказ одним кодом,
    -- текст подбирает клиент. Служебный вызов приходит сюда же: пути для него нет
    -- (FR-002 / M-004), и отказ он получает типизированным, а не permission denied.
    if v_actor_id is null then
        raise exception 'AUTH_REQUIRED' using errcode = '42501';
    end if;

    -- M-013 / FR-005 распространяются и на предикат владения. Первая редакция начинала
    -- защищённый блок ПОСЛЕ этих вызовов, а они читают таблицы (users, admin_roles,
    -- user_organization_roles), поэтому сбой внутри них уходил наружу сырым текстом
    -- исключения — прямо против «никогда текст SQL-исключения». Нашёл converge якоря 7.
    -- Оборачиваем ТОЛЬКО обращения к БД: сам `raise exception FORBIDDEN` обязан остаться
    -- ВНЕ обработчика, иначе `when others` превратил бы типизированный отказ доступа в
    -- OVERVIEW_READ_FAILED и сломал M-002.
    begin
        v_is_admin := public.fn_is_admin();
        v_my_orgs  := coalesce(public.fn_my_org_ids(), array[]::uuid[]);
    exception
        when others then
            raise log 'rpc_get_mpk_profile_overview(%) predicate failed: % (%)',
                p_organization_id, sqlerrm, sqlstate;
            raise exception 'OVERVIEW_READ_FAILED' using errcode = 'P0001';
    end;

    -- FR-002: ровно два пути. FR-003 / M-002 / M-012: не названная, чужая и несуществующая
    -- организация дают ОДИН И ТОТ ЖЕ отказ — ответ не подтверждает существование чужой
    -- организации. Отказ на несуществующую поднимается ниже, за пределами блока чтения.
    if p_organization_id is null
       or not (p_organization_id = any(v_my_orgs) or v_is_admin) then
        raise exception 'FORBIDDEN: not a member of organization %', p_organization_id
            using errcode = '42501';
    end if;

    -- Единственное право, которое что-то гейтит на этом экране: кнопку «Оценить» у пункта
    -- hidden_review. Остальные восемь МПК-прав каталога сюда не кладутся — они ничего на
    -- «Обзоре» не решают, а payload обязан быть ограниченным (FR-001).
    -- БЕЗ дизъюнкта `v_is_admin or`: первая редакция его имела, converge якоря 7 назвал это
    -- unrequested и был прав по существу — обещание оказалось бы ЛОЖНЫМ. Право гейтит
    -- кнопку, за которой стоит rpc_submit_deal_review, а тот требует членства
    -- (fn_my_org_ids) и участия в сделке, поэтому админу-не-участнику он откажет. Сказать
    -- ему «можешь оценить» значило бы соврать про действие, которого он совершить не может.
    -- Админский путь остаётся путём ДОСТУПА (FR-002), а не источником прав на мутацию.
    begin
        v_can_review := public.fn_org_has_permission(p_organization_id, 'mpk.review.submit');
    exception
        when others then
            raise log 'rpc_get_mpk_profile_overview(%) permission read failed: % (%)',
                p_organization_id, sqlerrm, sqlstate;
            raise exception 'OVERVIEW_READ_FAILED' using errcode = 'P0001';
    end;

    begin
        select exists (select 1 from public.organizations o where o.id = p_organization_id)
          into v_org_found;

        if v_org_found then
            -- P4: членство и верификация — у своего хозяина (ARS-361), не перевыводятся.
            v_mv           := public.rpc_get_org_membership_verification(p_organization_id);
            v_membership   := coalesce(v_mv -> 'membership',   '{}'::jsonb);
            v_verification := coalesce(v_mv -> 'verification', '{}'::jsonb);

            v_is_active  := coalesce((v_membership ->> 'is_active')::boolean, false);
            v_source     := coalesce(v_membership ->> 'source', 'none');
            v_vstatus    := coalesce(v_verification ->> 'status', 'not_mpk');
            v_period_end := nullif(v_membership ->> 'current_period_end', '')::timestamptz;

            -- Клампим по нулю: у истёкшей подписки конец периода в прошлом, и отрицательное
            -- число потребитель отрисовал бы как «-4 дня».
            v_days_left := case
                when v_period_end is null then null
                else greatest(0, (v_period_end::date - current_date))
            end;

            -- Дата последнего одобрения верификации — из таймлайна ARS-361, а не своим
            -- запросом к verification_records: у факта один хозяин (P4).
            -- ИМЕНА КЛЮЧЕЙ — РОВНО ТЕ, ЧТО ОТДАЁТ ХОЗЯИН: элемент timeline у ARS-361 несёт
            -- id · verification_type · result · effective_status · verified_at · expires_at.
            -- Первая редакция читала occurred_at/status — таких ключей у него НЕТ ВООБЩЕ,
            -- предикат не совпадал ни с одной строкой, и approved_at был null при любых
            -- данных. Нашло ревью якоря 7, не прогон: тест на это поле не смотрел.
            -- Берём effective_status, а не result: он уже учитывает истечение, поэтому
            -- просроченное одобрение не покажется действующей датой.
            select max(nullif(e ->> 'verified_at', '')::timestamptz)
              into v_approved_at
            from jsonb_array_elements(coalesce(v_verification -> 'timeline', '[]'::jsonb)) e
            where e ->> 'effective_status' = 'approved';

            -- M-007: правки критических полей на проверке. Отдаём имена полей, не тексты
            -- (FR-006: дом формулировок — клиент).
            select count(*)::int,
                   coalesce(jsonb_agg(distinct fr.field_name), '[]'::jsonb)
              into v_pending_count, v_pending_fields
            from public.org_field_reviews fr
            where fr.organization_id = p_organization_id
              and fr.status = 'pending';

            -- M-008: скрытый отзыв о НАШЕЙ сделке, который откроется, когда оценим мы.
            -- Атрибуция — два маршрута (см. заголовок блока), дедуп по партии.
            -- ВЛАДЕЛЕЦ ПУЛА — pools.organization_id, НЕ join через pool_requests (FR-024;
            -- FR-016 отставлен вместе с переподписью G2 09.09). Прежняя редакция ходила
            -- через pool_requests на посылке «колонки нет в каноническом файле» — посылка
            -- ЛОЖНАЯ: колонка объявлена в d02_tsp.sql ниже create table, через
            -- `alter table … add column if not exists` + бэкфилл + `set not null` + индекс,
            -- решением D-M6-OWNERSHIP, и её комментарий дословно говорит, что она заведена
            -- «чтобы проверки владельца не ходили join'ом через deprecated pool_requests».
            -- Ошибка была не косметической: pool_requests помечена DEPRECATED, канонический
            -- rpc_create_pool пишет pool_request_id = NULL, поэтому внутренний join молча
            -- отбрасывал бы все пулы, созданные штатным путём, и пункт «скрытый отзыв» у них
            -- не возникал бы НИКОГДА. Нашло ревью якоря 7; сторож против возврата — фикстура
            -- теста с пулом, у которого pool_request_id пуст.
            with our_batches as (
                select distinct a.batch_id as batch_id
                from public.batch_allocations a
                join public.pools p on p.id = a.pool_id
                where p.organization_id = p_organization_id
                  and a.status = 'delivered'
                union
                select b.id as batch_id
                from public.batches b
                join public.pool_lines pl on pl.id = b.pool_line_id
                join public.pools p       on p.id  = pl.pool_id
                where p.organization_id = p_organization_id
                  and b.status = 'delivered'
                  and not exists (
                      select 1 from public.batch_allocations x
                      where x.batch_id = b.id
                  )
            -- РОВНО ДВА УСЛОВИЯ, как в замороженном M-008: отзыв фермера скрыт И мы —
            -- вторая сторона сделки. Третьего условия («и мы сами ещё не оценили») здесь
            -- НЕТ, и это не упрощение: первая редакция его добавила, converge якоря 7
            -- назвал это contradicts, и он прав дважды. Во-первых, узкое чтение записано в
            -- §Assumptions спеки как ОПРОВЕРГАТЕЛЬ допущения, то есть код реализовывал
            -- отвергнутый вариант. Во-вторых, состояние «отзыв фермера скрыт, а наш уже
            -- есть» через канонического писателя НЕДОСТИЖИМО: rpc_submit_deal_review
            -- раскрывает пару атомарно, как только в ней две строки (d02_tsp.sql, блок
            -- v_can_reveal). То есть условие было мёртвой логикой, а тест инсценировал
            -- невозможное состояние, чтобы её проверить. Оба чтения в достижимом мире
            -- совпадают, поэтому выравнивание идёт К подписанному замыслу, а не от него.
            ), hidden as (
                select fo.legal_name as farm_name, dr.submitted_at as submitted_at
                from public.deal_reviews dr
                join our_batches ob        on ob.batch_id = dr.batch_id
                join public.batches b      on b.id  = dr.batch_id
                join public.organizations fo on fo.id = b.organization_id
                where dr.reviewer_role = 'farmer'
                  and dr.visible_at is null
            )
            select count(*)::int,
                   (array_agg(h.farm_name order by h.submitted_at asc, h.farm_name asc))[1]
              into v_hidden_count, v_hidden_name
            from hidden h;

            -- FR-018 / FR-023: единственный считаемый факт. У user_organization_roles нет
            -- is_active; приглашённые-но-не-вошедшие живут в org_invitations и в счёт не
            -- идут по конструкции.
            select count(*)::int
              into v_staff_active
            from public.user_organization_roles uor
            where uor.organization_id = p_organization_id;

            -- P4: репутация — у своего хозяина (ARS-360), публичный агрегат.
            v_reputation := public.rpc_get_mpk_reputation(p_organization_id);
        end if;
    exception
        when others then
            -- M-013 / FR-005: наружу уходит КОД, текст SQL-исключения — только в серверный
            -- лог. Обработчик один и ловит всё; отказ «не найдено» вынесен ЗА блок через
            -- флаг v_org_found, поэтому passthrough не нужен и наружу не просочится родной
            -- permission denied (тот же класс, что триаж №6 у соседа ARS-362).
            raise log 'rpc_get_mpk_profile_overview(%) read failed: % (%)',
                p_organization_id, sqlerrm, sqlstate;
            raise exception 'OVERVIEW_READ_FAILED' using errcode = 'P0001';
    end;

    -- FR-003: несуществующая организация даёт ТОТ ЖЕ отказ, что чужая. Достижимо только
    -- для админа TURAN — участник несуществующей организации отсекается предикатом выше.
    if not v_org_found then
        raise exception 'FORBIDDEN: not a member of organization %', p_organization_id
            using errcode = '42501';
    end if;

    -- Статус допуска. Гейт documents в вывод НЕ входит и это не упущение: рантайм-гейтом
    -- закупок является членство (D-BILL-TRUTH-01), документы — доказательная база
    -- верификации, не отдельный запрет. M-005 / M-011: отсутствие данных даёт unknown
    -- («статус уточняется»), НИКОГДА restricted — «нет данных» не равно «отказано».
    -- «Нет данных вовсе» отличается от «данные частичные», а ARS-361 отдаёт под оба
    -- один status = 'incomplete'. Различитель — пустота latest_by_type: без него
    -- организация, о которой TURAN ещё ничего не знает, читалась бы как «проверка идёт»,
    -- а при неактивном членстве — и вовсе как «отказано» (первый прогон теста так и упал).
    v_no_evidence := v_vstatus = 'not_mpk'
                  or coalesce(jsonb_array_length(v_verification -> 'latest_by_type'), 0) = 0;

    v_admission := case
        when v_no_evidence then 'unknown'
        when v_vstatus in ('rejected', 'expired') then 'restricted'
        when not v_is_active then 'restricted'
        when v_vstatus = 'conditional' then 'allowed_conditional'
        when v_vstatus = 'approved' then 'allowed'
        else 'pending'
    end;

    v_verif_tone := case
        when v_no_evidence then 'unknown'
        when v_vstatus in ('rejected', 'expired', 'incomplete') then 'warning'
        when v_vstatus = 'conditional' then 'info'
        when v_pending_count > 0 then 'warning'
        else 'ok'
    end;

    v_memb_tone := case
        when not v_is_active then 'warning'
        when v_days_left is not null and v_days_left <= 30 then 'warning'
        else 'ok'
    end;

    -- Комментарии держатся ВЫШЕ jsonb_build_object: внутри списка аргументов они склеиваются
    -- с ключом и ключ исчезает из снапшота CHECK 11 (CONTRACT-SNAPSHOT-DOTTED-KEYS-01).
    -- Гейт documents отдаёт ТОЛЬКО признак: счётчика «N из M» нет, читателя документов не
    -- существует, дом — ARS-363 (FR-011).
    v_gates := jsonb_build_array(
        jsonb_build_object(
            'kind', 'verification',
            'tone', v_verif_tone,
            'available', true,
            'status', v_vstatus,
            'approved_at', v_approved_at,
            'pending_field_count', v_pending_count
        ),
        jsonb_build_object(
            'kind', 'membership',
            'tone', v_memb_tone,
            'available', true,
            'is_active', v_is_active,
            'source', v_source,
            'days_left', v_days_left,
            'current_period_end', v_period_end,
            'plan_title', v_membership ->> 'plan_title',
            'cta', v_membership ->> 'cta'
        ),
        jsonb_build_object(
            'kind', 'documents',
            'available', false,
            'blocked_by', 'ARS-363'
        )
    );

    -- M-006: членство истекает. Порог 30 дней — §Assumptions спеки, запись [2026-09-09,
    -- сборка]; шкала взята из подписи гейта документов в прототипе, а не из головы. Первая
    -- редакция этого комментария ссылалась на запись, которой в спеке НЕ БЫЛО — нашёл
    -- converge якоря 7; запись дописана, ссылка стала правдой. Пункт возникает только
    -- при АКТИВНОМ членстве: неактивное несёт гейт (tone) и admission=restricted, а не
    -- пункт «истекает», и отдельного kind под это перечень не имеет (FR-007).
    if v_is_active and v_days_left is not null and v_days_left <= 30 then
        v_attention := v_attention || jsonb_build_array(jsonb_build_object(
            'kind', 'membership_expiring',
            'priority', 1,
            'tone', 'warning',
            'days_left', v_days_left,
            'current_period_end', v_period_end,
            'action', jsonb_build_object('type', 'open_admission')
        ));
    end if;

    -- M-007: правки на проверке. На закупки не влияет — это факт для клиента, он его и
    -- формулирует (FR-006); здесь только машинные поля.
    if v_pending_count > 0 then
        v_attention := v_attention || jsonb_build_array(jsonb_build_object(
            'kind', 'pending_field_review',
            'priority', 2,
            'tone', 'warning',
            'field_count', v_pending_count,
            'fields', v_pending_fields,
            'action', jsonb_build_object('type', 'open_org')
        ));
    end if;

    -- M-008: скрытый отзыв. Имя контрагента отдаётся законно — пункт возникает только по
    -- СВОЕЙ сделке в состоянии delivered, то есть после confirmed, когда раскрытие уже
    -- произошло (D-M6-5 / D-M6-12); до confirmed пункт недостижим по конструкции.
    if v_hidden_count > 0 then
        v_attention := v_attention || jsonb_build_array(jsonb_build_object(
            'kind', 'hidden_review',
            'priority', 3,
            'tone', 'info',
            'count', v_hidden_count,
            'counterparty_name', v_hidden_name,
            'action', jsonb_build_object('type', 'open_reputation')
        ));
    end if;

    -- M-009 / FR-008: пустой список внимания — это ПОСЧИТАННОЕ «чисто», отличимое от «не
    -- считалось». Поэтому attention всегда массив (возможно пустой), а не null.
    -- FR-023 / M-020: три сделочных числа — признак, а не ноль. Ноль означал бы «сделок нет»,
    -- а мы не знаем: смысл числа не определён (дом — ARS-668).
    v_payload := jsonb_build_object(
        'contract_version', 1,
        'organization_id', p_organization_id,
        'admission', jsonb_build_object(
            'status', v_admission,
            'checked_at', now(),
            'has_pending_reviews', (v_pending_count > 0)
        ),
        'gates', v_gates,
        'attention', v_attention,
        'reputation', v_reputation,
        'facts', jsonb_build_object(
            'staff_active', v_staff_active,
            'deals_closed', jsonb_build_object('available', false, 'blocked_by', 'ARS-668'),
            'heads_accepted', jsonb_build_object('available', false, 'blocked_by', 'ARS-668'),
            'supplier_orgs', jsonb_build_object('available', false, 'blocked_by', 'ARS-668')
        ),
        'permissions', jsonb_build_object(
            'mpk.review.submit', v_can_review
        )
    );

    return v_payload;
end;
$$;

comment on function public.rpc_get_mpk_profile_overview(uuid) is
    'ARS-646 / MP-2.2. Ограниченное чтение вкладки «Обзор» одним вызовом: статус допуска,
     три гейта (верификация · членство · документы-заглушка), список «требует внимания»
     кодами без текста, сводка репутации и факты. Членство/верификация берутся у ARS-361,
     репутация у ARS-360 — факты не перевыводятся (P4). Три сделочных числа отдаются
     признаком «пока не считается» с указателем на ARS-668: смысл числа не определён
     (FR-023). Два пути доступа — членство или админ TURAN; служебного пути нет, грант
     service_role сохранён ради типизированного отказа. Ничего не мутирует (FR-015).
     Контракт ответа — Dok3 RPC-64; изменение формы = правка Dok3 в том же PR
     (D-RPC-CONTRACT-SYNC-01).';

revoke execute on function public.rpc_get_mpk_profile_overview(uuid) from public, anon;
-- Грант service_role умышленный и НЕ является путём доступа (FR-002): он лишь доводит
-- служебный вызов до гейта, чтобы отказ был типизированным, а не сырой ошибкой прав
-- Postgres мимо обработчика. Проверка предиката его не пропускает — сторож M-004.
grant execute on function public.rpc_get_mpk_profile_overview(uuid) to authenticated, service_role;

insert into public.rpc_name_registry (sql_name, dok3_name, created_in, notes) values
    ('rpc_get_mpk_profile_overview', 'rpc_get_mpk_profile_overview', '20260909120000_ars_646_mpk_profile_overview.sql', 'ARS-646 MP-2.2 bounded self-read of the MPK profile overview tab (admission status, three gates, attention list as codes, reputation summary, staff count); deal counters intentionally unavailable pending ARS-668; two access paths only, no service path')
on conflict (sql_name) do update
set notes = excluded.notes,
    created_in = excluded.created_in,
    status = 'active';
