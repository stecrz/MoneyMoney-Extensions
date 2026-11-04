# ERGO Kundenportal – MoneyMoney-Extension

Web-Banking-Extension für [MoneyMoney](https://moneymoney-app.com) (macOS), die Verträge aus dem ERGO-Kundenportal **„Meine Versicherungen"** (`kunde-s.ergo.de`) als Depots abbildet. Deckt ERGO- und DKV-Verträge ab.

Für jeden Vertrag mit bezifferbarem Wert legt die Extension ein Depot an:

- **Fondsgebundene Verträge** (z. B. ERGO Rente Chance): eine Position je Fonds mit ISIN und aktuellem Wert; Differenz zum Vertragsguthaben als „Sonstiges Guthaben".
- **Klassische Verträge** (Kapital-LV, Rürup, Sofortrente …): eine Position mit dem Vertragsguthaben bzw. Rückkaufswert.

MoneyMoney speichert den Depotbestand bei jeder Aktualisierung lokal und baut daraus den **Wertverlauf** – ab Installation, nicht rückwirkend.

Nichts ist fest verdrahtet: Vertragsnummern, Produktnamen, Inhaber, Währung und ISINs werden bei jedem Abruf aus den ERGO-Schnittstellen gelesen.

---

## Voraussetzungen

- MoneyMoney (App-Store- oder Direktversion)
- Zugang zum ERGO-Kundenportal `kunde-s.ergo.de` (Benutzername + Passwort)
- Mobiltelefon für den **SMS-Code**: ERGO verlangt seit 2026 bei jeder Anmeldung einen zweiten Faktor

## Installation

**Signierte Version** (empfohlen): Datei `ERGO-Kundenportal.lua` in den Extensions-Ordner legen. Den Ordner öffnet MoneyMoney über *Hilfe → Datenbank im Finder zeigen* (dort der Unterordner `Extensions`).

**Unsignierte Version** (Eigenbau, Entwicklung): zusätzlich unter *Einstellungen → Extensions* die Option *„Digitale Signatur von Extensions überprüfen"* deaktivieren. Ohne diesen Schritt ignoriert MoneyMoney die Datei stillschweigend (Protokoll: `signature verification failed`).

Signaturen sind an den exakten Dateiinhalt gebunden. **Jede geänderte Version muss neu signiert werden** (Anfrage an `support@moneymoney.app`).

## Einrichtung

1. *Konto hinzufügen → Andere → „ERGO Kundenportal"*
2. Benutzername und Passwort des Kundenportals eingeben. Der Benutzername ist der bei der Registrierung gewählte Name – **nicht** die Versicherungsnummer.
3. MoneyMoney zeigt einen Dialog **„SMS-Kennwort"** mit der maskierten Mobilfunknummer. Den per SMS erhaltenen Code eingeben.
4. Die Verträge erscheinen als Depots; der erste Abruf legt den Startpunkt des Wertverlaufs.

## Konfiguration

Alle Schalter stehen am Anfang der Datei und sind dort dokumentiert.

| Schalter | Standard | Bedeutung |
|---|---|---|
| `PORTFOLIO_MODE` | `true` | Verträge als Depot mit Wertverlauf. `false`: ein Konto je Vertrag mit dem Guthaben als Saldo (ohne Historie). |
| `INCLUDE_ALL_CONTRACTS` | `false` | Auch Verträge ohne Wert (Kfz, Haftpflicht …) als 0-Euro-Konto anlegen. |
| `TERMS_MODE` | `"ask"` | Umgang mit geänderten Nutzungsbedingungen, siehe unten. |
| `SHOW_NOTICES` | `true` | Hinweise, die ERGO beim Login einblendet, im SMS-Dialog mit anzeigen. |
| `DEBUG` | `false` | Ausführliches Protokoll (Rohantworten, Feldlängen). Nur zur Fehlersuche. |
| `MANUAL_CONTRACTS` | leer | Notnagel: Verträge manuell eintragen, falls die automatische Erkennung leer bleibt. |

### Nutzungsbedingungen (`TERMS_MODE`)

ERGO verlangt nach Änderungen der Portal-Nutzungsbedingungen einmalig die Zustimmung; ohne sie ist das Portal gesperrt. Das passiert selten (einmal je Änderung, nicht bei jedem Login).

- `"ask"` – Der Änderungstext erscheint als MoneyMoney-Dialog. Eingabe `ja` = Zustimmung direkt aus MoneyMoney. Jede andere Eingabe = keine Zustimmung; der Abruf wird trotzdem versucht, und erst bei Misserfolg erscheint der Hinweis, im Browser zuzustimmen.
- `"auto"` – automatisch zustimmen, Text nur im Protokoll.
- `"never"` – nie fragen, nie zustimmen; bei Misserfolg Hinweis mit dem Änderungstext.

## Funktionsweise

1. `GET kunde-s.ergo.de` → Redirect-Kette zum ForgeRock-Login (`ciam.ergo.com`)
2. `POST /am/json/…/authenticate` → Callback-Baum wird generisch abgearbeitet: Benutzername/Passwort, Bestätigungsseiten („Verstanden"), Hinweistexte, SMS-Code-Eingabe über den MoneyMoney-Dialog
3. OAuth2-`form_post`-Formulare bis zum Dashboard automatisch absenden
4. `__RequestVerificationToken` aus dem Dashboard-HTML lesen
5. `GET apps.kunde-s.ergo.de/prod/api/v1/contracts` → Vertragsliste (Produkt, Inhaber, Gesellschaft, Status)
6. `POST /meineversicherungen/L1/api/spa` `{"contractDetails":[…]}` → Guthaben und Fondspositionen aus dem `dataFields`-Baum
7. Logout

Der Login-Teil ist bewusst nicht auf eine feste Schrittfolge gebaut: Er reagiert auf die Callback-Typen, die ERGO sendet. Entfällt der zweite Faktor oder kommt ein Hinweis hinzu, läuft die Extension ohne Änderung weiter; nur ein unbekannter Callback-Typ führt zum Abbruch mit Nennung des Typs.

Angesprochene Hosts: `kunde-s.ergo.de`, `apps.kunde-s.ergo.de`, `ciam.ergo.com`.

## Einschränkungen

- **Kein Hintergrundabruf.** Der SMS-Code ist bei jeder Anmeldung Pflicht; automatische Aktualisierungen ohne Nutzer melden das als klaren Fehler. Das ist eine ERGO-Vorgabe, keine technische Grenze der Extension.
- **Wertverlauf ab Installation.** ERGO liefert keine Historie; MoneyMoney protokolliert den Bestand ab dem ersten Abruf.
- **Getestet mit einem Vertragstyp** (fondsgebundene Rentenversicherung, ein Vertrag). Klassische Verträge, DKV und Mehrvertragskonten sind implementiert, aber nicht gegen echte Daten geprüft – Rückmeldungen willkommen.
- Nur lesend. Die einzige schreibende Aktion ist die Zustimmung zu Nutzungsbedingungen, und die nur nach ausdrücklicher Eingabe (`TERMS_MODE = "ask"`) oder bewusster Konfiguration (`"auto"`).

## Fehlersuche

1. `DEBUG = true` setzen (Zeile am Dateianfang).
2. *Fenster → Protokollfenster* öffnen, Konto aktualisieren.
3. Protokoll kopieren und als Issue einstellen.

Vorher prüfen: Das Protokoll enthält Vertragsnummern und die maskierte Mobilfunknummer; Passwörter und SMS-Codes werden **nie** protokolliert, Zugangsdaten-Felder nur als Zeichenanzahl. Die Zeilen `Anmeldeschritt N senden`, `ERGO-Hinweis:` und `Nutzungsbedingungen …` zeigen, an welchem Punkt die Anmeldung steht.

Typische Meldungen:

| Meldung | Ursache |
|---|---|
| `signature verification failed` | Unsignierte Datei bei aktiver Signaturprüfung → Prüfung deaktivieren. |
| `LoginFailed` / 401 im Protokoll | Benutzername/Passwort falsch. Im Browser mit exakt denselben Daten testen. |
| `SMS-Code abgelehnt` | Code abgelaufen oder vertippt → erneut aktualisieren, neuen Code eingeben. |
| `Nicht unterstützter Anmeldeschritt: …` | ERGO hat den Login-Ablauf geändert → Issue mit Protokoll. |
| `Keine Verträge erkannt` | Vertragsliste leer → DEBUG-Protokoll einsenden, ggf. `MANUAL_CONTRACTS`. |

## Sicherheit und Datenschutz

- Zugangsdaten verwaltet MoneyMoney (Schlüsselbund); die Extension sieht sie nur zur Laufzeit.
- Daten fließen ausschließlich zwischen deinem Rechner und den oben genannten ERGO-Hosts. Keine Telemetrie, keine Drittserver.
- Die Datei enthält keine persönlichen Daten; die im Quelltext genannte Vertragsnummer `060012345` ist ein Platzhalter.

## Rechtliches

Dieses Projekt steht in keiner Verbindung zur ERGO Group AG, zur DKV oder zu MRH applications GmbH (MoneyMoney). „ERGO", „DKV" und „MoneyMoney" sind Marken ihrer jeweiligen Inhaber.

Die Extension liest Daten des eigenen Kundenkontos über die Schnittstellen aus, die das Portal auch dem Browser liefert, und umgeht keine Schutzmaßnahmen (der zweite Faktor wird vom Nutzer selbst eingegeben). Ob die Nutzungsbedingungen des Kundenportals automatisierte Zugriffe gestatten, ist vom Nutzer selbst zu prüfen. **Nutzung auf eigene Verantwortung, ohne jede Gewähr.**

## Lizenz und Urheberschaft

Der Code wurde von einem KI-Assistenten (Claude, Anthropic) auf Grundlage von Anforderungen, Netzwerkmitschnitten und Tests des Repository-Inhabers erstellt. Nach deutschem Recht (§ 2 Abs. 2 UrhG) und der Praxis des US Copyright Office entsteht an rein KI-generiertem Code in der Regel kein Urheberrecht. Es wird daher **keine Urheberschaft beansprucht**.

Soweit dennoch Rechte bestehen, sind sie unter **[CC0 1.0 Universal](LICENSE)** freigegeben: Verwendung, Änderung und Weitergabe ohne Bedingungen, ohne Namensnennung, ohne Gewährleistung.

## Mitwirken

Issues mit DEBUG-Protokoll (ohne Zugangsdaten) sind die nützlichste Hilfe, vor allem für Vertragstypen, die hier nicht getestet werden konnten. Pull Requests: Bitte beachten, dass jede Codeänderung eine neue Signatur durch MRH braucht; gesammelte Änderungen sind deshalb praktischer als viele kleine.
