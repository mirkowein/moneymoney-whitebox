# Offline-Tests

Die Tests führen die echte `Whitebox.lua` unter Lua 5.4 aus. Es werden keine
Whitebox-Zugangsdaten benötigt und keine Netzwerkverbindungen aufgebaut.
Alle Anmeldedaten, Kennungen, Texte und Beträge in den Testantworten sind künstlich.

## Ausführen

Im Wurzelordner des Repositories:

```sh
python3 -m venv .venv
.venv/bin/pip install -r tests/requirements.txt
.venv/bin/python -m pytest -q tests
git diff --check
```

Die Abhängigkeiten stehen in [requirements.txt](requirements.txt): `pytest` als
Testläufer, `lupa` für Lua, `lxml` für das nachgebildete Login-Formular und
`graphql-core` zum Parsen der Referenzabfragen.

## Was die Testumgebung nachbildet

`Harness` in [test_whitebox.py](test_whitebox.py) stellt die MoneyMoney-Konstanten
und die verwendeten Teile von `Connection`, `HTML`, `JSON` und `MM.time` bereit.
Anfragen werden im Arbeitsspeicher aufgezeichnet und mit vorbereiteten Antworten
beantwortet. Das Login durchläuft ein Formular mit verstecktem Token. Damit werden
auch Sonderzeichen im Passwort und die Weiterleitung zur Wallet getestet.

| Bereich | Abgedeckte Fälle |
| --- | --- |
| Anmeldung | Formularfelder, Tokenanforderung, falsche Zugangsdaten, fehlendes Token, Abmeldung |
| Kontenzuordnung | Vier Ansichten, aktive Anlagen, vollständiger Slug, Refresh ohne vorherige Kontensuche, fremde IDs |
| Umsätze | Vorzeichen und Währung, Datum, Zeitraum, Sortierung, keine eigene Betragsberechnung aus Stückzahl und Kurs |
| KONTO-Texte | `Order`/`ORDER`/`order`, Kauf/Verkauf, Zeilenumbrüche, getrennter Titel, Reihenfolge und fehlende/doppelte Referenzen |
| DEPOT-Texte | Anlageklasse, Stückzahl, ausdrücklich ungefährer Kurs, ISIN und TAN, Fallback bei fehlenden Metadaten |
| Bestände | Bruchstückzahlen, Bewertung, optionale Kurse und Kaufpreise |
| Anlageklassen | Zuordnung nach Anlage und ISIN, fehlende/widersprüchliche Klassen, Folgeseiten, Caching, Cursorfehler, Sitzungswechsel |
| Performance | Prozentwerte ohne weiteren Faktor 100, alte Bezeichnung und ISIN, Informationszeilen ohne zusätzlichen Kontowert |
| Fehler | Unvollständiges JSON/GraphQL, abgelaufene Sitzung, ungültige Zahlen und Kalenderdaten, abweichende Währung |

## Referenzabfragen

- [frontend_queries.graphql](fixtures/frontend_queries.graphql) enthält Abfragen
  aus der Whitebox-Oberfläche 2.10.1, ermittelt am 21.10.2026.
- [api_asset_classes.graphql](fixtures/api_asset_classes.graphql) enthält die
  zusätzlich direkt geprüfte Abfrage für `DepotAsset.className`.

Der Referenztest prüft die im Lua-Code verwendeten Feldpfade, Argumentnamen und
Variablentypen gegen diese Abfragen. Er prüft nicht das vollständige Serverschema
und ersetzt keine erneute Prüfung nach einem Whitebox-Deployment.

## Grenzen

Die Nachbildung ersetzt nicht die tatsächliche MoneyMoney-Engine, deren
Darstellung, Signaturprüfung oder Duplikaterkennung. Sie sagt auch nicht voraus,
welche Historie oder Berechtigungen der Server für andere Konten liefert.
Bei neuen Fehlerfällen eine kleine synthetische Antwort ergänzen und das von
MoneyMoney erwartete Ergebnis prüfen; keine vollständigen Kundenprotokolle oder
Sitzungstokens in Fixtures übernehmen.

Architektur und Datenzuordnung: [IMPLEMENTATION.md](../IMPLEMENTATION.md).
