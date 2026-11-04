# MoneyMoney-Extensions

Web-Banking-Extensions für [MoneyMoney](https://moneymoney-app.com) (macOS) für Anbieter, die MoneyMoney nicht selbst abdeckt. Alle Extensions sind rein lesend und bilden nur Daten des eigenen Zugangs ab.

| Extension | Anbieter | Abbildung | Besonderheit |
|---|---|---|---|
| [ERGO-Kundenportal](ERGO/) | ERGO / DKV – „Meine Versicherungen" (`kunde-s.ergo.de`) | ein Depot je Vertrag mit Guthaben, Fondspositionen mit ISIN | SMS-Code bei jedem Login (ERGO-Vorgabe) |
| [WIWIN](WIWIN/) | WIWIN Crowdinvesting – Kundenportal `invest.wiwin.de` (Partner Portagon) | ein Depot mit einer Position je Investition plus Verrechnungskonto | nicht für WIWINs eigene Plattform `wiwin-invest.de` |
| [DZ-Banking](DZ/) | DZ BANK AG – Firmenkundenportal `dzbanking.com` | jedes Konto einzeln: Kontokorrent mit Umsätzen, Tagesgeld; Konditionen als Vormerkung | einmalige SecureGo-Freigabe für 18 Monate Historie |

Installation, Konfiguration und Fehlersuche stehen in der README des jeweiligen Ordners.

## Installation

1. `.lua`-Datei in den Extensions-Ordner legen: *Hilfe → Datenbank im Finder zeigen → Extensions*.
2. *Konto hinzufügen → Andere* → Extension wählen, Zugangsdaten eingeben.

**Signatur.** MoneyMoney lädt nur von MRH applications signierte Extensions – oder beliebige, wenn unter *Einstellungen → Extensions* die Signaturprüfung deaktiviert ist. Eine Signatur gilt für den exakten Dateiinhalt; jede Änderung macht sie ungültig. Unsignierte Dateien werden stillschweigend ignoriert (Protokoll: `signature verification failed`). Signierung: E-Mail an `support@moneymoney.app`.

## Rechtliches

Keine Verbindung zu den Anbietern (ERGO Group AG, DKV, WIWIN GmbH, Portagon, Baader Bank, DZ BANK AG, Atruvia AG) oder zu MRH applications GmbH; Namen sind Marken ihrer Inhaber. Die Extensions nutzen die Schnittstellen, die das jeweilige Portal auch dem Browser liefert, und umgehen keine Schutzmaßnahmen – zweite Faktoren bestätigt der Nutzer selbst. Ob die Nutzungsbedingungen eines Portals automatisierte Zugriffe gestatten, prüft der Nutzer selbst. **Nutzung auf eigene Verantwortung, ohne jede Gewähr.**

## Lizenz

[CC0 1.0](LICENSE). Der Code wurde von einem KI-Assistenten (Claude, Anthropic) nach Vorgaben, Netzwerkmitschnitten und Tests des Repository-Inhabers erstellt; an rein KI-generiertem Code entsteht nach deutschem Recht und US-Praxis in der Regel kein Urheberrecht. Es wird keine Urheberschaft beansprucht und keine Namensnennung verlangt.

## Mitwirken

Issues mit DEBUG-Protokoll (ohne Zugangsdaten) sind die nützlichste Hilfe – vor allem für Vertrags-, Instrument- und Kontoarten, die der Entwicklung nicht zur Verfügung standen. Da jede Codeänderung eine neue Signatur braucht, sind gesammelte Änderungen praktischer als viele kleine.
