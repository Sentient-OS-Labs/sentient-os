-- A one-time announcement for the 661 courtesy-only recipients upgraded by the
-- preceding migration. Its verified last original gift is the immutable cutoff:
-- later redemptions and people who already had lifetime access are not this cohort.
create table public.invite_upgrade_announcements (
    user_id uuid primary key references auth.users(id) on delete cascade,
    id uuid not null unique default gen_random_uuid(),
    upgraded_at timestamptz not null default now(),
    seen_at timestamptz,
    notification_claimed_at timestamptz
);
alter table public.invite_upgrade_announcements enable row level security;
alter table public.invite_upgrade_announcements force row level security;
revoke all on table public.invite_upgrade_announcements from public, anon, authenticated;
grant all on table public.invite_upgrade_announcements to service_role;

insert into public.invite_upgrade_announcements(user_id)
select late.user_id
from public.invite_code_late_uses late
join public.invite_redemptions redemption on redemption.recipient_id = late.user_id
join public.invite_codes invitation on invitation.id = redemption.invite_id
where public.normalize_invite_code(invitation.code) = 'FINAL_1000'
    and redemption.redeemed_at = late.first_seen_at
    and late.first_seen_at <= '2026-10-25 23:25:20.382483+00'::timestamptz
on conflict (user_id) do nothing;

-- Keep old response fields intact; old apps ignore the new optional receipt.
create or replace function public.invite_status()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare receipt jsonb; upgrade jsonb;
begin
    if auth.uid() is null then raise insufficient_privilege; end if;
    select jsonb_build_object('code', invite_code, 'recordedAt', extract(epoch from first_seen_at), 'email', email)
        into receipt from public.invite_code_late_uses where user_id = auth.uid();
    select jsonb_build_object('id', id, 'upgradedAt', extract(epoch from upgraded_at),
        'seenAt', extract(epoch from seen_at), 'notificationClaimedAt', extract(epoch from notification_claimed_at))
        into upgrade from public.invite_upgrade_announcements where user_id = auth.uid();
    return public.invite_status_before_late_use()
        || jsonb_build_object('lateUse', receipt, 'lifetimeUpgrade', upgrade);
end;
$$;
revoke all on function public.invite_status() from public, anon;
grant execute on function public.invite_status() to authenticated;

-- Atomic claim prevents repeated notifications across launches/devices. If macOS
-- cannot deliver a claimed notification, the independent in-app notice remains.
create function public.claim_invite_upgrade_notification(p_notice_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare claimed uuid;
begin
    if auth.uid() is null then raise insufficient_privilege; end if;
    update public.invite_upgrade_announcements set notification_claimed_at = now()
        where user_id = auth.uid() and id = p_notice_id
          and seen_at is null and notification_claimed_at is null
        returning id into claimed;
    return jsonb_build_object('claimed', claimed is not null);
end;
$$;
revoke all on function public.claim_invite_upgrade_notification(uuid) from public, anon;
grant execute on function public.claim_invite_upgrade_notification(uuid) to authenticated;

create function public.acknowledge_invite_upgrade(p_notice_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
    if auth.uid() is null then raise insufficient_privilege; end if;
    update public.invite_upgrade_announcements set seen_at = coalesce(seen_at, now())
        where user_id = auth.uid() and id = p_notice_id;
    if not found then return jsonb_build_object('error', 'invalid_notice'); end if;
    return public.invite_status();
end;
$$;
revoke all on function public.acknowledge_invite_upgrade(uuid) from public, anon;
grant execute on function public.acknowledge_invite_upgrade(uuid) to authenticated;
