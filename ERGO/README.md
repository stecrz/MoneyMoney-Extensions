# ERGO Kundenportal – MoneyMoney-Extension

Bildet Verträge aus dem ERGO-Kundenportal **„Meine Versicherungen"** (`kunde-s.ergo.de`, ERGO und DKV) als Depots in [MoneyMoney](https://moneymoney-app.com) ab: fondsgebundene Verträge mit einer Position je Fonds (ISIN, aktueller Wert), klassische Verträge mit einer Position „Vertragsguthaben" bzw. „Rückkaufswert". Nur lesend.

> **Zwei-Faktor:** ERGO verlangt bei jeder Anmeldung einen SMS-Code. MoneyMoney fragt ihn in einem Dialog ab; eine Aktualisierung im Hintergrund ist deshalb nicht möglich.

## Installation

1. `ERGO-Kundenportal.lua` in den Extensions-Ordner legen: *Hilfe → Datenbank im Finder zeigen → Extensions*.
2. Unsignierte Datei: *Einstellungen → Extensions → „Digitale Signatur überprüfen"* deaktivieren.
3. *Konto hinzufügen → Andere → ERGO Kundenportal*. Benutzername ist der bei der Registrierung gewählte Name, nicht die Versicherungsnummer. Danach SMS-Code eingeben.

Der Wertverlauf beginnt mit dem ersten Abruf; ERGO liefert keine Historie.

## Konfiguration

Schalter am Dateianfang:

| Schalter | Standard | Wirkung |
|---|---|---|
| `PORTFOLIO_MODE` | `true` | Verträge als Depot mit Wertverlauf (`false`: Konto mit Guthaben als Saldo, ohne Verlauf) |
| `INCLUDE_ALL_CONTRACTS` | `false` | Auch Verträge ohne Wert (Kfz, Haftpflicht …) als 0-Euro-Konto |
| `TERMS_MODE` | `"ask"` | Geänderte Nutzungsbedingungen: im Dialog mit `ja` zustimmen (`"auto"`: automatisch, `"never"`: nie) |
| `SHOW_NOTICES` | `true` | Hinweise von ERGO im SMS-Dialog anzeigen |
| `DEBUG` | `false` | Ausführliches Protokoll |

Nutzungsbedingungen legt ERGO nur nach einer Änderung einmalig vor; ohne Zustimmung ist das Portal gesperrt. Bei Ablehnung wird der Abruf trotzdem versucht und erst bei Misserfolg ein Hinweis angezeigt.

## Funktionsweise

Login über ForgeRock (`ciam.ergo.com`), Callback-Baum generisch abgearbeitet (Zugangsdaten, Hinweisseiten, SMS-Code) → OAuth2-Formulare bis zum Dashboard → Vertragsliste (`apps.kunde-s.ergo.de`) → Vertragsdetails mit Guthaben und Fondspositionen → Logout. Hosts: `kunde-s.ergo.de`, `apps.kunde-s.ergo.de`, `ciam.ergo.com`.

## Einschränkungen

Getestet mit einer fondsgebundenen Rentenversicherung. Klassische Verträge, DKV und mehrere Verträge laufen über generische Parser – Rückmeldungen willkommen.

## Fehlersuche

`DEBUG = true`, *Fenster → Protokollfenster*, Konto aktualisieren, Protokoll als Issue einstellen (Passwörter und SMS-Codes werden nie protokolliert; Vertragsnummern schon). `signature verification failed` = Signaturprüfung noch aktiv; 401 im Protokoll = Zugangsdaten falsch.

## Lizenz

[CC0 1.0](../LICENSE) – KI-generiert (Claude, Anthropic), keine Urheberschaft beansprucht, keine Gewähr. Keine Verbindung zur ERGO Group AG, DKV oder MRH applications; Namen sind Marken ihrer Inhaber. Automatisierte Zugriffe auf das eigene Konto sind nach den Portal-Nutzungsbedingungen selbst zu prüfen.
