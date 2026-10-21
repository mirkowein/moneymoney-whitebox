# moneymoney-whitebox
An Extension to query your Whitebox.eu goals in [MoneyMoney](https://moneymoney-app.com).

![MoneyMoney screenshot mit Whitebox](Screenshots/Whitebox.png)

Es werden jeweils 4 Accounts für jedes aktive Ziel angelegt:
- KONTO = Umsätze Cash
- DEPOT = Umsätze im Depot
- PORTFOLIO = Bestand ETF 
- PERFORMANCE = Nur Informationen: Wertentwicklung nach Kosten und Steuern, Geldgewichtete Rendite annualisiert, Geldgewichtete Rendite, Vermögensstand

Es macht Sinn als Kontogruppe zu gruppieren. Also KONTO und DEPOT hat in der Summe den Vermögensstand. Oder KONTO und PORTFOLIO.
Es macht keinen Sinn DEPOT und PORTFOLIO zu haben. Sie sind 2 Darstellungen des selben Vermögens. Die Summe wäre dann doppelt in Ihren Übersichten. 

Kurz:
- KONTO + DEPOT oder
- KONTO + PORTFOLIO
- PERFORMANCE optional dazu.

## Tipp: 
Zusammen als **Kontogruppe** mit *"Kontostand in Saldenleiste anzeigen"* zusammenfassen, dann hat man den Gesamtwert des Ziels 
![MoneyMoney screenshot Kontosaldo](Screenshots/Kontosaldo.png)
![MoneyMoney screenshot Kontogruppe](Screenshots/Kontogruppe.png)


## Neue Whitebox-Oberfläche (Version 1.16)

Die Erweiterung nutzt die GraphQL-Schnittstelle der neuen Whitebox-Oberfläche.
Die Anmeldung erfolgt weiterhin über das vorhandene Login-Formular; anschließend
wird die Sitzung über `/api/onboarding/session` für die Datenabfragen verwendet.

Die Kontensuche findet aktive Anlagen mit zugeordnetem Depot. Sie übernimmt den
vollständigen `slug` der Anlage einschließlich eventueller Suffixe und verwendet
für die Datenabfragen die von Whitebox gelieferten Anlagen- und Depotkennungen.
Bestehende Konten bleiben zuordenbar, wenn ihre bisherige Kennung diesem `slug`
entspricht. Andere Kundenbereiche als der nach der Anmeldung ausgewählte werden
nicht automatisch zusammengeführt.

Cash- und Depotumsätze übernehmen den von Whitebox gelieferten Buchungsbetrag
mit Vorzeichen. Fehlende Pflichtdaten oder GraphQL-Fehler brechen den Abruf ab,
statt als leere Bestände importiert zu werden. Die neue Umsatzabfrage liefert nur
ein Buchungsdatum; ein gesondertes Wertstellungsdatum wird nicht ergänzt.
Noch nicht verfügbare Renditen werden als „nicht verfügbar“ angezeigt.
Die Zeitangabe von Wertpapierpositionen entspricht wie bisher dem Abrufzeitpunkt.

### Installation einer angepassten Version

1. In MoneyMoney **Hilfe → Zeige Datenbank im Finder** wählen und den Ordner
   **Extensions** öffnen.
2. Die bisherige `Whitebox.lua` außerhalb dieses Ordners sichern und durch die
   neue Datei ersetzen. Vorhandene Konten und Buchungen müssen nicht gelöscht werden.
3. Die geänderte Datei ist noch nicht signiert. Für einen Test muss die Option
   **MoneyMoney → Einstellungen → Erweiterungen → Digitale Signatur von Extensions
   überprüfen** ausgeschaltet sein. Für die reguläre Veröffentlichung muss die
   Erweiterung durch MoneyMoney neu signiert werden.
4. Den Zugang neu einrichten oder **Nach neuen Konten suchen** ausführen.
   Im Protokoll muss **Whitebox.lua version 1.16** erscheinen.

Beim ersten Abruf Cashbestand, Depotwert und einzelne Käufe/Verkäufe mit Whitebox
vergleichen. Bei vorhandenen Buchungen können geänderte Buchungstexte und Beträge
die Duplikaterkennung beeinflussen. Bei Bedarf die gesicherte Datei zurückkopieren
und die Signaturprüfung wieder einschalten.

### Offline-Tests

Die Tests führen das Script in Lua 5.4 mit nachgebildeten MoneyMoney-Objekten und
künstlichen Daten aus. Zusätzlich werden die abgefragten Felder, Argumentnamen und
Variablentypen mit den veröffentlichten Abfragen der Whitebox-Oberfläche 2.10.1
verglichen. Die Referenzabfragen stehen unter
`tests/fixtures/frontend_queries.graphql`; sie enthalten keine Kundendaten.
Die Tests ersetzen keine vollständige Prüfung mit einem echten Konto.

```sh
python3 -m venv .venv
.venv/bin/pip install -r tests/requirements.txt
.venv/bin/python -m pytest -q tests
```

Die MoneyMoney-API einschließlich Installation und Signaturprüfung ist unter
[MoneyMoney Web Banking API](https://moneymoney.app/api/webbanking/) dokumentiert.
