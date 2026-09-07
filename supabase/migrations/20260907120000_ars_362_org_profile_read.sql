-- ARS-362 / MP-2.1 — rpc_get_org_profile: транспортная копия.
--
-- КАНОНИЧЕСКИЙ ДОМ DDL — d01_kernel.sql. Этот файл только транспорт: порядок деплоя
-- d-файлы → supabase/migrations/, поэтому в прод ложится последним ИМЕННО ОН.
-- Правишь d01_kernel.sql и заново извлекаешь блок. ПАТЧИТЬ ЭТОТ ФАЙЛ ОТДЕЛЬНО НЕЛЬЗЯ:
-- миграция вне SQL_FILES cross_check.sh, снапшот CHECK 11 снимается с d01_kernel.sql, а
-- исполняется эта копия — правка только здесь пройдёт зелёной и уедет в прод
-- (IMPL_DEBT MIGRATION-COPY-OUTSIDE-CROSSCHECK-01, тот же класс, что L-1).
--
-- Ниже — байт-идентичная копия блока ARS-362 из d01_kernel.sql, сверена diff при сборке.

-- =============================================================================
-- ARS-362 / MP-2.1 — rpc_get_org_profile: единственное чтение вкладки «Предприятие».
-- Спека: Docs/AGOS-MPK-Profile-ReadRPC-ARS-362.md — действующие FR-001 · FR-003…FR-007 ·
-- FR-009…FR-016 · FR-018 · FR-019 / M-001…M-014. FR-002 и FR-008 в отставке 2026-09-07
-- (заменены на FR-015/FR-016 и FR-018); номер между FR-016 и FR-018 израсходован на
-- отменённую редакцию «служебный путь» и повторно не выдаётся.
-- Контракт ответа — Docs/AGOS-Dok3-RPC-Catalog-v1_5.md RPC-63 (D-RPC-CONTRACT-SYNC-01).
-- Перевыведено с нуля 2026-09-07 после переподписи G2; сборка 56631d8 снята ревертом a4dec07.
--
-- Почему SECURITY DEFINER (ADR-MPK-CONVERGENCE-01 §8 требует письменной причины):
-- mpk_profiles / mpk_sites / org_bank_accounts / org_field_reviews отозваны у роли
-- authenticated слайсом ARS-359, поэтому прямое чтение из UI невозможно. Путь definer
-- читает их, не переоткрывая гранты: мёртвые SELECT-политики остаются домом ARS-358
-- (FR-011, IMPL_DEBT MPK-PROFILE-READ-PATH-01), а не проблемой этого слайса.
--
-- ДВА ПУТИ ДОСТУПА И НИКАКИХ ДРУГИХ (FR-015): членство в запрошенной организации
-- (fn_my_org_ids) либо админ TURAN (fn_is_admin). СЛУЖЕБНОГО ПУТИ НЕТ — слагаемого
-- coalesce(auth.role(),'') = 'service_role' нет ни в гейте сессии, ни в предикате
-- владения, ни в v_bank_read, в отличие от соседа rpc_get_org_membership_verification
-- (d13_billing.sql), откуда ветка была скопирована машинально в сборке 56631d8 и убрана
-- решением владельца 2026-09-07. Грант execute у service_role при этом СОХРАНЁН: без него
-- служебный вызов падал бы сырой ошибкой прав Postgres мимо обработчика, а с ним доходит
-- до гейта и получает типизированный отказ. Сторож против возврата ветки копипастой —
-- M-014 в tests/ars_362_org_profile_read_test.sql; без него ветка вернётся тем же путём.
-- Членство доказывается подписанным клеймом app_metadata.org_ids либо запросом к базе,
-- но НИКОГДА аргументом p_organization_id (класс дефекта VET-02). Следствие, названное
-- явно: исключённый из организации сохраняет доступ до обновления токена — FR-016, долг
-- IMPL_DEBT JWT-MEMBERSHIP-STALENESS-01, дом предиката D-NEW-1, а не этот слайс.
--
-- Аддитивно (FR-007, P7): новых таблиц и колонок нет, ни одна существующая сигнатура не
-- тронута, писатели ARS-359 не тронуты, fn_my_org_ids не тронут. Ни одного индекса не
-- добавлено, и утверждение здесь точное, а не «всё нужное уже есть»: выборку по
-- организации покрывают задеплоенные ARS-359 idx_org_bank_accounts_org_current,
-- org_bank_accounts_version_unique (ведущая колонка organization_id),
-- idx_org_field_reviews_org_status, uq_mpk_sites_active_primary. ДВЕ сортировки
-- индексом НЕ покрыты — закрытые версии банка по valid_to desc и разрешённые правки по
-- reviewed_at desc: они идут сортировкой в памяти по набору, ограниченному одной
-- организацией. Спекулятивного индекса нет (HS-4), потому что набор мал по конструкции
-- (правок критических полей всего три поля, версии банка меняются редко), и замер это
-- подтверждает: p95 около 2.3 мс на фикстуре теста (28 строк банка в двух лестницах +
-- 28 правок: 3 pending и 25 разрешённых) при пороге 200 мс (FR-014). Точные цифры и
-- условия каждого прогона — в пакете G3, а не в комментарии: комментарий устаревает
-- при первой же правке фикстуры и начинает врать про замер, которого не было.
-- Появится организация с тысячами строк — индекс заводится тогда, с замером.
-- Читатель ничего не мутирует и не эмитит событий (FR-013) — держится на STABLE.
--
-- ДВЕ ЛОВУШКИ СНАПШОТА CHECK 11, обе уже стоили ложно-зелёной проверки:
--   1) IMPL_DEBT CONTRACT-SNAPSHOT-DOTTED-KEYS-01 — комментарий ВНУТРИ списка аргументов
--      jsonb_build_object склеивается с ключом, ключ молча исчезает из снапшота, а CHECK 11
--      говорит OK. Комментарии держать ВЫШЕ вызова. Ключи с точками ("mpk.profile.edit")
--      снапшот не видит вообще — их сторожат только тесты.
--   2) IMPL_DEBT CONTRACT-SNAPSHOT-TOJSONB-ROWS-01 — to_jsonb(row) не даёт снапшоту ни
--      одного ключа, поэтому пропажа iban/bik прошла бы зелёной. Строки банка и правок
--      собираются ЯВНЫМИ jsonb_build_object, а не to_jsonb: тогда денежные реквизиты
--      закреплены снапшотом, а не только глазами.
-- =============================================================================
create or replace function public.rpc_get_org_profile(
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
    v_bank_read       boolean;
    v_active_mpk      boolean := false;
    v_org_found       boolean := false;
    v_current_id      uuid;
    v_org             jsonb;
    v_profile         jsonb;
    v_primary_site    jsonb;
    v_bank_current    jsonb;
    v_bank_history    jsonb := '[]'::jsonb;
    v_bank_total      int    := 0;
    v_reviews_pending jsonb := '[]'::jsonb;
    v_reviews_recent  jsonb := '[]'::jsonb;
    v_reviews_total   int    := 0;
    v_payload         jsonb;
begin
    -- M-005 / FR-018: нет пользовательской сессии — типизированный отказ одним кодом,
    -- текст подбирает клиент. Служебный вызов приходит сюда же: пути для него нет
    -- (FR-015 / M-014), и отказ он получает типизированным, а не permission denied.
    if v_actor_id is null then
        raise exception 'AUTH_REQUIRED' using errcode = '42501';
    end if;

    v_is_admin := public.fn_is_admin();

    -- FR-015: ровно два пути. FR-003 / M-004 / M-010: не названная, чужая и несуществующая
    -- организация дают ОДИН И ТОТ ЖЕ отказ — ответ не подтверждает существование чужой
    -- организации. Отказ на несуществующую поднимается ниже, за пределами блока чтения.
    if p_organization_id is null
       or not (
           p_organization_id = any(coalesce(public.fn_my_org_ids(), array[]::uuid[]))
           or v_is_admin
       ) then
        raise exception 'FORBIDDEN: not a member of organization %', p_organization_id
            using errcode = '42501';
    end if;

    -- FR-004: банковский подблок открыт держателю mpk.bank.manage или админу — та же
    -- граница, что у задеплоенной политики org_bank_accounts_read_authorized. Без права
    -- приходит признак «доступ закрыт», а не молчаливое отсутствие блока (M-003).
    v_bank_read := v_is_admin
                or public.fn_org_has_permission(p_organization_id, 'mpk.bank.manage');

    begin
        select jsonb_build_object(
                   'id', o.id,
                   'legal_name', o.legal_name,
                   'bin_iin', o.bin_iin,
                   'legal_form', o.legal_form,
                   'region_id', o.region_id,
                   'region_name', r.name_ru,
                   'district_id', o.district_id,
                   'address_text', o.address_text,
                   'phone', o.phone,
                   'email', o.email,
                   'website', o.website,
                   'head_full_name', o.head_full_name,
                   'head_title', o.head_title,
                   'is_active', o.is_active,
                   'org_types', coalesce(
                       (select jsonb_agg(ota.org_type order by ota.org_type)
                          from public.organization_type_assignments ota
                         where ota.organization_id = o.id),
                       '[]'::jsonb
                   ),
                   'created_at', o.created_at,
                   'updated_at', o.updated_at
               )
          into v_org
          from public.organizations o
          left join public.regions r on r.id = o.region_id
         where o.id = p_organization_id;
        v_org_found := found;

        if v_org_found then
            -- Триаж №4 итерации 1: permissions — это права на ЗАПИСЬ. Писатели ARS-359
            -- сверх права требуют organizations.is_active + назначение org_type='mpk',
            -- иначе ORG_NOT_ACTIVE_MPK. Читатель обещает запись ровно там, где писатель
            -- её даст, иначе экран покажет кнопку, которую rpc_* отклонит с 42501.
            -- M-009: организация не МПК — флаги false и пустые МПК-секции, а не отказ.
            select exists (
                       select 1
                         from public.organizations o
                         join public.organization_type_assignments ota
                           on ota.organization_id = o.id
                          and ota.org_type = 'mpk'
                        where o.id = p_organization_id
                          and o.is_active
                   )
              into v_active_mpk;

            select jsonb_build_object(
                       'public_description', mp.public_description,
                       'logo_path', mp.logo_path,
                       'created_at', mp.created_at,
                       'updated_at', mp.updated_at
                   )
              into v_profile
              from public.mpk_profiles mp
             where mp.organization_id = p_organization_id;

            -- Активная первичная площадка. uq_mpk_sites_active_primary допускает не более
            -- одной такой строки на организацию, поэтому сортировка-тайбрейкер не нужна
            -- и не пишется (HS-4). Не-первичные и неактивные площадки — вне скоупа v0.1
            -- (Docs/AGOS-Dok6-Slice10-MPK-Profile.md §4.1), а не пропажа.
            select jsonb_build_object(
                       'id', s.id,
                       'site_name', s.site_name,
                       'region_id', s.region_id,
                       'region_name', sr.name_ru,
                       'address_text', s.address_text,
                       'processing_capacity_heads_per_day', s.processing_capacity_heads_per_day,
                       'phone', s.phone,
                       'email', s.email,
                       'is_primary', s.is_primary,
                       'is_active', s.is_active,
                       'created_at', s.created_at,
                       'updated_at', s.updated_at
                   )
              into v_primary_site
              from public.mpk_sites s
              left join public.regions sr on sr.id = s.region_id
             where s.organization_id = p_organization_id
               and s.is_active
               and s.is_primary
             limit 1;

            if v_bank_read then
                -- Действующая версия. Несколько ЖИВЫХ лестниц достижимо задеплоенным
                -- писателем: rpc_append_org_bank_account при p_previous_account_id = null
                -- создаёт новый logical_account_id и не закрывает существующие живые
                -- (IMPL_DEBT BANK-MULTI-LIVE-ACCOUNT-01, решение владельца 07.09 «пока
                -- скипаем»). В current попадает primary, затем самая свежая.
                select a.id
                  into v_current_id
                  from public.org_bank_accounts a
                 where a.organization_id = p_organization_id
                   and a.valid_to is null
                 order by a.is_primary desc, a.valid_from desc, a.version_no desc, a.id desc
                 limit 1;

                select jsonb_build_object(
                           'account_id', a.id,
                           'logical_account_id', a.logical_account_id,
                           'version_no', a.version_no,
                           'bank_name', a.bank_name,
                           'bik', a.bik,
                           'iban', a.iban,
                           'account_holder_name', a.account_holder_name,
                           'currency_code', a.currency_code,
                           'is_primary', a.is_primary,
                           'valid_from', a.valid_from,
                           'valid_to', a.valid_to,
                           'created_by_user_id', a.created_by_user_id,
                           'created_at', a.created_at
                       )
                  into v_bank_current
                  from public.org_bank_accounts a
                 where a.id = v_current_id;

                -- FR-019: history_total — ПОЛНОЕ число строк истории, а не отданных;
                -- иначе обрезка молчалива и на клиенте неотличима от короткой истории.
                select count(*)
                  into v_bank_total
                  from public.org_bank_accounts a
                 where a.organization_id = p_organization_id
                   and (v_current_id is null or a.id <> v_current_id);

                -- FR-019 / M-013: граница режет ТОЛЬКО закрытые версии. Общий limit по
                -- version_no desc сквозь лестницы вытолкнул бы второй ЖИВОЙ счёт из
                -- payload'а целиком — это «починка» FR-001 ценой пропажи денежных
                -- реквизитов. Живые записи, не попавшие в current, идут МИМО границы.
                -- Ключа id в строке нет (триаж №14): истории нужен только account_id.
                with rest as (
                    select a.*
                      from public.org_bank_accounts a
                     where a.organization_id = p_organization_id
                       and (v_current_id is null or a.id <> v_current_id)
                ), live as (
                    select * from rest where valid_to is null
                ), closed as (
                    -- РЕЗ и ПОРЯДОК — разные требования, и путать их нельзя.
                    -- Здесь только РЕЗ: 20 ПОСЛЕДНИХ закрытых версий (Dok3 RPC-63),
                    -- то есть по ВРЕМЕНИ закрытия. По номеру версии резать неверно:
                    -- номера нумеруются внутри лестницы (logical_account_id), и при
                    -- двух лестницах версия 1 второй, закрытая вчера, проигрывала бы
                    -- версии 6 первой, закрытой год назад, — свежая история молча
                    -- пропадала бы из ответа (FR-019 запрещает молчаливую пропажу).
                    -- ПОРЯДОК выдачи задаётся ниже, в jsonb_agg, и он по убыванию
                    -- version_no, как требует FR-006 дословно. Одно другому не мешает:
                    -- рез решает, КАКИЕ строки попадут, сортировка — в каком порядке
                    -- их показать.
                    select * from rest
                     where valid_to is not null
                     order by valid_to desc, version_no desc, id desc
                     limit 20
                ), picked as (
                    select * from live
                    union all
                    select * from closed
                )
                select coalesce(
                           jsonb_agg(
                               jsonb_build_object(
                                   'account_id', p.id,
                                   'logical_account_id', p.logical_account_id,
                                   'version_no', p.version_no,
                                   'bank_name', p.bank_name,
                                   'bik', p.bik,
                                   'iban', p.iban,
                                   'account_holder_name', p.account_holder_name,
                                   'currency_code', p.currency_code,
                                   'is_primary', p.is_primary,
                                   'valid_from', p.valid_from,
                                   'valid_to', p.valid_to,
                                   'created_by_user_id', p.created_by_user_id,
                                   'created_at', p.created_at
                               )
                               -- FR-006 дословно: история идёт ПО УБЫВАНИЮ ВЕРСИИ.
                               -- Живые записи, не попавшие в current, идут первыми:
                               -- они действующие, и прятать их в хвост по номеру
                               -- версии значило бы показать денежные реквизиты как
                               -- историю (FR-019). Внутри закрытых — строго
                               -- version_no desc, без примеси времени закрытия:
                               -- время решило, какие строки взять (CTE closed выше),
                               -- порядок решает только номер версии.
                               order by (p.valid_to is null) desc,
                                        p.version_no desc,
                                        p.valid_to desc,
                                        p.valid_from desc,
                                        p.id desc
                           ),
                           '[]'::jsonb
                       )
                  into v_bank_history
                  from picked p;
            end if;

            -- FR-006: актуальное и история приходят РАЗНЫМИ ключами. pending по
            -- конструкции <= 3 — uq_org_field_reviews_pending допускает одну pending-правку
            -- на поле, а полей три (legal_name, address_text, bin_iin), поэтому границы
            -- здесь нет. M-006: organization.bin_iin выше остаётся ПРОД-значением, а
            -- предложенное приезжает только внутри правки, с актором и временем.
            select coalesce(
                       jsonb_agg(
                           jsonb_build_object(
                               'id', fr.id,
                               'field_name', fr.field_name,
                               'previous_value', fr.previous_value,
                               'proposed_value', fr.proposed_value,
                               'status', fr.status,
                               'requested_by_user_id', fr.requested_by_user_id,
                               'requested_at', fr.requested_at
                           )
                           order by fr.requested_at desc, fr.id desc
                       ),
                       '[]'::jsonb
                   )
              into v_reviews_pending
              from public.org_field_reviews fr
             where fr.organization_id = p_organization_id
               and fr.status = 'pending';

            select count(*)
              into v_reviews_total
              from public.org_field_reviews fr
             where fr.organization_id = p_organization_id
               and fr.status in ('approved', 'rejected');

            select coalesce(
                       jsonb_agg(
                           jsonb_build_object(
                               'id', fr.id,
                               'field_name', fr.field_name,
                               'previous_value', fr.previous_value,
                               'proposed_value', fr.proposed_value,
                               'status', fr.status,
                               'requested_by_user_id', fr.requested_by_user_id,
                               'requested_at', fr.requested_at,
                               'reviewed_by_user_id', fr.reviewed_by_user_id,
                               'reviewed_at', fr.reviewed_at,
                               'review_note', fr.review_note,
                               'production_value_applied_at', fr.production_value_applied_at
                           )
                           order by fr.reviewed_at desc, fr.id desc
                       ),
                       '[]'::jsonb
                   )
              into v_reviews_recent
              from (
                   select *
                     from public.org_field_reviews
                    where organization_id = p_organization_id
                      and status in ('approved', 'rejected')
                    order by reviewed_at desc, id desc
                    limit 20
              ) fr;

            -- FR-001: один вызов на открытие вкладки — реквизиты, площадка, банк, правки
            -- на проверке и эффективные права одним ограниченным payload'ом.
            -- FR-005: contract_version — значение то же, что у соседа ARS-361 под именем
            -- version; расхождение ИМЁН зафиксировано в Implementation Notes спеки, а не
            -- устранено молча (у ARS-361 подписанный контракт — менять его отдельно, P7).
            -- FR-004 / M-003: access = 'denied' + пустые current/history, не тишина.
            -- Комментарии стоят ВЫШЕ вызова умышленно — см. ловушку 1 в шапке блока.
            v_payload := jsonb_build_object(
                'contract_version', 1,
                'organization', v_org,
                'profile', v_profile,
                'primary_site', v_primary_site,
                'bank', jsonb_build_object(
                    'access', case when v_bank_read then 'granted' else 'denied' end,
                    'current', v_bank_current,
                    'history', v_bank_history,
                    'history_total', v_bank_total
                ),
                'field_reviews', jsonb_build_object(
                    'pending', v_reviews_pending,
                    'resolved_recent', v_reviews_recent,
                    'resolved_total', v_reviews_total
                ),
                'permissions', jsonb_build_object(
                    'mpk.profile.edit',
                        v_active_mpk
                        and public.fn_org_has_permission(p_organization_id, 'mpk.profile.edit'),
                    'mpk.bank.manage',
                        v_active_mpk
                        and public.fn_org_has_permission(p_organization_id, 'mpk.bank.manage')
                )
            );
        end if;
    exception
        when others then
            -- M-011 / FR-018: наружу уходит КОД, текст SQL-исключения — только в серверный
            -- лог. Обработчик один и ловит всё: passthrough «when insufficient_privilege
            -- then raise» из сборки 56631d8 (триаж №6) выпускал наружу и родной
            -- permission denied for table, то есть ровно текст исключения. Отказ «не
            -- найдено» вынесен ЗА блок через флаг v_org_found, поэтому passthrough не нужен.
            raise log 'rpc_get_org_profile(%) read failed: % (%)',
                p_organization_id, sqlerrm, sqlstate;
            raise exception 'PROFILE_READ_FAILED' using errcode = 'P0001';
    end;

    -- FR-003: несуществующая организация даёт ТОТ ЖЕ отказ, что чужая. Достижимо только
    -- для админа TURAN — участник несуществующей организации отсекается предикатом выше.
    if not v_org_found then
        raise exception 'FORBIDDEN: not a member of organization %', p_organization_id
            using errcode = '42501';
    end if;

    return v_payload;
end;
$$;

comment on function public.rpc_get_org_profile(uuid) is
    'ARS-362 / MP-2.1. Ограниченное чтение вкладки «Предприятие» одним вызовом: организация,
     профиль, активная первичная площадка, банк по праву mpk.bank.manage (или админ),
     append-only след правок критических полей и эффективные права на запись.
     Два пути доступа — членство или админ TURAN; служебного пути нет (FR-015), грант
     service_role сохранён ради типизированного отказа. Ничего не мутирует (FR-013).
     Контракт ответа — Dok3 RPC-63; изменение формы = правка Dok3 в том же PR
     (D-RPC-CONTRACT-SYNC-01).';

revoke execute on function public.rpc_get_org_profile(uuid) from public, anon;
-- Грант service_role умышленный и НЕ является путём доступа (FR-015): он лишь доводит
-- служебный вызов до гейта, чтобы отказ был типизированным, а не сырой ошибкой прав
-- Postgres мимо обработчика. Проверка предиката его не пропускает — сторож M-014.
grant execute on function public.rpc_get_org_profile(uuid) to authenticated, service_role;

insert into public.rpc_name_registry (sql_name, dok3_name, created_in, notes) values
    ('rpc_get_org_profile', 'rpc_get_org_profile', '20260907120000_ars_362_org_profile_read.sql', 'ARS-362 MP-2.1 bounded self-read of the MPK organization profile (org/site/bank/field-reviews/permissions); two access paths only, no service path')
on conflict (sql_name) do update
set notes = excluded.notes,
    created_in = excluded.created_in,
    status = 'active';
