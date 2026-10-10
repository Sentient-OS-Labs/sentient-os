-- Curated YC reference data is separate from addresses submitted to onboarding.
-- Only explicitly published company display content is reachable through the resolver.
-- This migration imports no Bookface records and creates no Auth identities.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '30s';

create table public.yc_companies (
    id uuid primary key default gen_random_uuid(),
    source_id text unique not null check (length(source_id) between 1 and 100),
    name text not null check (length(name) between 1 and 100 and name = btrim(name) and name !~ '[[:cntrl:]]'),
    website text not null check (website ~ '^https://[^[:space:]]+$'),
    source_url text not null check (source_url ~ '^https://[^[:space:]]+$'),
    welcome_line text not null check (length(welcome_line) between 1 and 180
        and welcome_line = btrim(welcome_line) and welcome_line !~ '[[:cntrl:]]'),
    logo_path text check (length(logo_path) <= 180 and logo_path ~ '^[a-zA-Z0-9_-]+/[a-zA-Z0-9_-]+\.(png|jpg|webp)$'),
    content_version integer not null default 1 check (content_version > 0),
    published boolean not null default false,
    reviewed_at timestamptz,
    retrieved_at timestamptz not null default now(),
    check (not published or reviewed_at is not null)
);

create table public.yc_company_domains (
    domain text primary key check (
        length(domain) between 4 and 253 and domain = lower(btrim(domain))
        and domain ~ '^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$'
        and domain <> all(array['gmail.com','googlemail.com','outlook.com','hotmail.com','live.com','msn.com',
            'icloud.com','me.com','mac.com','yahoo.com','ymail.com','aol.com','proton.me','protonmail.com',
            'pm.me','hey.com','fastmail.com','mail.com'])
    ),
    company_id uuid not null references public.yc_companies(id) on delete cascade,
    reviewed_at timestamptz not null,
    source_url text not null check (source_url ~ '^https://[^[:space:]]+$')
);
create index yc_company_domains_company on public.yc_company_domains(company_id);

create table public.yc_founders (
    id uuid primary key default gen_random_uuid(),
    source_id text unique not null check (length(source_id) between 1 and 100),
    first_name text not null check (length(first_name) between 1 and 100),
    last_name text not null default '' check (length(last_name) <= 100),
    source_url text not null check (source_url ~ '^https://[^[:space:]]+$'),
    retrieved_at timestamptz not null default now()
);

create table public.yc_founder_companies (
    founder_id uuid not null references public.yc_founders(id) on delete cascade,
    company_id uuid not null references public.yc_companies(id) on delete cascade,
    current_founder boolean not null default true,
    primary key (founder_id, company_id)
);
create index yc_founder_companies_company on public.yc_founder_companies(company_id);

alter table public.yc_companies enable row level security;
alter table public.yc_companies force row level security;
alter table public.yc_company_domains enable row level security;
alter table public.yc_company_domains force row level security;
alter table public.yc_founders enable row level security;
alter table public.yc_founders force row level security;
alter table public.yc_founder_companies enable row level security;
alter table public.yc_founder_companies force row level security;
revoke all on public.yc_companies, public.yc_company_domains, public.yc_founders, public.yc_founder_companies
    from public, anon, authenticated;
grant select, insert, update, delete on public.yc_companies, public.yc_company_domains,
    public.yc_founders, public.yc_founder_companies to service_role;

-- Intentionally usable before sign-in: this returns ONLY public, reviewed display content.
-- It never consults a founder/contact table, records the caller, or confers an entitlement.
-- Exact equality on a primary key: no search, wildcard lookup, or directory enumeration API.
create function public.resolve_yc_company_welcome(email_domain text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
    if email_domain is null or length(email_domain) not between 4 and 253
       or email_domain <> lower(btrim(email_domain))
       or email_domain !~ '^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$'
    then return null; end if;

    return (
        select jsonb_build_object('company_name', c.name, 'welcome_line', c.welcome_line,
                                 'logo_path', c.logo_path, 'content_version', c.content_version)
        from public.yc_company_domains d
        join public.yc_companies c on c.id = d.company_id
        where d.domain = email_domain and c.published and c.reviewed_at is not null
    );
end;
$$;
revoke all on function public.resolve_yc_company_welcome(text) from public;
grant execute on function public.resolve_yc_company_welcome(text) to anon, authenticated, service_role;

-- Only vetted display assets belong here. App roles have no write policies. Paths are served
-- publicly by Storage, so neither raw directory exports nor private logos belong in this bucket.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('yc-company-logos', 'yc-company-logos', true, 1048576,
        array['image/png', 'image/jpeg', 'image/webp']);

comment on table public.yc_founders is
    'Privileged reference records from permitted sources, not app signups or verified identities.';
comment on function public.resolve_yc_company_welcome(text) is
    'Returns approved public company display content by exact domain. No founder identity or contact-list lookup.';
commit;
