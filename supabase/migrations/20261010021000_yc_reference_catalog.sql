-- Preserve the complete reference catalog, including companies without a current website.
-- A missing website is allowed only for unpublished records and never produces a welcome.
begin;
set local lock_timeout = '5s';
alter table public.yc_companies alter column website drop not null;
alter table public.yc_companies add column source_status text
    check (source_status in ('Active', 'Inactive', 'Acquired', 'Public'));
alter table public.yc_companies add constraint yc_published_company_has_website
    check (not published or website is not null);
commit;
