# DZ Banking – MoneyMoney-Extension

Bindet **DZ Banking**, das Firmenkundenportal der DZ BANK AG (`dzbanking.com`), in [MoneyMoney](https://moneymoney-app.com) ein: jedes Konto der Finanzübersicht als eigenes Konto – Kontokorrent als Girokonto mit IBAN, Inhaber und allen Umsätzen (Gegen-IBAN, Name, Verwendungszweck, Buchungstext), Tagesgeld/Termingeld als Sparkonto. Mehrere Konten und mehrere Unternehmen eines Zugangs werden unterstützt. Nur lesend. Privatkunden betreut die DZ BANK nicht über dieses Portal.

## Was die Extension kann

- **Umsatzhistorie bis 18 Monate** beim ersten Abruf (Portal-Maximum), danach lückenlos fortlaufend. Dafür ist einmalig je Kontokorrentkonto eine Freigabe in **SecureGo plus** nötig – siehe unten.
- **Konditionen sichtbar:** Soll-/Haben-/Überziehungszins mit Referenzzins, KK-Limit, nächste Abrechnung, Tagesgeldzins und Laufzeit werden bei jedem Abruf gelesen und als **vorgemerkte 0-€-Buchung „Konditionen"** je Konto angezeigt – bei jedem Abruf ersetzt, nie in der Historie, ohne Saldo-Einfluss. Abschalten: `CONDITIONS_MODE = "off"`.
- **Tagesgeld mit Buchungen:** Das Portal führt für Tagesgeld keine Umsätze. Anlage und Rückzahlung werden aus den Gegenbuchungen des Kontokorrents desselben Unternehmens abgeleitet; der Saldo stammt immer direkt aus dem Portal. Abschalten: `MIRROR_SAVINGS_BOOKINGS = false`.

## Installation

1. `DZ-Banking.lua` in den Extensions-Ordner legen: *Hilfe → Datenbank im Finder zeigen → Extensions*.
2. Unsignierte Datei: *Einstellungen → Extensions → „Digitale Signatur überprüfen"* deaktivieren.
3. *Konto hinzufügen → Andere → DZ Banking*. In „Benutzername" den **VR-NetKey** (oder Alias) eintragen, in „Passwort" die **PIN**.
4. Beim ersten Abruf erscheint ein Wartedialog: in der App **SecureGo plus** die Abfrage der Umsatzhistorie freigeben – einmal je Kontokorrentkonto. Danach laufen alle Abrufe ohne Freigabe.

Für den Login selbst ist kein zweiter Faktor nötig; verlangt die Bank künftig einen, nennt die Extension den Schritt im Fehlertext.

## Erstimport und SecureGo

Umsätze älter als 90 Tage gibt das Portal nur nach starker Authentifizierung heraus (PSD2). Die Extension fordert deshalb beim ersten Login die Freigabe an, wartet auf die Bestätigung in der App (Polling, kein Tippen nötig) und lädt dann bis zu `HISTORY_DAYS` Tage. Ob der Import erledigt ist, merkt sich MoneyMoney je Bankzugang.

- **Unterstützt ist nur SecureGo plus** (Direktfreigabe). Ist am Zugang kein SecureGo-Verfahren aktiv (z. B. nur Sm@rt-TAN), wird der Erstimport mit Hinweis übersprungen; alles andere funktioniert normal mit 90 Tagen Rückschau.
- **Freigabe nicht erteilt** (abgelehnt, abgelaufen, Wartezeit überschritten): Die Extension fragt, ob ohne Altdaten fortgefahren werden soll. `ja` = weiter mit 90 Tagen, keine erneute Frage. `nein` = Abbruch, nächster Abruf fragt erneut.
- **Erneut versuchen:** `HISTORY_RESET = true` setzen, aktualisieren, zurücksetzen. **Nie fragen:** `HISTORY_DAYS = 0`.
- Hintergrund-Aktualisierungen überspringen den Erstimport; er braucht eine manuelle Aktualisierung.

## Konfiguration

Schalter am Dateianfang:

| Schalter | Standard | Wirkung |
|---|---|---|
| `CONDITIONS_MODE` | `"pending"` | Konditionen als vorgemerkte Buchung; `"name"`: einmalig im Kontonamen; `"off"`: nur Protokoll |
| `MIRROR_SAVINGS_BOOKINGS` | `true` | Kapitalbewegungen des Tagesgelds aus den Gegenbuchungen des Kontokorrents ableiten |
| `HISTORY_DAYS` | `540` | Erstimport mit SecureGo-Freigabe; Portal-Maximum ca. 18 Monate; `0` = kein Erstimport |
| `HISTORY_RESET` | `false` | `true`: Erstimport beim nächsten Login wiederholen (danach zurücksetzen) |
| `MAX_DAYS` | `89` | Reichweite der laufenden Abrufe ohne Freigabe (PSD2-Grenze) |
| `PAGE_SIZE` | `300` | Umsätze je API-Seite |
| `DEBUG` | `false` | Ausführliches Protokoll; Zugangsdaten werden nie protokolliert |

## Funktionsweise

Reine JSON-API, kein HTML-Scraping. Login über das Atruvia-Auth-Backend: Zugangsdaten werden als JWE (RSA-OAEP-512 + AES-256-GCM) mit dem Bankschlüssel verschlüsselt, danach OAuth-Code → Session-Cookie; die Session wird vor jedem Abruf verlängert. Dann Kontenliste aller Unternehmen → je Konto Details, Zinssätze und Umsätze (paginiert). Einziger Host: `dzbanking.com`.

## Einschränkungen

- Teilen sich mehrere Tagesgeld-Anlagen eine Vertragsnummer-Basis, werden Kapitalbewegungen nur bei exakt passendem Betrag zugeordnet; im Zweifel fehlt eine Buchung, nie entsteht eine falsche.
- Getestet mit einem Unternehmen, Kontokorrent und Tagesgeld, SecureGo plus. Termingeld, Fremdwährungskonten, Kreditlinien und weitere Unternehmen laufen über generische Pfade – Rückmeldungen willkommen.

## Fehlersuche

`DEBUG = true`, *Fenster → Protokollfenster*, Konto aktualisieren, Protokoll als Issue einstellen (enthält Kontonummern, Salden und Namen – PIN und NetKey nie). `signature verification failed` = Signaturprüfung noch aktiv; `INVALID_CREDENTIALS` = Zugangsdaten falsch; „gesperrt" = zu viele Fehlversuche, Wartezeit abwarten.

## Lizenz

[CC0 1.0](../LICENSE) – KI-generiert (Claude, Anthropic), keine Urheberschaft beansprucht, keine Gewähr. Keine Verbindung zur DZ BANK AG, Atruvia AG oder MRH applications; Namen sind Marken ihrer Inhaber. Automatisierte Zugriffe auf das eigene Konto sind nach den Portal-Nutzungsbedingungen selbst zu prüfen.
