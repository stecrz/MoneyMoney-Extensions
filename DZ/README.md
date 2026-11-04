# DZ Banking – MoneyMoney-Extension

Bildet die Konten aus **DZ Banking**, dem Firmenkundenportal der DZ BANK AG (`dzbanking.com`), in [MoneyMoney](https://moneymoney-app.com) ab: jedes Konto der Finanzübersicht als eigenes Konto – Kontokorrent als Girokonto mit IBAN, Inhaber und allen Umsätzen (Gegen-IBAN, Name, Verwendungszweck, Buchungstext), Tagesgeld/Termingeld als Sparkonto mit Saldo. Nur lesend. Privatkunden betreut die DZ BANK nicht über dieses Portal.

> **Konditionen in MoneyMoney:** Zinssätze (Soll/Haben/Überziehung mit Referenzzins), KK-Limit, nächste Abrechnung, Tagesgeldzins und Laufzeit liest die Extension bei jedem Abruf. Da MoneyMoney für Konten kein aktualisierbares Textfeld hat, erscheinen sie standardmäßig als **vorgemerkte 0-€-Buchung „Konditionen"** – bei jedem Abruf ersetzt, nie in der Historie, ohne Saldo-Einfluss. **Abschalten:** in der Datei `CONDITIONS_MODE = "off"` setzen (oder `"name"` für einen einmaligen Eintrag im Kontonamen).

## Installation

1. `DZ-Banking.lua` in den Extensions-Ordner legen: *Hilfe → Datenbank im Finder zeigen → Extensions*.
2. Unsignierte Datei: *Einstellungen → Extensions → „Digitale Signatur überprüfen"* deaktivieren.
3. *Konto hinzufügen → Andere → DZ Banking*. In das Feld „Benutzername" den **VR-NetKey** (oder Alias) eintragen, in „Passwort" die **PIN**.

Ein zweiter Faktor ist für den Lesezugriff nicht nötig; verlangt die Bank künftig einen, nennt die Extension den Schritt im Fehlertext.

## Konfiguration

Schalter am Dateianfang:

| Schalter | Standard | Wirkung |
|---|---|---|
| `CONDITIONS_MODE` | `"pending"` | Konditionen als vorgemerkte Buchung; `"name"`: im Kontonamen bei Anlage; `"off"`: nur Protokoll |
| `MIRROR_SAVINGS_BOOKINGS` | `true` | Kapitalbewegungen des Tagesgelds aus den Gegenbuchungen des Kontokorrents als Umsätze führen |
| `MAX_DAYS` | `89` | Wie weit Umsätze zurückgeholt werden; mehr verlangt eine SecureGo-Freigabe |
| `PAGE_SIZE` | `300` | Umsätze je API-Seite |
| `DEBUG` | `false` | Ausführliches Protokoll (Zugangsdaten werden nie protokolliert) |

## Funktionsweise

Reine JSON-API, kein HTML-Scraping. Login über das Atruvia-Auth-Backend: Zugangsdaten werden als JWE (RSA-OAEP-512 + AES-256-GCM) mit dem Bankschlüssel verschlüsselt, danach OAuth-Code → Session-Cookie. Die Session läuft nach ~90 s ab und wird vor jedem Kontoabruf verlängert. Danach: Kontenliste aller Unternehmen → je Konto Details, Zinssätze und Umsätze (paginiert, ab letztem bekannten Umsatz). Einziger Host: `dzbanking.com`.

## Einschränkungen

- **Umsätze maximal 90 Tage zurück.** Ältere gibt das Portal nur nach SecureGo-Freigabe heraus (PSD2); MoneyMoney kann während des Abrufs keine Freigabe einholen. Ab der Einrichtung wächst die Historie lückenlos.
- **Tagesgeld ohne eigene Umsätze im Portal.** Anlage und Rückzahlung werden aus den Gegenbuchungen des Kontokorrents abgeleitet (gleiches Unternehmen, letzte 90 Tage); Zinsen fließen auf das Kontokorrent und bleiben dort. Fehlt die Gegenbuchung – etwa bei einer älteren Anlage – fehlt nur die Buchung, der Saldo stammt immer direkt aus dem Portal. Teilen sich mehrere Anlagen eine Vertragsnummer-Basis, wird nur bei exakt passendem Betrag zugeordnet.
- Getestet mit einem Unternehmen, je einem Kontokorrent- und Tagesgeldkonto. Termingeld, Fremdwährung und Kreditlinien laufen über generische Pfade – Rückmeldungen willkommen.

## Fehlersuche

`DEBUG = true`, *Fenster → Protokollfenster*, Konto aktualisieren, Protokoll als Issue einstellen (enthält Kontonummern, Salden und Namen – PIN und NetKey nie). `signature verification failed` = Signaturprüfung noch aktiv; „gesperrt" = zu viele Fehlversuche, Wartezeit abwarten.

## Lizenz

[CC0 1.0](../LICENSE) – KI-generiert (Claude, Anthropic), keine Urheberschaft beansprucht, keine Gewähr. Keine Verbindung zur DZ BANK AG, Atruvia AG oder MRH applications; Namen sind Marken ihrer Inhaber. Automatisierte Zugriffe auf das eigene Konto sind nach den Portal-Nutzungsbedingungen selbst zu prüfen.
