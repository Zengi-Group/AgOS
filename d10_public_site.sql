-- =============================================================================
-- d10_public_site.sql  —  Public site tables migrated from turan-industry-catalyst
-- Apply order: after d09_consulting.sql
--
-- Includes: registration_applications, news_articles, startups,
--           finance_programs, subsidy_programs (+ related tables),
--           admin RPCs for news management, storage buckets.
--
-- RLS uses public.fn_is_admin() / public.fn_is_expert() from d01_kernel.sql.
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- 0. Shared utility: updated_at trigger function
-- ─────────────────────────────────────────────────────────────────────────────

create or replace function public.update_updated_at_column()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. MEMBERSHIP APPLICATIONS
-- ─────────────────────────────────────────────────────────────────────────────

create table if not exists public.registration_applications (
  id              uuid        not null default gen_random_uuid() primary key,
  role            text        not null check (role in ('farmer', 'mpk')),
  full_name       text        not null,
  phone           text        not null,
  region          text,
  farm_name       text,
  bin_iin         text,
  herd_size       text,
  primary_breed   text,
  company_name    text,
  bin             text,
  company_type    text,
  monthly_volume  text,
  ready_to_sell   text,
  sell_count      text,
  target_breeds   text[],
  target_weight   text,
  procurement_frequency text,
  how_heard       text,
  created_at      timestamptz not null default now(),
  status          text        not null default 'pending' check (status in ('pending','approved','rejected')),
  updated_at      timestamptz,
  reviewed_by     text,
  reviewed_at     timestamptz,
  rejection_reason text,
  consent_given   boolean     not null default true
);

alter table public.registration_applications enable row level security;

-- anyone can submit (public form, no auth required)
drop policy if exists "registration_applications_insert_anon" on public.registration_applications;
create policy "registration_applications_insert_anon"
  on public.registration_applications for insert
  with check (true);

-- admins can read and manage
drop policy if exists "registration_applications_select_admin" on public.registration_applications;
create policy "registration_applications_select_admin"
  on public.registration_applications for select
  using (public.fn_is_admin());

drop policy if exists "registration_applications_update_admin" on public.registration_applications;
create policy "registration_applications_update_admin"
  on public.registration_applications for update
  using (public.fn_is_admin());

drop policy if exists "registration_applications_delete_admin" on public.registration_applications;
create policy "registration_applications_delete_admin"
  on public.registration_applications for delete
  using (public.fn_is_admin());

-- counter table
create table if not exists public.app_counters (
  id    text    primary key,
  value integer not null default 0
);

alter table public.app_counters enable row level security;

drop policy if exists "app_counters_select_anon" on public.app_counters;
create policy "app_counters_select_anon"
  on public.app_counters for select
  using (true);

drop policy if exists "app_counters_update_admin" on public.app_counters;
create policy "app_counters_update_admin"
  on public.app_counters for update
  using (public.fn_is_admin());

-- seed counter if absent
insert into public.app_counters (id, value) values ('registration_count', 0)
  on conflict (id) do nothing;

-- trigger: increment counter on every new application
create or replace function public.increment_registration_counter()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update public.app_counters set value = value + 1 where id = 'registration_count';
  return new;
end;
$$;

drop trigger if exists on_new_registration on public.registration_applications;
create trigger on_new_registration
  after insert on public.registration_applications
  for each row execute function public.increment_registration_counter();

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. NEWS ARTICLES
-- ─────────────────────────────────────────────────────────────────────────────

create table if not exists public.news_articles (
  id               uuid        not null default gen_random_uuid() primary key,
  type             text        not null default 'association'
                               check (type in ('association', 'media')),
  title            text        not null,
  slug             text        not null unique,
  summary          text,
  content          text,
  cover_image_url  text,
  author           text,
  video_url        text,
  video_type       text,
  source_name      text,
  source_url       text,
  source_logo_url  text,
  category         text        not null default 'general'
                               check (category in ('industry','standards','events','partnership','general')),
  tags             text[]      not null default '{}',
  is_published     boolean     not null default false,
  is_featured      boolean     not null default false,
  published_at     timestamptz not null default now(),
  meta_title       text,
  meta_description text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);

create index if not exists idx_news_articles_published
  on public.news_articles (is_published, published_at desc);
create index if not exists idx_news_articles_type
  on public.news_articles (type);
create index if not exists idx_news_articles_slug
  on public.news_articles (slug);

drop trigger if exists set_news_articles_updated_at on public.news_articles;
create trigger set_news_articles_updated_at
  before update on public.news_articles
  for each row execute function public.update_updated_at_column();

alter table public.news_articles enable row level security;

drop policy if exists "news_articles_select_published" on public.news_articles;
create policy "news_articles_select_published"
  on public.news_articles for select
  using (is_published = true);

drop policy if exists "news_articles_select_admin" on public.news_articles;
create policy "news_articles_select_admin"
  on public.news_articles for select
  to authenticated
  using (public.fn_is_admin() or public.fn_is_expert());

drop policy if exists "news_articles_insert_admin" on public.news_articles;
create policy "news_articles_insert_admin"
  on public.news_articles for insert
  to authenticated
  with check (public.fn_is_admin() or public.fn_is_expert());

drop policy if exists "news_articles_update_admin" on public.news_articles;
create policy "news_articles_update_admin"
  on public.news_articles for update
  to authenticated
  using (public.fn_is_admin() or public.fn_is_expert())
  with check (public.fn_is_admin() or public.fn_is_expert());

drop policy if exists "news_articles_delete_admin" on public.news_articles;
create policy "news_articles_delete_admin"
  on public.news_articles for delete
  to authenticated
  using (public.fn_is_admin());

-- Admin RPCs (SECURITY DEFINER — bypass RLS for admin operations)

create or replace function public.admin_get_news_articles(
  p_type    text default null,
  p_status  text default null,
  p_search  text default null
)
returns setof public.news_articles
language plpgsql security definer set search_path = public as $$
begin
  return query
    select * from public.news_articles
    where
      (p_type   is null or type = p_type)
      and (p_status is null
           or (p_status = 'published' and is_published = true)
           or (p_status = 'draft'     and is_published = false))
      and (p_search is null
           or title   ilike '%' || p_search || '%'
           or summary ilike '%' || p_search || '%')
    order by created_at desc;
end;
$$;

create or replace function public.admin_get_news_article(p_id uuid)
returns setof public.news_articles
language plpgsql security definer set search_path = public as $$
begin
  return query select * from public.news_articles where id = p_id limit 1;
end;
$$;

create or replace function public.admin_create_news_article(
  p_type             text,
  p_title            text,
  p_slug             text,
  p_summary          text        default null,
  p_content          text        default null,
  p_cover_image_url  text        default null,
  p_author           text        default null,
  p_video_url        text        default null,
  p_video_type       text        default null,
  p_source_name      text        default null,
  p_source_url       text        default null,
  p_source_logo_url  text        default null,
  p_category         text        default 'general',
  p_tags             text[]      default '{}',
  p_is_published     boolean     default false,
  p_is_featured      boolean     default false,
  p_published_at     timestamptz default now(),
  p_meta_title       text        default null,
  p_meta_description text        default null
)
returns public.news_articles
language plpgsql security definer set search_path = public as $$
declare v_article public.news_articles;
begin
  insert into public.news_articles (
    type, title, slug, summary, content, cover_image_url,
    author, video_url, video_type, source_name, source_url, source_logo_url,
    category, tags, is_published, is_featured, published_at,
    meta_title, meta_description
  ) values (
    p_type, p_title, p_slug, p_summary, p_content, p_cover_image_url,
    p_author, p_video_url, p_video_type, p_source_name, p_source_url, p_source_logo_url,
    p_category, p_tags, p_is_published, p_is_featured, p_published_at,
    p_meta_title, p_meta_description
  ) returning * into v_article;
  return v_article;
end;
$$;

create or replace function public.admin_update_news_article(
  p_id               uuid,
  p_title            text        default null,
  p_slug             text        default null,
  p_summary          text        default null,
  p_content          text        default null,
  p_cover_image_url  text        default null,
  p_author           text        default null,
  p_video_url        text        default null,
  p_video_type       text        default null,
  p_source_name      text        default null,
  p_source_url       text        default null,
  p_source_logo_url  text        default null,
  p_category         text        default null,
  p_tags             text[]      default null,
  p_is_published     boolean     default null,
  p_is_featured      boolean     default null,
  p_published_at     timestamptz default null,
  p_meta_title       text        default null,
  p_meta_description text        default null
)
returns public.news_articles
language plpgsql security definer set search_path = public as $$
declare v_article public.news_articles;
begin
  update public.news_articles set
    title            = coalesce(p_title,            title),
    slug             = coalesce(p_slug,             slug),
    summary          = coalesce(p_summary,          summary),
    content          = coalesce(p_content,          content),
    cover_image_url  = coalesce(p_cover_image_url,  cover_image_url),
    author           = coalesce(p_author,           author),
    video_url        = coalesce(p_video_url,        video_url),
    video_type       = coalesce(p_video_type,       video_type),
    source_name      = coalesce(p_source_name,      source_name),
    source_url       = coalesce(p_source_url,       source_url),
    source_logo_url  = coalesce(p_source_logo_url,  source_logo_url),
    category         = coalesce(p_category,         category),
    tags             = coalesce(p_tags,             tags),
    is_published     = coalesce(p_is_published,     is_published),
    is_featured      = coalesce(p_is_featured,      is_featured),
    published_at     = coalesce(p_published_at,     published_at),
    meta_title       = coalesce(p_meta_title,       meta_title),
    meta_description = coalesce(p_meta_description, meta_description)
  where id = p_id
  returning * into v_article;
  return v_article;
end;
$$;

create or replace function public.admin_delete_news_article(p_id uuid)
returns void
language plpgsql security definer set search_path = public as $$
begin
  delete from public.news_articles where id = p_id;
end;
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. STARTUPS
-- ─────────────────────────────────────────────────────────────────────────────

create table if not exists public.startups (
  id                  uuid        not null default gen_random_uuid() primary key,
  slug                text        not null unique,
  title               text        not null,
  tagline             text,
  description_problem text,
  description_solution text,
  target_market       text,
  business_model      text,
  category            text        not null default 'agritech',
  stage               text        not null default 'idea',
  funding_ask         numeric,
  funding_raised      numeric,
  funding_instrument  text,
  funding_status      text        not null default 'open',
  year_founded        integer,
  team_size           integer,
  location_region     text,
  cover_image_url     text,
  logo_url            text,
  pitch_deck_url      text,
  one_pager_url       text,
  video_url           text,
  website_url         text,
  contact_email       text,
  contact_name        text,
  contact_phone       text,
  social_links        jsonb       not null default '{}'::jsonb,
  submission_status   text        not null default 'pending_review'
                                  check (submission_status in ('pending_review','approved','rejected')),
  rejection_reason    text,
  is_published        boolean     not null default false,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

create index if not exists idx_startups_slug
  on public.startups (slug);
create index if not exists idx_startups_category
  on public.startups (category);
create index if not exists idx_startups_stage
  on public.startups (stage);
create index if not exists idx_startups_funding_status
  on public.startups (funding_status);
create index if not exists idx_startups_submission_status
  on public.startups (submission_status);

drop trigger if exists set_startups_updated_at on public.startups;
create trigger set_startups_updated_at
  before update on public.startups
  for each row execute function public.update_updated_at_column();

create table if not exists public.startup_team_members (
  id           uuid    not null default gen_random_uuid() primary key,
  startup_id   uuid    not null references public.startups(id) on delete cascade,
  name         text    not null,
  role         text,
  bio          text,
  photo_url    text,
  order_index  integer not null default 0
);

create table if not exists public.startup_use_of_funds (
  id          uuid    not null default gen_random_uuid() primary key,
  startup_id  uuid    not null references public.startups(id) on delete cascade,
  item        text    not null,
  percentage  numeric not null default 0,
  description text
);

alter table public.startups             enable row level security;
alter table public.startup_team_members enable row level security;
alter table public.startup_use_of_funds enable row level security;

-- public: read published only
drop policy if exists "startups_select_published" on public.startups;
create policy "startups_select_published"
  on public.startups for select
  using (is_published = true);

drop policy if exists "startup_team_members_select_published" on public.startup_team_members;
create policy "startup_team_members_select_published"
  on public.startup_team_members for select
  using (exists (select 1 from public.startups s where s.id = startup_id and s.is_published = true));

drop policy if exists "startup_use_of_funds_select_published" on public.startup_use_of_funds;
create policy "startup_use_of_funds_select_published"
  on public.startup_use_of_funds for select
  using (exists (select 1 from public.startups s where s.id = startup_id and s.is_published = true));

-- public submission (creates unpublished row)
drop policy if exists "startups_insert_anon" on public.startups;
create policy "startups_insert_anon"
  on public.startups for insert
  with check (is_published = false);

drop policy if exists "startup_team_members_insert_anon" on public.startup_team_members;
create policy "startup_team_members_insert_anon"
  on public.startup_team_members for insert
  with check (true);

drop policy if exists "startup_use_of_funds_insert_anon" on public.startup_use_of_funds;
create policy "startup_use_of_funds_insert_anon"
  on public.startup_use_of_funds for insert
  with check (true);

-- admin: full access
drop policy if exists "startups_all_admin" on public.startups;
create policy "startups_all_admin"
  on public.startups for all
  using (public.fn_is_admin() or public.fn_is_expert())
  with check (public.fn_is_admin() or public.fn_is_expert());

drop policy if exists "startup_team_members_all_admin" on public.startup_team_members;
create policy "startup_team_members_all_admin"
  on public.startup_team_members for all
  using (public.fn_is_admin() or public.fn_is_expert())
  with check (public.fn_is_admin() or public.fn_is_expert());

drop policy if exists "startup_use_of_funds_all_admin" on public.startup_use_of_funds;
create policy "startup_use_of_funds_all_admin"
  on public.startup_use_of_funds for all
  using (public.fn_is_admin() or public.fn_is_expert())
  with check (public.fn_is_admin() or public.fn_is_expert());

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. FINANCE PROGRAMS
-- ─────────────────────────────────────────────────────────────────────────────

create table if not exists public.finance_programs (
  id                  text        primary key,
  name_ru             text        not null,
  name_kz             text        not null default '',
  name_en             text        not null default '',
  type                text        not null default 'credit',
  description_ru      text,
  description_kz      text,
  description_en      text,
  role_in_project_ru  text,
  role_in_project_kz  text,
  when_used_ru        text,
  when_used_kz        text,
  financing_scope_ru  text,
  financing_scope_kz  text,
  limits_min          numeric     default 0,
  limits_max          numeric     default 0,
  restrictions        jsonb       not null default '[]'::jsonb,
  eligibility_rules   jsonb       not null default '[]'::jsonb,
  order_index         integer     not null default 0,
  is_active           boolean     not null default true,
  -- detail columns (added in later migration)
  provider            text        default '',
  provider_short      text        default '',
  hero_title          text        default '',
  hero_desc           text        default '',
  hero_color          text        default '#1a3d22',
  hero_badges         jsonb       default '[]'::jsonb,
  key_params          jsonb       default '[]'::jsonb,
  calc_defaults       jsonb       default '{}'::jsonb,
  info_notice         text        default '',
  eligible_items      jsonb       default '[]'::jsonb,
  not_eligible_items  jsonb       default '[]'::jsonb,
  covered_items       jsonb       default '[]'::jsonb,
  not_covered_items   jsonb       default '[]'::jsonb,
  conditions_table    jsonb       default '[]'::jsonb,
  documents_list      jsonb       default '[]'::jsonb,
  steps_list          jsonb       default '[]'::jsonb,
  faq_list            jsonb       default '[]'::jsonb,
  similar_program_ids jsonb       default '[]'::jsonb,
  created_at          timestamptz not null default now()
);

alter table public.finance_programs enable row level security;

drop policy if exists "finance_programs_select_active" on public.finance_programs;
create policy "finance_programs_select_active"
  on public.finance_programs for select
  using (is_active = true);

drop policy if exists "finance_programs_select_admin" on public.finance_programs;
create policy "finance_programs_select_admin"
  on public.finance_programs for select
  using (public.fn_is_admin() or public.fn_is_expert());

drop policy if exists "finance_programs_write_admin" on public.finance_programs;
create policy "finance_programs_write_admin"
  on public.finance_programs for all
  using (public.fn_is_admin())
  with check (public.fn_is_admin());

-- Finance Program Dependencies
create table if not exists public.finance_program_deps (
  id                    uuid  primary key default gen_random_uuid(),
  program_id            text  not null references public.finance_programs(id) on delete cascade,
  depends_on_program_id text  references public.finance_programs(id) on delete set null,
  condition             jsonb not null default '{}'::jsonb
);

alter table public.finance_program_deps enable row level security;

drop policy if exists "finance_program_deps_select_all" on public.finance_program_deps;
create policy "finance_program_deps_select_all"
  on public.finance_program_deps for select
  using (true);

drop policy if exists "finance_program_deps_write_admin" on public.finance_program_deps;
create policy "finance_program_deps_write_admin"
  on public.finance_program_deps for all
  using (public.fn_is_admin())
  with check (public.fn_is_admin());

-- Finance Projects (user-created project plans)
create table if not exists public.finance_projects (
  id                   uuid        primary key default gen_random_uuid(),
  user_id              uuid        references auth.users(id) on delete cascade,
  goal_type            text        not null default 'start_farm',
  is_agri_producer     boolean     not null default false,
  land_area            numeric     default 0,
  has_feed_base        boolean     not null default false,
  has_farm             boolean     not null default false,
  herd_size            integer     not null default 0,
  target_herd_size     integer     not null default 0,
  import_livestock     boolean     not null default false,
  need_infrastructure  boolean     not null default false,
  user_segment         text,
  status               text        not null default 'draft',
  legal_entity         text,
  bin_iin              text,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now()
);

drop trigger if exists set_finance_projects_updated_at on public.finance_projects;
create trigger set_finance_projects_updated_at
  before update on public.finance_projects
  for each row execute function public.update_updated_at_column();

alter table public.finance_projects enable row level security;

drop policy if exists "finance_projects_own" on public.finance_projects;
create policy "finance_projects_own"
  on public.finance_projects for all
  to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

drop policy if exists "finance_projects_select_admin" on public.finance_projects;
create policy "finance_projects_select_admin"
  on public.finance_projects for select
  using (public.fn_is_admin() or public.fn_is_expert());

-- Finance Project Stages
create table if not exists public.finance_project_stages (
  id          uuid        primary key default gen_random_uuid(),
  project_id  uuid        not null references public.finance_projects(id) on delete cascade,
  program_id  text        not null references public.finance_programs(id),
  status      text        not null default 'available',
  order_index integer     not null default 0,
  notes       text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

drop trigger if exists set_finance_project_stages_updated_at on public.finance_project_stages;
create trigger set_finance_project_stages_updated_at
  before update on public.finance_project_stages
  for each row execute function public.update_updated_at_column();

alter table public.finance_project_stages enable row level security;

drop policy if exists "finance_project_stages_own" on public.finance_project_stages;
create policy "finance_project_stages_own"
  on public.finance_project_stages for all
  to authenticated
  using (exists (select 1 from public.finance_projects fp where fp.id = project_id and fp.user_id = auth.uid()))
  with check (exists (select 1 from public.finance_projects fp where fp.id = project_id and fp.user_id = auth.uid()));

drop policy if exists "finance_project_stages_select_admin" on public.finance_project_stages;
create policy "finance_project_stages_select_admin"
  on public.finance_project_stages for select
  using (public.fn_is_admin() or public.fn_is_expert());

-- Finance Wizard Rules
create table if not exists public.finance_wizard_rules (
  id          uuid        primary key default gen_random_uuid(),
  program_id  text        not null references public.finance_programs(id) on delete cascade,
  field       text        not null,
  op          text        not null default 'eq',
  value       jsonb       not null default 'true'::jsonb,
  label_ru    text        not null default '',
  label_kz    text        default '',
  order_index integer     not null default 0,
  created_at  timestamptz not null default now()
);

alter table public.finance_wizard_rules enable row level security;

drop policy if exists "finance_wizard_rules_select_all" on public.finance_wizard_rules;
create policy "finance_wizard_rules_select_all"
  on public.finance_wizard_rules for select
  using (true);

drop policy if exists "finance_wizard_rules_write_admin" on public.finance_wizard_rules;
create policy "finance_wizard_rules_write_admin"
  on public.finance_wizard_rules for all
  using (public.fn_is_admin())
  with check (public.fn_is_admin());

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. SUBSIDY PROGRAMS
-- ─────────────────────────────────────────────────────────────────────────────

create table if not exists public.subsidy_programs (
  id                       text        primary key,
  category                 text        not null check (category in ('livestock','crop','investment','irrigation')),
  npa_reference            text        not null,
  reg_number               text,
  name_ru                  text        not null,
  name_kz                  text        not null default '',
  name_en                  text        not null default '',
  description_ru           text,
  description_kz           text,
  recipients_ru            text,
  okved_codes              text[]      default '{}',
  source_budget            text        default 'Местный бюджет',
  submission_platform_url  text,
  submission_platform_name text,
  submission_period        text,
  processing_days          integer,
  reimbursement_rate_text  text,
  formula_text             text,
  obligations_ru           text,
  sanctions_ru             text,
  documents                jsonb       not null default '[]'::jsonb,
  steps                    jsonb       not null default '[]'::jsonb,
  faq                      jsonb       not null default '[]'::jsonb,
  eligibility_rules        jsonb       not null default '[]'::jsonb,
  order_index              integer     not null default 0,
  is_active                boolean     not null default true,
  created_at               timestamptz not null default now()
);

create index if not exists idx_subsidy_programs_category
  on public.subsidy_programs (category);
create index if not exists idx_subsidy_programs_active
  on public.subsidy_programs (is_active) where is_active = true;

alter table public.subsidy_programs enable row level security;

drop policy if exists "subsidy_programs_select_active" on public.subsidy_programs;
create policy "subsidy_programs_select_active"
  on public.subsidy_programs for select
  using (is_active = true);

drop policy if exists "subsidy_programs_select_admin" on public.subsidy_programs;
create policy "subsidy_programs_select_admin"
  on public.subsidy_programs for select
  using (public.fn_is_admin() or public.fn_is_expert());

drop policy if exists "subsidy_programs_write_admin" on public.subsidy_programs;
create policy "subsidy_programs_write_admin"
  on public.subsidy_programs for all
  using (public.fn_is_admin())
  with check (public.fn_is_admin());

-- Subsidy Rates
create table if not exists public.subsidy_rates (
  id            uuid        primary key default gen_random_uuid(),
  subsidy_id    text        not null references public.subsidy_programs(id) on delete cascade,
  subcategory   text,
  name_ru       text        not null,
  unit          text,
  rate_kzt      numeric,
  rate_cap_pct  numeric,
  condition_ru  text,
  filters       jsonb       not null default '{}'::jsonb,
  order_index   integer     not null default 0,
  created_at    timestamptz not null default now()
);

create index if not exists idx_subsidy_rates_subsidy
  on public.subsidy_rates (subsidy_id);

alter table public.subsidy_rates enable row level security;

drop policy if exists "subsidy_rates_select_all" on public.subsidy_rates;
create policy "subsidy_rates_select_all"
  on public.subsidy_rates for select
  using (exists (select 1 from public.subsidy_programs sp where sp.id = subsidy_id and sp.is_active = true));

drop policy if exists "subsidy_rates_select_admin" on public.subsidy_rates;
create policy "subsidy_rates_select_admin"
  on public.subsidy_rates for select
  using (public.fn_is_admin() or public.fn_is_expert());

drop policy if exists "subsidy_rates_write_admin" on public.subsidy_rates;
create policy "subsidy_rates_write_admin"
  on public.subsidy_rates for all
  using (public.fn_is_admin())
  with check (public.fn_is_admin());

-- Subsidy Investment Passports
create table if not exists public.subsidy_investment_passports (
  id               text        primary key,
  subsidy_id       text        not null references public.subsidy_programs(id) on delete cascade,
  passport_number  integer     not null,
  name_ru          text        not null,
  name_kz          text        default '',
  description_ru   text,
  default_rate_pct numeric,
  order_index      integer     not null default 0,
  created_at       timestamptz not null default now()
);

create index if not exists idx_investment_passports_subsidy
  on public.subsidy_investment_passports (subsidy_id);

alter table public.subsidy_investment_passports enable row level security;

drop policy if exists "subsidy_investment_passports_select_all" on public.subsidy_investment_passports;
create policy "subsidy_investment_passports_select_all"
  on public.subsidy_investment_passports for select
  using (true);

drop policy if exists "subsidy_investment_passports_write_admin" on public.subsidy_investment_passports;
create policy "subsidy_investment_passports_write_admin"
  on public.subsidy_investment_passports for all
  using (public.fn_is_admin())
  with check (public.fn_is_admin());

-- Subsidy Investment Items
create table if not exists public.subsidy_investment_items (
  id                     uuid        primary key default gen_random_uuid(),
  passport_id            text        not null references public.subsidy_investment_passports(id) on delete cascade,
  position_code          text,
  name_ru                text        not null,
  unit                   text        default 'ед.',
  reimbursement_rate_pct numeric,
  max_cost_kzt           numeric,
  min_threshold_ru       text,
  note_ru                text,
  filters                jsonb       not null default '{}'::jsonb,
  order_index            integer     not null default 0,
  created_at             timestamptz not null default now()
);

create index if not exists idx_investment_items_passport
  on public.subsidy_investment_items (passport_id);

alter table public.subsidy_investment_items enable row level security;

drop policy if exists "subsidy_investment_items_select_all" on public.subsidy_investment_items;
create policy "subsidy_investment_items_select_all"
  on public.subsidy_investment_items for select
  using (true);

drop policy if exists "subsidy_investment_items_write_admin" on public.subsidy_investment_items;
create policy "subsidy_investment_items_write_admin"
  on public.subsidy_investment_items for all
  using (public.fn_is_admin())
  with check (public.fn_is_admin());

-- Subsidy Project Matches (cross-link with finance_projects)
create table if not exists public.subsidy_project_matches (
  id                    uuid        primary key default gen_random_uuid(),
  project_id            uuid        not null references public.finance_projects(id) on delete cascade,
  subsidy_id            text        not null references public.subsidy_programs(id),
  matched_rates         jsonb       not null default '[]'::jsonb,
  matched_items         jsonb       not null default '[]'::jsonb,
  estimated_amount_kzt  numeric,
  status                text        not null default 'suggested'
                                    check (status in ('suggested','confirmed','dismissed')),
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now()
);

create index if not exists idx_subsidy_matches_project
  on public.subsidy_project_matches (project_id);

drop trigger if exists set_subsidy_project_matches_updated_at on public.subsidy_project_matches;
create trigger set_subsidy_project_matches_updated_at
  before update on public.subsidy_project_matches
  for each row execute function public.update_updated_at_column();

alter table public.subsidy_project_matches enable row level security;

drop policy if exists "subsidy_project_matches_own" on public.subsidy_project_matches;
create policy "subsidy_project_matches_own"
  on public.subsidy_project_matches for all
  to authenticated
  using (exists (select 1 from public.finance_projects fp where fp.id = project_id and fp.user_id = auth.uid()))
  with check (exists (select 1 from public.finance_projects fp where fp.id = project_id and fp.user_id = auth.uid()));

drop policy if exists "subsidy_project_matches_select_admin" on public.subsidy_project_matches;
create policy "subsidy_project_matches_select_admin"
  on public.subsidy_project_matches for select
  using (public.fn_is_admin() or public.fn_is_expert());

-- ─────────────────────────────────────────────────────────────────────────────
-- 6. SUBSIDY GLOSSARY & CROSS-CONDITIONS
-- ─────────────────────────────────────────────────────────────────────────────

create table if not exists public.subsidy_glossary (
  id             uuid        primary key default gen_random_uuid(),
  abbreviation   text        not null unique,
  full_name_ru   text        not null,
  full_name_kz   text        default '',
  description_ru text,
  order_index    integer     not null default 0,
  created_at     timestamptz not null default now()
);

alter table public.subsidy_glossary enable row level security;

drop policy if exists "subsidy_glossary_select_all" on public.subsidy_glossary;
create policy "subsidy_glossary_select_all"
  on public.subsidy_glossary for select
  using (true);

drop policy if exists "subsidy_glossary_write_admin" on public.subsidy_glossary;
create policy "subsidy_glossary_write_admin"
  on public.subsidy_glossary for all
  using (public.fn_is_admin())
  with check (public.fn_is_admin());

create table if not exists public.subsidy_cross_conditions (
  id               uuid        primary key default gen_random_uuid(),
  condition_key    text        not null,
  label_ru         text        not null,
  crop_value       text,
  investment_value text,
  livestock_value  text,
  irrigation_value text,
  order_index      integer     not null default 0,
  created_at       timestamptz not null default now()
);

alter table public.subsidy_cross_conditions enable row level security;

drop policy if exists "subsidy_cross_conditions_select_all" on public.subsidy_cross_conditions;
create policy "subsidy_cross_conditions_select_all"
  on public.subsidy_cross_conditions for select
  using (true);

drop policy if exists "subsidy_cross_conditions_write_admin" on public.subsidy_cross_conditions;
create policy "subsidy_cross_conditions_write_admin"
  on public.subsidy_cross_conditions for all
  using (public.fn_is_admin())
  with check (public.fn_is_admin());

-- ─────────────────────────────────────────────────────────────────────────────
-- 7. STORAGE BUCKETS
-- ─────────────────────────────────────────────────────────────────────────────

insert into storage.buckets (id, name, public)
values
  ('news-covers',           'news-covers',           true),
  ('startup-decks',         'startup-decks',         false),
  ('membership-documents',  'membership-documents',  false),
  ('batch-media',           'batch-media',           false)
on conflict (id) do nothing;

-- news-covers: public read, authenticated write
drop policy if exists "news_covers_select" on storage.objects;
create policy "news_covers_select"
  on storage.objects for select
  using (bucket_id = 'news-covers');

drop policy if exists "news_covers_insert" on storage.objects;
create policy "news_covers_insert"
  on storage.objects for insert
  to authenticated
  with check (bucket_id = 'news-covers');

drop policy if exists "news_covers_delete" on storage.objects;
create policy "news_covers_delete"
  on storage.objects for delete
  to authenticated
  using (bucket_id = 'news-covers' and (public.fn_is_admin() or public.fn_is_expert()));

-- startup-decks: public upload (submission flow), admin read
drop policy if exists "startup_decks_insert" on storage.objects;
create policy "startup_decks_insert"
  on storage.objects for insert
  with check (bucket_id = 'startup-decks');

drop policy if exists "startup_decks_select_admin" on storage.objects;
create policy "startup_decks_select_admin"
  on storage.objects for select
  to authenticated
  using (bucket_id = 'startup-decks' and (public.fn_is_admin() or public.fn_is_expert()));

-- fn_storage_org_id: first path segment of a Storage object name, as uuid.
-- Fails closed (returns null, never raises) on malformed/non-uuid segments so
-- RLS predicates built on it can't be tripped into a runtime error by a bad path.
create or replace function public.fn_storage_org_id(object_name text)
returns uuid language sql immutable
set search_path = public, pg_temp as $$
    select case
        when (storage.foldername(object_name))[1] ~
             '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
        then (storage.foldername(object_name))[1]::uuid
        else null
    end;
$$;

-- membership-documents: org-scoped read/write (SEC-STORAGE-01), admin full access.
-- Path convention: membership-documents/{orgId}/... — first segment must match caller's org.
drop policy if exists "membership_documents_insert_auth" on storage.objects;
drop policy if exists "membership_documents_select_auth" on storage.objects;
drop policy if exists "membership_documents_insert_org" on storage.objects;
drop policy if exists "membership_documents_select_org" on storage.objects;
drop policy if exists "membership_documents_update_org" on storage.objects;

create policy "membership_documents_insert_org"
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'membership-documents'
    and (public.fn_is_admin() or public.fn_storage_org_id(name) = any(public.fn_my_org_ids()))
  );

drop policy if exists "membership_documents_select_org" on storage.objects;
create policy "membership_documents_select_org"
  on storage.objects for select
  to authenticated
  using (
    bucket_id = 'membership-documents'
    and (public.fn_is_admin() or public.fn_storage_org_id(name) = any(public.fn_my_org_ids()))
  );

-- upsert (used by cabinet + admin doc uploaders) does an UPDATE on replace — needs its own policy
drop policy if exists "membership_documents_update_org" on storage.objects;
create policy "membership_documents_update_org"
  on storage.objects for update
  to authenticated
  using (
    bucket_id = 'membership-documents'
    and (public.fn_is_admin() or public.fn_storage_org_id(name) = any(public.fn_my_org_ids()))
  )
  with check (
    bucket_id = 'membership-documents'
    and (public.fn_is_admin() or public.fn_storage_org_id(name) = any(public.fn_my_org_ids()))
  );

drop policy if exists "membership_documents_delete_admin" on storage.objects;
create policy "membership_documents_delete_admin"
  on storage.objects for delete
  to authenticated
  using (bucket_id = 'membership-documents' and public.fn_is_admin());

-- batch-media (ARS-227): private, org-scoped read/write/delete; admin full access.
-- Path convention: batch-media/{orgId}/{batchId}/{uuid}.{ext} — first segment = owner org.
-- Reuses fn_storage_org_id (defined above). Visibility = owner + admin only (aggregate-only,
-- Art.171); matched-MPK read is deferred to ARS-229 with correct reveal semantics (D-M6-5/12).
drop policy if exists "batch_media_insert_org" on storage.objects;
create policy "batch_media_insert_org"
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'batch-media'
    and (public.fn_is_admin() or public.fn_storage_org_id(name) = any(public.fn_my_org_ids()))
  );

drop policy if exists "batch_media_select_org" on storage.objects;
create policy "batch_media_select_org"
  on storage.objects for select
  to authenticated
  using (
    bucket_id = 'batch-media'
    and (public.fn_is_admin() or public.fn_storage_org_id(name) = any(public.fn_my_org_ids()))
  );

drop policy if exists "batch_media_update_org" on storage.objects;
create policy "batch_media_update_org"
  on storage.objects for update
  to authenticated
  using (
    bucket_id = 'batch-media'
    and (public.fn_is_admin() or public.fn_storage_org_id(name) = any(public.fn_my_org_ids()))
  )
  with check (
    bucket_id = 'batch-media'
    and (public.fn_is_admin() or public.fn_storage_org_id(name) = any(public.fn_my_org_ids()))
  );

drop policy if exists "batch_media_delete_org" on storage.objects;
create policy "batch_media_delete_org"
  on storage.objects for delete
  to authenticated
  using (
    bucket_id = 'batch-media'
    and (public.fn_is_admin() or public.fn_storage_org_id(name) = any(public.fn_my_org_ids()))
  );
