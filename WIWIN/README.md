# WIWIN – MoneyMoney-Extension

Bildet das Portfolio aus dem WIWIN-Investorenportal **`invest.wiwin.de`** als Depot in [MoneyMoney](https://moneymoney-app.com) ab: eine Position je Investition (Bestandswert, ISIN, Emittent, Finanzinstrument, Vertragsnummer, Kaufdatum) plus Guthaben des Baader-Bank-Verrechnungskontos – auch negativ. Nur lesend.

> **Login-Weg:** Zugangsdaten von **`invest.wiwin.de`** (Kundenportal, Partner Portagon) – nicht von `wiwin-invest.de`. Nur über das Portal sind alle Investitionen sichtbar.

## Installation

1. `WIWIN.lua` in den Extensions-Ordner legen: *Hilfe → Datenbank im Finder zeigen → Extensions*.
2. Unsignierte Datei: *Einstellungen → Extensions → „Digitale Signatur überprüfen"* deaktivieren.
3. *Konto hinzufügen → Andere → WIWIN Crowdinvesting*, E-Mail und Passwort eingeben.

Der Wertverlauf beginnt mit dem ersten Abruf; das Portal liefert keine Historie.

## Konfiguration

Schalter am Dateianfang:

| Schalter | Standard | Wirkung |
|---|---|---|
| `INCLUDE_CASH` | `true` | Verrechnungskonto-Guthaben mit abbilden |
| `SEPARATE_CASH_ACCOUNT` | `false` | Guthaben als eigenes Girokonto mit IBAN statt als Depotposition |
| `INCLUDE_REPAID` | `false` | Auch beendete Investitionen abrufen |
| `RICH_NAMES` | `true` | Finanzinstrument und Vertragsnummer im Positionsnamen |
| `FETCH_DETAILS` | `true` | Detailseite je Investition laden (`false`: nur Liste – schneller, ohne ISIN und Bestandswert) |
| `DEBUG` | `false` | Ausführliches Protokoll |

## Funktionsweise

Login (CSRF + Session) → Investitionsliste über alle Seiten → Detailseite je Investition (bei Fehler Rückfall auf die Listenzeile) → Guthaben-Fragment → Abgleich der Positionssumme mit dem Portal-Bestandswert (Warnung bei Abweichung) → Logout. Einziger Host: `invest.wiwin.de`.

## Einschränkungen

- Stückzahl und Stückpreis stehen nur im Zeichnungsschein-PDF, nicht im Portal; die Position führt den Gesamtwert.
- Getestet mit Namensaktien (eine Position). Andere Instrumente laufen über generische Parser – Rückmeldungen willkommen.

## Fehlersuche

`DEBUG = true`, *Fenster → Protokollfenster*, Konto aktualisieren, Protokoll als Issue einstellen (Passwörter werden nie protokolliert; Vertragsnummern und IBAN schon). `signature verification failed` = Signaturprüfung noch aktiv.

## Lizenz

[CC0 1.0](../LICENSE) – KI-generiert (Claude, Anthropic), keine Urheberschaft beansprucht, keine Gewähr. Keine Verbindung zu WIWIN, Portagon, Baader Bank oder MRH applications; Namen sind Marken ihrer Inhaber. Automatisierte Zugriffe auf das eigene Konto sind nach den Portal-Nutzungsbedingungen selbst zu prüfen.
