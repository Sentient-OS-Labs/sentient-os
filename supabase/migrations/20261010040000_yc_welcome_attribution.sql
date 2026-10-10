-- Shared public display copy is managed on the server, without embedding it in the app.
-- This table must contain only copy intended for unauthenticated onboarding visitors.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '30s';

create table public.yc_welcome_presentation (
    singleton boolean primary key default true check (singleton),
    attribution_line text not null check (length(attribution_line) between 1 and 140
        and attribution_line = btrim(attribution_line) and attribution_line !~ '[[:cntrl:]]')
);
alter table public.yc_welcome_presentation enable row level security;
alter table public.yc_welcome_presentation force row level security;
revoke all on public.yc_welcome_presentation from public, anon, authenticated;
grant select, insert, update, delete on public.yc_welcome_presentation to service_role;

-- The existing domain-only lookup includes the optional footer in the same round trip.
-- Missing presentation copy leaves company matching and older clients unchanged.
create or replace function public.resolve_yc_company_welcome(email_domain text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
    if email_domain is null or length(email_domain) not between 4 and 253
       or email_domain <> lower(btrim(email_domain))
       or email_domain !~ '^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$'
    then return null; end if;

    return (
        select jsonb_build_object('company_name', c.name, 'welcome_line', c.welcome_line,
                                 'logo_path', c.logo_path, 'content_version', c.content_version,
                                 'attribution_line', (select p.attribution_line
                                     from public.yc_welcome_presentation p where p.singleton))
        from public.yc_company_domains d
        join public.yc_companies c on c.id = d.company_id
        where d.domain = email_domain and c.published and c.reviewed_at is not null
    );
end;
$$;
revoke all on function public.resolve_yc_company_welcome(text) from public;
grant execute on function public.resolve_yc_company_welcome(text) to anon, authenticated, service_role;

comment on table public.yc_welcome_presentation is
    'Public display copy returned with matched company welcomes. Never store private contact details here.';
commit;
