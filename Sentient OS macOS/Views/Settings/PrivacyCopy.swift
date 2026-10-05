// PrivacyCopy.swift
// Shared privacy copy for onboarding, Settings, permissions, and the full in-app policy.
// Describes each feature's actual data path without making app-wide local-only promises.
// Doc: Documentation - Settings.md

import Foundation

enum PrivacyCopy {
    struct Section: Identifiable, Sendable {
        let id: String
        let title: String
        let paragraphs: [String]
    }

    static let headline = "Personal AI. Privacy at its core."
    static let summary = "On-device understanding. Your choice of AI. Knowledge you own."
    static let intro = "Sentient uses on-device inference wherever it can do the work well, keeps your knowledge in a folder on your Mac, and lets you choose the AI that puts it to work. The app and supporting infrastructure are open source."
    static let trustRibbon = "Private by design. On-device at the core."
    static let noSale = "We do not sell your personal information or share it for cross-site targeted advertising."
    static let crashReports = "Privacy-preserving technical reports that help us fix bugs, designed to exclude your files and conversations."
    static let extendedAnalytics = "Usage counts, timings, and app health through TelemetryDeck, designed to exclude your content."
    static let coreAnalytics = "Basic usage, launch/session, and install/uninstall counts remain enabled. These counts and optional, privacy-preserving crash reports help us improve this open-source app for you."
    static let fullDiskAccess = "Lets Sentient’s on-device model analyze local files, Apple Mail, notes, and selected conversations. Your chosen AI organizes the useful summaries. Double Tap’s one-time writing examples are prepared separately and are yours to inspect and edit."
    static let screenCapture = "Lets Sidekick and Double Tap understand the screen you’re asking about. Sidekick uses your selected AI. Double Tap uses its own drafting provider, including Sentient’s OpenAI API route with Zero Data Retention by default."
    static let screenFooter = "Screen context follows the AI provider you choose for each feature."
    static let voiceInput = "Privacy-focused voice input, using Apple’s on-device speech recognition where supported. Your words become a Sidekick request."
    static let frontierSummary = "Your Mac understands your local sources. Your chosen AI organizes that knowledge and helps get things done."
    static let frontierDetail = "Sentient’s on-device model prepares useful summaries from your local sources. Choose the AI that organizes your knowledge, prepares proactive suggestions, and powers Sidekick: your ChatGPT or Claude account, OpenRouter, or a compatible local model."
    static let customProvider = "Apple Mail and Apple Calendar work with your chosen model, without a ChatGPT or Claude subscription. Hosted Gmail and Google Calendar connectors use a supported subscription account. Double Tap and optional knowledge sharing have their own settings."
    static let conversationSources = "Analyzed on this Mac by Sentient’s on-device model. Your chosen AI uses the useful summaries. Double Tap’s one-time writing examples are prepared separately."
    static let emailSources = "Apple Mail and Apple Calendar are analyzed on this Mac. Other services use the connections you choose; your selected AI puts their context to work."
    static let emailRecommendation = "Email and calendar give Sentient useful context for your day. Apple Mail and Apple Calendar are analyzed on this Mac and work with your chosen AI. You can also use supported connections through your ChatGPT or Claude account. Manage your choices in Settings."
    static let overnight = "At 3 AM, Sentient can wake your Mac to analyze new local sources, update your knowledge with your chosen AI, and prepare morning suggestions. It runs while plugged in, or on battery if you’ve enabled that in the Analysis menu, with Sentient running in your menu bar."

    static let doubleTapCovered = "Low-latency drafts, covered by Sentient for our first users. OpenAI API with Zero Data Retention. No API key needed."
    static let doubleTapContext = "A screenshot of the display under your pointer, your knowledge base including selected one-time writing-style examples, and your instructions help Double Tap write an unsent draft in your voice."
    static let doubleTapInfo = "Fast replies, with privacy built in.\n\nTo keep Double Tap responsive, we use a low-latency OpenAI API route with Zero Data Retention and cover the cost for our first users. A screenshot, your knowledge base including selected one-time writing-style examples, and your instructions pass through our relay to create an unsent draft.\n\nInspect and edit your one-time writing examples in Settings → Double Tap. You can also choose your own drafting provider there, including a compatible local model. Double Tap’s provider is independent of the AI you choose for Sidekick."
    static let writingSamples = "Double Tap uses a one-time snapshot of selected examples of your own sent messages. Sentient does not continuously collect new writing-style examples from messages or emails. Inspect and edit writingstyle.md in your knowledge folder anytime; your edits are preserved."
    static let writingSources = "Setup draws from available one-to-one iMessage and WhatsApp conversations and supported connected sent email, separately from your regular analysis selections. The saved snapshot is included in Double Tap requests and optional knowledge sharing."
    static let writingSetup = "A one-time snapshot of your own sent messages helps Double Tap match your voice. You can inspect and edit it anytime in writingstyle.md, inside your knowledge folder."

    static let sharingContents = "Offer the knowledge you own to the AIs you choose, including your one-time writing examples and files you add to the knowledge folder. Sharing is optional."
    static let sharingEncryption = "Encrypted on your Mac before upload. Our open-source relay stores encrypted knowledge without persisting the decryption key, and decrypts in memory to serve authorised requests through your private link."
    static let sharingControl = "No separate Sentient login. Turn sharing off to stop syncing and request deletion of the cloud copy. The copy expires after 30 days without a sync."
    static let sharingOpenSource = "The app and sharing relay are open source, so you can inspect how they work."
    static let sharingOff = "Syncing stops and Sentient requests deletion of the cloud copy. Your knowledge stays on this Mac. Turning sharing back on reuses your private link."
    static let localKnowledge = "Your knowledge is a folder of plain Markdown files on this Mac. A compatible local AI can read it directly. Tools such as Claude Code can also use the folder with their chosen model; its processing settings still apply."

    static let reset = "Reset removes your local knowledge, summaries, and suggestions and requests deletion of the shared knowledge copy. Sentient returns to setup. Saved contact addresses and invitation or lifetime access are retained."
    static let resetConfirmation = "Your local knowledge and analysis state will be removed, and Sentient will request deletion of the shared knowledge copy. Saved contact addresses and invitation access remain. Local knowledge removal cannot be undone."
    static let uninstall = "Uninstall removes Sentient’s local knowledge, model, settings, and saved connection credentials, and requests deletion of the shared knowledge copy. Your own source files stay in place. Saved contact addresses and invitation or lifetime-access records are retained."

    static let sections: [Section] = [
        Section(id: "local", title: "Understanding starts on your Mac.", paragraphs: [
            "Sentient OS, Inc. builds personal AI around on-device understanding, knowledge you own, and your choice of AI provider.",
            "Sentient’s on-device model analyzes the local sources you enable, including files, saved screenshots, Apple Notes, iMessage, WhatsApp, Apple Mail, and Apple Calendar. It prepares useful summaries, with checks that help filter out irrelevant material and common sensitive identifiers.",
            "Your chosen AI consolidates those summaries into your knowledge base and prepares proactive suggestions. Your main knowledge base lives on your Mac. If you choose a cloud model, that provider processes the context used for this work.",
            noSale,
        ]),
        Section(id: "providers", title: "Your AI, your choice.", paragraphs: [
            "Use your own ChatGPT or Claude account, a compatible API provider such as OpenRouter, or a supported larger local model for knowledge organization, proactive intelligence, and Sidekick. Apple Mail and Calendar work without a ChatGPT or Claude subscription. Model capabilities and hardware needs depend on your setup.",
            "Sidekick uses your request, relevant knowledge, and screen or app context to carry out your task. Cloud models process this context under your chosen provider’s account settings, training choices, and retention policies. Double Tap has its own provider setting.",
            "Connected services use the connections you authorize. Direct connections keep their credentials in your Mac’s Keychain; hosted connections use your own supported AI account. You do not need to create a separate Sentient account or login.",
        ]),
        Section(id: "double-tap", title: "Fast replies, with privacy built in.", paragraphs: [
            "To keep Double Tap responsive, we use a low-latency OpenAI API route with Zero Data Retention and cover the cost for our first users. With this route, a screenshot of the display under your pointer, your knowledge base including selected one-time writing-style examples, and your instructions pass through Sentient’s relay to generate an unsent draft for you to review.",
            "Zero Data Retention excludes eligible request content from OpenAI’s retained logs and stored responses. OpenAI API content is not used for training by default. OpenAI’s data controls explain the scope and exceptions.",
            "Prefer your own setup? In Settings → Double Tap, choose OpenAI, OpenRouter, or a compatible endpoint, including Ollama or LM Studio. When that endpoint runs a compatible model on your Mac, drafting stays on your Mac. If you choose a hosted endpoint, your chosen provider’s account settings, training choices, and retention policies apply.",
        ]),
        Section(id: "writing", title: "Your voice, from a one-time snapshot.", paragraphs: [
            writingSamples,
            writingSources,
            "Examples contain your original wording and recipient or conversation context to help match your tone. Use Show writing examples in Finder in Settings → Double Tap to open the folder containing your snapshot.",
        ]),
        Section(id: "sharing", title: "Share knowledge with the AIs you choose.", paragraphs: [
            "Your knowledge is a folder of ordinary Markdown files on your Mac. Optional cloud sharing lets compatible AIs read it over MCP. Sharing is off until you enable it.",
            sharingEncryption,
            "The private link supplies the secret needed to access your knowledge. Keep it private and share it only with AIs you choose to connect. Those AIs process the knowledge under their own policies. Sharing includes the writing-style snapshot and any other files you add to your knowledge folder.",
            "The service records access times, tool names, client information, and hashed note references to show sharing activity. Turning sharing off stops syncing and requests deletion of the hosted copy and its access history. Periodic cleanup also removes them after 30 days without a sync.",
        ]),
        Section(id: "voice", title: "Privacy-focused voice input.", paragraphs: [
            "Sentient uses Apple’s on-device speech recognition where supported. When on-device recognition is unavailable, Apple’s speech service may process the audio. The resulting transcript becomes your Sidekick request and follows your chosen model’s processing settings.",
        ]),
        Section(id: "contact", title: "A direct line to the people building Sentient.", paragraphs: [
            "When you finish connecting Gmail or Outlook through a supported AI account, Sentient can save your email address so the founders can occasionally reach out to a small sample of users to ask for feedback. (We never collect your knowledge base or the contents of your tasks for product analytics. Asking you directly is how we learn what you use Sentient for.) Any feedback email will include a way to opt out.",
            "For this feedback list, we collect your email address and nothing else, ever. The list is stored in Supabase.",
            "A random installation credential lets us provide covered inference and manage usage limits. Invitations and lifetime access are recorded separately in Supabase so you keep your access.",
        ]),
        Section(id: "diagnostics", title: "Useful diagnostics, focused on the app.", paragraphs: [
            "Crash reports and extended usage analytics have separate controls in Settings → System. Both are enabled by default in release builds. They are designed to report how the app works, excluding your files, conversations, screenshots, and knowledge content.",
            "Sentry receives technical crash and error reports, app and system versions, recent diagnostic events, and a random installation identifier. Sentient scrubs common identifiers such as home-folder paths and email addresses from report text. Turning crash reports off stops Sentry reporting.",
            "TelemetryDeck receives usage counts and, with extended analytics enabled, timings, onboarding progress, and app health signals. Turning extended analytics off leaves basic usage, launch/session, and installation or uninstall counts. Generated identifiers let us recognize repeat events without asking for your name or email.",
            "These basic counts and optional, privacy-preserving crash reports help us improve this open-source app for you.",
        ]),
        Section(id: "control", title: "Your knowledge, your controls.", paragraphs: [
            "Read and edit your knowledge, change sources, choose supported models, disconnect services, and turn optional sharing off. Changes to shared notes reach the hosted copy on the next successful sync.",
            reset,
            "Uninstall also clears local connection credentials. It does not remove the retained contact list or invitation-access records. To ask about those records, request their removal, or get help with your privacy choices, contact feedback@sentient-os.ai.",
        ]),
    ]
}
