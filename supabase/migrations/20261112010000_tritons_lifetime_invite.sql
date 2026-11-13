-- Register TRITONS as a founder-issued gift in the uncapped lifetime campaign.
insert into public.invite_codes(campaign_id, code)
select 'launch-lifetime', 'TRITONS'
where not exists (
    select 1 from public.invite_codes existing
    where public.normalize_invite_code(existing.code) = 'TRITONS'
)
on conflict do nothing;
