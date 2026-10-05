// MailAccountCloudConfiguration.swift
// Public Supabase endpoint and publishable key. Authorization is enforced by Auth and RLS.
// Doc: Documentation - Connected Email Accounts.md

import Foundation

nonisolated enum MailAccountCloudConfiguration {
    static let url = URL(string: "https://hjqedlalhfoxwehxhton.supabase.co")!
    static let publishableKey = "sb_publishable_MFHS0LDzdAW1lGyEf1MUig_BzqObIr9"
}
