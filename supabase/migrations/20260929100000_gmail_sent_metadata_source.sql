-- Preserve the distinction between an account profile and a sending address inferred from
-- Claude Gmail metadata. This changes validation only; all ownership grants/RLS remain in force.
begin;

alter table public.connected_email_accounts
    drop constraint connected_email_accounts_reported_via_check;
alter table public.connected_email_accounts
    add constraint connected_email_accounts_reported_via_check
    check (reported_via in ('connector_profile', 'sent_mail_metadata', 'user_entered'));
alter table public.connected_email_accounts
    add constraint connected_email_accounts_sent_metadata_provider_check
    check (reported_via <> 'sent_mail_metadata' or (engine = 'claude' and provider = 'gmail'));

commit;
