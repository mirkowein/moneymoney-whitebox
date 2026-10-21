# Implementierung und Whitebox-API

Stand: **21.10.2026**, Erweiterung **1.16**, untersuchte Whitebox-Oberfläche
**2.10.1**. Dieses Dokument beschreibt die Implementierung und die beim Umbau
bestätigten Schnittstellen. Die Whitebox-Abfragen wurden aus dem ausgelieferten
Frontend und ergänzend durch lesende Schema- und Datenabfragen ermittelt. Daraus
folgt keine Zusage, dass diese internen Schnittstellen dauerhaft unverändert bleiben.
Alle Beispiele unten verwenden künstliche Kennungen und Beträge.

## Ausgangslage und Entscheidung

Die ursprüngliche Erweiterung konnte sich weiterhin anmelden. Nach dem Login
lieferte Whitebox jedoch das Ladegerüst einer Next.js-Anwendung statt der früheren
HTML-Seite mit Depot-Schaltflächen. Die Kontensuche über diese Schaltflächen schlug
deshalb fehl. Große JavaScript-/Monitoring-Blöcke in der HTML-Antwort waren Teil
der Seite, nicht die eigentliche Fehlermeldung.

Die Anmeldung bleibt beim bestehenden Formular. Kontensuche und Datenabruf nutzen
anschließend GraphQL. Die untersuchten bisherigen REST-Pfade für `portfolio` und
`statements` antworteten mit HTTP 404 und werden nicht als Fallback verwendet.
Die Erweiterung führt keine Wertpapierorders, Überweisungen oder sonstigen
Finanzmutationen aus.

## Dateien und Aufbau

| Datei | Aufgabe |
| --- | --- |
| [Whitebox.lua](Whitebox.lua) | Einzige zur Laufzeit benötigte Erweiterungsdatei |
| [README.md](README.md) | Installation, Kontenauswahl und Hinweise für Anwender |
| [tests/test_whitebox.py](tests/test_whitebox.py) | Verhaltenstests mit Lua 5.4 und simulierten MoneyMoney-Objekten |
| [tests/fixtures/frontend_queries.graphql](tests/fixtures/frontend_queries.graphql) | Referenzabfragen aus dem öffentlichen Frontend |
| [tests/fixtures/api_asset_classes.graphql](tests/fixtures/api_asset_classes.graphql) | Zusätzlich direkt geprüfte Anlageklassen-Abfrage |
| [tests/README.md](tests/README.md) | Testaufbau, Ausführung und Grenzen der Prüfung |

Der Lua-Code ist in Abfragen, Antwortprüfung, Anlagenzuordnung, optionale
Anlageklassen, Textaufbereitung, kontoabhängige Abrufe und MoneyMoney-Einsprungspunkte
gegliedert. Die wichtigsten Zuständigkeiten sind:

| Funktionen | Zuständigkeit |
| --- | --- |
| `ReadJSON`, `RequireTable`, `Number`, `Amount` | Pflichtdaten und Zahlen/Währungen prüfen |
| `GraphQL` | Request aufbauen und GraphQL-Fehler abweisen |
| `ResetSessionState`, `LoadGoals`, `OnePortfolio` | Sitzungszustand und eindeutige Zuordnung |
| `AddAssetClass`, `CollectGoalAssetClasses`, `LoadAssetClasses` | Anlageklassen sammeln und Seiten durchlaufen |
| `PortfolioAssetClasses` | Optionalen Abruf und Sitzungscache verwalten |
| `CashOrderText`, `CashTransactionText`, `DepotTransactionText` | API-Daten in die bisherigen Buchungstexte übersetzen |
| `ReadTransactions`, `PerformanceSecurities` | MoneyMoney-Datenstrukturen erzeugen |
| `RefreshHoldings`, `RefreshBalancesAndTransactions` | Die passenden Daten pro Kontoansicht abrufen |

## Anmeldung und Sitzung

Die Basisadresse ist `https://inside.whitebox.eu`.

1. `GET /login` lädt das vorhandene Anmeldeformular.
2. Die Felder `session[email]` und `session[password]` werden befüllt. Der Submit
   erfolgt über den von MoneyMoney bereitgestellten Formularversand. Dadurch
   bleiben versteckte Felder wie `authenticity_token` und die Cookies derselben
   `Connection` erhalten.
3. Aus der Weiterleitungsadresse `/w/<walletId>/…` wird die Wallet-Kennung gelesen.
   Ein erneut angezeigtes Passwortfeld ohne diese Weiterleitung gilt als
   fehlgeschlagene Anmeldung. Andere unvollständige Anmeldungen liefern einen
   Hinweis auf die Whitebox-Webseite; ein eigener MFA-Ablauf ist nicht implementiert.
4. `GET /api/onboarding/session` wird mit `Accept: application/json` und
   `X-Requested-With: XMLHttpRequest` angefragt. Die Antwort liefert `authToken`
   sowie gegebenenfalls `csrfToken`.
5. GraphQL-Anfragen gehen an `POST /graphql` mit JSON-Body und
   `Authorization: Bearer <authToken>`.
6. `EndSession` meldet über `POST /logout` mit Formularinhalt `_method=delete` ab.
   Ein vorhandenes `csrfToken` wird dabei als `X-CSRF-Token` mitgegeben.

`authToken`, `csrfToken`, `walletId`, die Anlagenliste und Anlageklassen liegen
nur im Arbeitsspeicher der laufenden Sitzung. Beim Start und vor der Abmeldung
werden sie zurückgesetzt. `LocalStorage` wird nicht verwendet. Die Erweiterung
schreibt keine Antwortdateien und gibt keine Tokens ausdrücklich aus. MoneyMoneys
HTTP-Protokoll sowie vom Server übernommene Fehlermeldungen sind davon getrennt zu
betrachten; vollständige Protokolle gehören nicht in öffentliche Fehlerberichte.

MoneyMoney ruft beim Einrichten `ListAccounts` vor `RefreshAccount` auf, beim
normalen Rundruf jedoch nicht. Deshalb lädt `RefreshAccount` die Anlagen bei
Bedarf selbst. Die Reihenfolge und Rückgabestrukturen sind in der
[MoneyMoney Web Banking API](https://moneymoney.app/api/webbanking/) beschrieben.

## Kennungen und Konten

| Kennung | Herkunft und Verwendung |
| --- | --- |
| `walletId` | Aus der Login-Weiterleitung; begrenzt die Abfragen auf den ausgewählten Kundenbereich |
| `goal.id` | Serverkennung einer Anlage; Ersatzschlüssel, wenn `slug` fehlt |
| `goal.slug` | Vollständig übernommener Schlüssel für bestehende MoneyMoney-Kontonummern |
| `goal.portfolioId` | Depotkennung für gezielte Bestands-, Umsatz- und Performance-Abfragen |
| ISIN | Zuordnung eines Wertpapiers bzw. seiner optionalen Anlageklasse |

Diese Serverkennungen werden unverändert übernommen: keine Ziffern abschneiden, keine Slugs aus Namen
erzeugen und keine angenommene Gleichheit von Goal-ID und Portfolio-ID verwenden.
Synthetisches Beispiel: Aus dem Slug `anlage-demo_42` entstehen
`KONTO_anlage-demo_42`, `DEPOT_anlage-demo_42`, `PERFORMANCE_anlage-demo_42`
und `PORTFOLIO_anlage-demo_42`.

Die Kontensuche bietet nur Ziele mit `status == "ACTIVE"` und einer Depotkennung
an. Doppelte Schlüssel führen zum Abbruch. Ein gespeichertes Konto mit nicht mehr
zuordenbarem Schlüssel wird nicht ersatzweise einer anderen Anlage zugewiesen.
Weitere Kundenbereiche werden nicht automatisch zusammengeführt.

| Präfix | Rückgabe | Bedeutung für den Gesamtwert |
| --- | --- | --- |
| `KONTO` | Cashsaldo und Cashumsätze | Mit `DEPOT` oder `PORTFOLIO` kombinieren |
| `DEPOT` | Depotwert und Depotumsätze | Alternative zu `PORTFOLIO` |
| `PORTFOLIO` | Einzelne Wertpapierpositionen | Derselbe Vermögensanteil wie `DEPOT` |
| `PERFORMANCE` | Vier Informationspositionen | `quantity`, `price` und `amount` jeweils `0` |

`AccountTypePortfolio` und MoneyMoneys Kennzeichen `portfolio` sind unterschiedliche
Angaben: `DEPOT` hat zwar diesen Kontotyp, liefert aber Umsätze. Das Kennzeichen
für Wertpapierpositionen wird nur bei `PORTFOLIO` und `PERFORMANCE` gesetzt.

## GraphQL-Abfragen

Die vollständigen sechs Abfragen stehen als `*_QUERY`-Konstanten im Lua-Code.
`operationName` bezeichnet die lokale Abfrage, nicht einen zusätzlichen URL-Pfad.
Der Request hat die Form:

```json
{
  "operationName": "MoneyMoneyGoals",
  "query": "query MoneyMoneyGoals($walletId: ID!) { wealthGoals(walletId: $walletId) { id slug name status portfolioId } }",
  "variables": {"walletId": "wallet-demo"}
}
```

| Operation | Datenpfad / Zweck |
| --- | --- |
| `MoneyMoneyGoals` | `wealthGoals`: `id`, `slug`, `name`, `status`, `portfolioId` |
| `MoneyMoneyCash` | `portfolios.cashAccount.balance` und `cashTransactions` |
| `MoneyMoneyDepot` | `portfolios.depotAccount.currentValue` und `depotTransactions` |
| `MoneyMoneyAssets` | `assets.securityData`: Bestände und optionale Kurse |
| `MoneyMoneyAssetClasses` | `wallet.goals.nodes.portfolio.depotAssets`: `isin`, `className` |
| `MoneyMoneyPerformance` | `portfolios.performanceReport`: Vermögensstand, Renditen und Euroergebnis |

`walletId` hat den Variablentyp `ID!`, `portfolioIds` den Typ `[ID!]`.
Datumsgrenzen sind optionale `ISO8601Date`-Werte im Format `YYYY-MM-DD`.
Der Cursor `after` ist ein optionaler `String`. Bei den Depot-/Bestandsabfragen
ist `productType: WEALTH` fest angegeben. Geldobjekte haben die Form
`{ amount, currency { isoCode } }`; `amount` kann ein Dezimalstring sein.

Die portfolioabhängigen Abrufe senden genau eine `portfolioId`. Antworten mit
mehreren Depots oder einer anderen ID werden bei Salden und Performance
abgewiesen. Ein ungezielter Abruf aller Depots erwies sich bei der Untersuchung
als unnötig langsam und konnte in eine Zeitüberschreitung laufen.

Für Umsätze setzt die Erweiterung `from` aus MoneyMoneys `since` und `to` auf den
aktuellen Tag. Ohne `since` bleibt `from` weg; der Server bestimmt dann die
verfügbare Historie. Die untersuchten Umsatzabfragen liefern Listen und keine
Cursor-Verbindung. Eine unbegrenzte Historie oder das Fehlen anderer serverseitiger
Grenzen ist damit nicht bewiesen. Die API-Antwort liefert ein Buchungsdatum, aber
kein gesondertes Wertstellungsdatum für diese Abfragen.

## Anlageklassen und Wertpapierpositionen

`assets.securityData.type` bezeichnet Typen wie ETF oder FUND. Daraus lässt sich
die fachliche Anlageklasse, etwa „Aktien Schwellenländer“, nicht ableiten.
Die zusätzliche, direkt geprüfte Abfrage nutzt stattdessen `DepotAsset.className`:

```graphql
query MoneyMoneyAssetClasses($walletId: ID!, $after: String) {
  wallet(id: $walletId) {
    goals(first: 100, after: $after) {
      nodes {
        slug
        portfolio { depotAssets { isin className } }
      }
      pageInfo { hasNextPage endCursor }
    }
  }
}
```

Die Zuordnung erfolgt über **Goal-Slug und ISIN**, nicht über Zeilenposition oder
Fondsname. `className` wird am Rand von Leerraum befreit. Der Anzeigename lautet
anschließend `Test ETF (Aktien Schwellenländer)`; ein bereits vorhandener identischer
Zusatz wird nicht doppelt angehängt.

Weitere Seiten werden anhand von `hasNextPage` und `endCursor` geladen. Ein
fehlender oder wiederholter Cursor bei angekündigter Folgeseite ist ein Fehler.
Erst nach vollständigem Abruf wird das Ergebnis in den Sitzungscache übernommen.
Bei widersprüchlichen Klassen für dieselbe ISIN innerhalb einer Anlage markiert
`false` die Mehrdeutigkeit; auch spätere Treffer lösen sie nicht durch Raten auf.

Anlageklassen sind optionale Anzeigeinformationen. Scheitert die Abfrage, werden
auch bereits geladene Teilseiten verworfen. Für die restliche Sitzung bleibt der
Cache leer; Bestände und Umsätze können ohne Klassenzusatz geladen werden. Ein
neuer Abrufversuch erfolgt in der nächsten Sitzung. Fehlende Portfolios oder
fehlende `depotAssets` einzelner Anlagen werden übersprungen. Die Abfrage erfolgt
nur bei nichtleeren Beständen oder Depotumsätzen.

Historische, inzwischen vollständig verkaufte Positionen können in den aktuellen
Depotmetadaten fehlen. Dann bleibt ihr Buchungstext ohne Anlageklasse.

| Whitebox-Feld | MoneyMoney-Feld |
| --- | --- |
| `securityData.name` + optionale Klasse | `name` |
| `isin` | `isin` |
| `shares` | `quantity` |
| `totalValue.amount` | `amount` |
| `marketPrice` | `price`, wenn vorhanden |
| `averagePurchasePrice` | `purchasePrice`, wenn vorhanden |

Die Zeitangabe `tradeTimestamp` ist der Abrufzeitpunkt, kein nachgewiesener
Börsenzeitstempel. Fehlende optionale Kurse werden ausgelassen, nicht als null
erfunden. Die bestehenden Abfragen und Darstellungen gehen von EUR aus.

## Buchungstexte und Beträge

### KONTO: Titel von Referenzen trennen

Ein tatsächlich bestätigtes Format, hier mit künstlichen Kennungen, ist:

```text
description: Ausführung ORDER Verkauf IE00TEST0001 987654321
number:      123456789
```

Daraus werden ausdrücklich zwei MoneyMoney-Felder erzeugt:

```text
name:    Ausführung Order Verkauf IE00TEST0001
purpose: 987654321 123456789
```

Die Großschreibung `ORDER` war wesentlich: Eine nur auf `Order` abgestimmte
Erkennung griff nicht. Die aktuelle Erkennung akzeptiert unterschiedliche
Groß-/Kleinschreibung dieses Worts und der Kauf-/Verkauf-Angabe und vereinheitlicht
Leerraum einschließlich Zeilenumbrüchen. Die ISIN muss aus zwei Großbuchstaben
und weiteren alphanumerischen Zeichen bestehen und insgesamt zwölf Zeichen haben;
eine Prüfzifferprüfung erfolgt dabei nicht.

Die erste Nummer stammt aus dem Ende der Beschreibung, die zweite aus `number`.
Fehlende Referenzen werden ausgelassen, identische nicht doppelt ausgegeben.
Andere Cashbuchungen behalten die bisherige Aufbereitung: Nummer vor dem
Beschreibungstext bzw. `Referenz <Nummer>`, wenn die Beschreibung leer ist.

### DEPOT: bisherige Reihenfolge erhalten

`DepotTransactionText` setzt vorhandene Teile in dieser Reihenfolge zusammen:

1. Beschreibung der API;
2. optionale Anlageklasse;
3. Produktname;
4. `Anteile <quantity>`, gegebenenfalls ergänzt um `Kurs ca. <Näherungswert>`;
5. `ISIN <isin> TAN <number>`.

`TAN` ist hier die bisherige Beschriftung der Transaktionsreferenz, keine
Aufforderung zur Zwei-Faktor-Authentifizierung.

Der verbindliche Umsatzbetrag ist immer **`value.amount` mit dem gelieferten
Vorzeichen**. Die frühere Multiplikation von Stückzahl und Kurs wird nicht für
den importierten Betrag verwendet. `depotTransactions` stellt keinen eigenen
Ausführungskurs bereit; die im Umbau geprüften Buchungswerte waren centgerundet.

Für den Anzeigetext wird deshalb `abs(Buchungsbetrag / Stückzahl)` als
**„Kurs ca.“** berechnet. Rundung und mögliche im Betrag enthaltene Kosten können
den Quotienten vom historischen Ausführungskurs unterscheiden. Die Anzeige nutzt
drei Nachkommastellen und entfernt überflüssige Endnullen. Sehr kleine positive
Werte, die sonst als null erschienen, werden mit sechs signifikanten Stellen
formatiert. Bei fehlenden, unlesbaren oder nullwertigen Stückzahlen bzw. einem
Nullbetrag wird kein Kurs ergänzt. Der Umsatzbetrag selbst bleibt unverändert.

## Performance und stabile Kennungen

Die Abfrage setzt `withWhiteboxFees: true` und `withTaxes: true`.
Die vier Zeilen behalten ihre bisherigen Kennungen:

| MoneyMoney-ISIN nach `Performance ` | Bezeichnung | API-Wert |
| --- | --- | --- |
| `end_assets` | Vermögensstand | `endAssets.amount` |
| `mwr` | Geldgewichtete Rendite | `moneyWeightedReturnInPercentage` |
| `yearly_mwr` | Geldgewichtete Rendite annualisiert | `moneyWeightedReturnAnnualizedInPercentage` |
| `sum_of_erfolgsrelevante_kapitalveraenderungen` | Erfolgsrelevante Kapitalveränderungen | `returnInEuro.amount` |

Die letzte Kennung ist eine **Kompatibilitätskennung für MoneyMoney**, kein Feldname
der neuen GraphQL-Abfrage. Beim lesenden Abgleich entsprach `returnInEuro` der
Summe aus `gains` und `costs` des älteren GraphQL-Typs `PerformanceReport`. Die
Erweiterung nutzt den aktuellen API-Wert, ohne ihn an einen älteren Anzeigenstand
anzupassen. Unterschiedliche Bewertungszeitpunkte können unterschiedliche Werte
liefern; die Beobachtung ist keine Garantie identischer Werte aller API-Varianten.

Die aktuellen Renditefelder enthalten bereits Prozentwerte. Der frühere Faktor
100 darf deshalb nicht übernommen werden. Fehlende Renditen erscheinen als
„nicht verfügbar“. Alle vier Positionen haben `quantity = 0`, `price = 0` und
`amount = 0`, damit die Informationsansicht keinen zusätzlichen Vermögenswert zählt.

## Fehlerbehandlung und Wartung

- Ungültiges JSON, fehlende Pflichtobjekte, nicht endliche Zahlen und unerwartete
  Kontowährungen brechen den Abruf ab. Gültige Nullbeträge sind erlaubt.
- Ein GraphQL-Fehler wird auch dann nicht ignoriert, wenn gleichzeitig `data`
  enthalten ist. `UNAUTHENTICATED` erhält einen Hinweis auf die abgelaufene Sitzung.
- Optionale Anlageklassen haben den beschriebenen Fallback; Salden und Bestände
  haben keinen Fallback auf leere oder geschätzte Finanzdaten.
- Datumswerte werden streng als Kalendertage geprüft und in lokale Mittagszeit
  umgewandelt. Umsätze werden nach Buchungsdatum absteigend sortiert.
- Änderungen an Slugs, Buchungstexten oder Beträgen können die Zuordnung bzw.
  Duplikaterkennung bestehender MoneyMoney-Daten beeinflussen. Für künftige
  Änderungen zuerst die betroffenen Verhaltenstests und Datenfelder prüfen.

Zum Nachziehen einer Whitebox-Änderung zuerst die veröffentlichten Abfragen und
gegebenenfalls das Schema untersuchen. Für Datenprüfungen gezielt die betroffene
Wallet und Portfolio-ID verwenden. Nur anonymisierte oder künstliche Beispiele
in Tests und Dokumentation übernehmen. Die Erweiterung ist noch unsigniert;
eine Änderung am Lua-Quelltext macht die bisherige Signatur unbrauchbar.
Installation und Signierung sind im [README](README.md) beschrieben.

## Quellen und Prüfgrenzen

- [MoneyMoney Web Banking API](https://moneymoney.app/api/webbanking/):
  Einsprungspunkte, Formular-/Verbindungsobjekte und Datenstrukturen.
- [Whitebox-Frontend, Abfragen und Typen](https://inside.whitebox.eu/_next/static/chunks/1tz_niucvfldq.js):
  Ausgangspunkt der Referenzabfragen in `tests/fixtures/frontend_queries.graphql`.
- [Whitebox-Sitzungsaufbau](https://inside.whitebox.eu/_next/static/chunks/2f3rcg-qyh02u.js):
  `/api/onboarding/session`, `authToken`, `csrfToken`.
- [Whitebox-GraphQL-Anbindung](https://inside.whitebox.eu/_next/static/chunks/33dvpo_6xwbe8.js):
  Bearer-Authentifizierung und `/graphql`.
- [Ursprüngliche Erweiterung](https://github.com/mirkowein/moneymoney-whitebox) und
  [Issue #13](https://github.com/mirkowein/moneymoney-whitebox/issues/13):
  bisherige Kennungen und Fehlerbild nach der Umstellung.

Die Chunk-URLs sind Versionsartefakte und können nach weiteren Whitebox-Deployments
entfallen. Die gespeicherten Referenzabfragen enthalten keine Kundenantworten.
Die Tests prüfen das Lua-Verhalten unter einer simulierten MoneyMoney-Umgebung
und gleichen die Abfragefelder mit diesen Referenzen ab. Sie beweisen keine
dauerhaften Serverberechtigungen, unbegrenzte Historie oder unveränderte Darstellung
aller bestehenden Buchungen in MoneyMoney. Testdetails: [tests/README.md](tests/README.md).
