// Offline checks of CalendarInviteText against synthetic Outlook/Teams invitation notes.
// Compile with CalendarInviteText.swift: xcrun swiftc -parse-as-library Scripts/test_calendar_invite_text.swift "Sentient OS macOS/Sources/CalendarInviteText.swift"
import Foundation

@main enum CalendarInviteTextTests {
    static func main() {
        var count = 0
        func check(_ value: Bool, _ name: String) {
            guard value else { fatalError("FAIL: \(name)") }
            count += 1
            print("PASS \(name)")
        }
        let rule = String(repeating: "_", count: 80), short = String(repeating: "_", count: 32)
        let spanish = [
            rule, "Reunión de Microsoft Teams",
            "Unirse: https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc",
            "Id. de reunión: 123 456 789 012", "Código de acceso: aB3dE9", short,
            "¿Necesita ayuda?<https://aka.ms/JoinTeamsMeeting?omkt=es-ES> | Referencia del sistema<https://teams.microsoft.com/l/meetup-join/x>",
            "Para organizadores: Opciones de reunión<https://teams.microsoft.com/meetingOptions/?organizerId=1>", rule,
        ]
        let english = [
            rule, "Microsoft Teams meeting", "Join: https://teams.microsoft.com/l/meetup-join/19%3ameeting_xyz",
            "Meeting ID: 987 654 321", "Passcode: Zx81Qa", rule,
        ]

        let after = (spanish + ["", "Revisar el avance del sprint y los riesgos del lanzamiento."]).joined(separator: "\r\n")
        check(CalendarInviteText.readable(after) == "Revisar el avance del sprint y los riesgos del lanzamiento.", "drop a leading Spanish join block and keep the agenda")

        let before = (["Agenda:", "1. Demo del prototipo", ""] + english).joined(separator: "\n")
        check(CalendarInviteText.readable(before) == "Agenda:\n1. Demo del prototipo", "drop a trailing English join block and keep the agenda")

        let cleaned = CalendarInviteText.readable(after)
        check(!cleaned.contains("aB3dE9") && !cleaned.contains("123 456"), "passcode and meeting ID never survive")
        check(!cleaned.contains("_____"), "section rules are removed with the block")

        let mention = (["Integración con Microsoft Teams: definir alcance."] + spanish).joined(separator: "\n")
        check(CalendarInviteText.readable(mention) == "Integración con Microsoft Teams: definir alcance.", "Teams mentioned outside the rules is the organizer's text")

        let plain = "Traer laptop.\nRevisar presupuesto Q2."
        check(CalendarInviteText.readable(plain) == plain, "notes without invitation structure are unchanged")

        let links = "Ver documento<https://example.com/doc?id=1> antes de la sesión."
        check(CalendarInviteText.readable(links) == "Ver documento antes de la sesión.", "Outlook link annotations keep only their label")
        check(CalendarInviteText.readable("Detalles en https://example.com/doc") == "Detalles en https://example.com/doc", "bare URLs are left to the prompt's privacy rules")

        let unrelated = [rule, "Notas del organizador sin enlace de reunión.", rule].joined(separator: "\n")
        check(CalendarInviteText.readable(unrelated) == unrelated, "rule sections without a Teams marker are kept")

        let unclosed = (["Objetivo: cierre del trimestre.", rule, "Microsoft Teams meeting", "Passcode: Zx81Qa"]).joined(separator: "\n")
        check(CalendarInviteText.readable(unclosed) == unclosed, "an unclosed section is kept; the credential preflight still sees it")

        check(CalendarInviteText.readable((spanish + english).joined(separator: "\n")).isEmpty, "invitation-only notes become empty")
        check(CalendarInviteText.readable("") == "", "empty notes stay empty")
        print("\(count) checks passed")
    }
}
