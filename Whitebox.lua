-- MoneyMoney Web Banking extension for Whitebox.
-- Based on https://github.com/mirkowein/moneymoney-whitebox
--
-- The MIT License (MIT)
-- Copyright (c) Mirko Weinschenk
--
-- Permission is hereby granted, free of charge, to any person obtaining a copy
-- of this software and associated documentation files (the "Software"), to deal
-- in the Software without restriction, including without limitation the rights
-- to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
-- copies of the Software, and to permit persons to whom the Software is
-- furnished to do so, subject to the following conditions:
--
-- The above copyright notice and this permission notice shall be included in
-- all copies or substantial portions of the Software.
--
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
-- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
-- OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
-- THE SOFTWARE.
--
-- 1.16 (2026-10-21, unsigned version): Replace retired HTML/REST
-- scraping with GraphQL, including asset-class names and transaction text.
-- Keep cash order titles separate from their reference numbers.
-- KONTO + DEPOT or KONTO + PORTFOLIO represent one goal's assets.
-- PERFORMANCE contains information only and contributes no balance.
-- Architektur, API-Quellen und Datenzuordnung: siehe IMPLEMENTATION.md.

local BASE_URL = "https://inside.whitebox.eu"

WebBanking {
    version = 1.16,
    url = BASE_URL .. "/login",
    services = {"Whitebox"},
    description = "Whitebox"
}

-- Nur für die laufende Sitzung: keine Tokens oder Kundendaten in LocalStorage.
local connection, authToken, csrfToken, walletId
local goals, goalsByKey
local assetClassesByGoal

-- Field names and argument types come from the public frontend's generated
-- queries. Request only read operations; all responses must be complete.
local GOALS_QUERY = [[
query MoneyMoneyGoals($walletId: ID!) {
  wealthGoals(walletId: $walletId) {
    id slug name status portfolioId
  }
}
]]

local CASH_QUERY = [[
query MoneyMoneyCash($walletId: ID!, $portfolioIds: [ID!], $from: ISO8601Date, $to: ISO8601Date) {
  portfolios(walletId: $walletId, portfolioIds: $portfolioIds, productType: WEALTH) {
    id
    cashAccount { balance { amount currency { isoCode } } }
    cashTransactions(from: $from, to: $to) {
      date description number value { amount currency { isoCode } }
    }
  }
}
]]

local DEPOT_QUERY = [[
query MoneyMoneyDepot($walletId: ID!, $portfolioIds: [ID!], $from: ISO8601Date, $to: ISO8601Date) {
  portfolios(walletId: $walletId, portfolioIds: $portfolioIds, productType: WEALTH) {
    id
    depotAccount { currentValue { amount currency { isoCode } } }
    depotTransactions(from: $from, to: $to) {
      date description number isin productName quantity
      value { amount currency { isoCode } }
    }
  }
}
]]

local ASSETS_QUERY = [[
query MoneyMoneyAssets($walletId: ID!, $portfolioIds: [ID!]) {
  assets(walletId: $walletId, portfolioIds: $portfolioIds, productType: WEALTH) {
    securityData {
      isin name shares marketPrice averagePurchasePrice
      totalValue { amount currency { isoCode } }
    }
  }
}
]]

-- Verified against the live API: the detailed DepotAsset type retains the
-- allocation class that is absent from assets.securityData.
local ASSET_CLASSES_QUERY = [[
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
]]

local PERFORMANCE_QUERY = [[
query MoneyMoneyPerformance($walletId: ID!, $portfolioIds: [ID!]) {
  portfolios(walletId: $walletId, portfolioIds: $portfolioIds, productType: WEALTH) {
    id
    performanceReport(input: {withWhiteboxFees: true, withTaxes: true}) {
      endAssets { amount currency { isoCode } }
      returnInEuro { amount currency { isoCode } }
      moneyWeightedReturnInPercentage
      moneyWeightedReturnAnnualizedInPercentage
    }
  }
}
]]

-- ---------------------------------------------------------------------------
-- Antworten prüfen und mit Whitebox kommunizieren
-- ---------------------------------------------------------------------------

local function Fail(message)
    error("Whitebox: " .. message, 0)
end

local function ReadJSON(content, context)
    local ok, result = pcall(function()
        return JSON(content):dictionary()
    end)
    if not ok or type(result) ~= "table" then
        Fail(context .. ": keine gültige JSON-Antwort. Bitte die Anmeldung auf der Whitebox-Webseite prüfen.")
    end
    return result
end

local function RequireTable(value, field)
    if type(value) ~= "table" then
        Fail("Antwort unvollständig: " .. field .. " fehlt. Es werden keine leeren Bestände übernommen.")
    end
    return value
end

local function Number(value, field)
    local number
    if type(value) == "number" or type(value) == "string" then
        number = tonumber(value)
    end
    -- Decimal-Werte kommen auch als Strings. NaN und unendliche Werte sind
    -- ebenso ungültig wie fehlende Werte; keiner davon darf zu null werden.
    if not number or number ~= number or number == math.huge or number == -math.huge then
        Fail("Ungültiger Zahlenwert für " .. field .. ".")
    end
    return number
end

local function Text(value)
    if type(value) == "string" or type(value) == "number" then
        return tostring(value)
    end
    return ""
end

local function Now()
    if MM and MM.time then
        return math.floor(MM.time())
    end
    return os.time()
end

local function Amount(money, field, expectedCurrency)
    RequireTable(money, field)
    local currency = RequireTable(money.currency, field .. ".currency").isoCode
    if type(currency) ~= "string" or currency == "" then
        Fail("Währung fehlt: " .. field .. ".")
    end
    if expectedCurrency and currency ~= expectedCurrency then
        Fail("Unerwartete Währung bei " .. field .. ": " .. currency .. ".")
    end
    return Number(money.amount, field .. ".amount"), currency
end

function IsoDateStr2Timestamp(dateStr)
    local year, month, day = string.match(Text(dateStr), "^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
    if not year then
        Fail("Ungültiges Buchungsdatum.")
    end
    -- Lokale Mittagszeit vermeidet die Tagesgrenze. os.time normalisiert
    -- ungültige Daten; deshalb anschließend den Kalendertag zurückprüfen.
    local timestamp = os.time({
        year = tonumber(year), month = tonumber(month), day = tonumber(day), hour = 12
    })
    if not timestamp or os.date("%Y-%m-%d", timestamp) ~= dateStr then
        Fail("Ungültiges Buchungsdatum.")
    end
    return timestamp
end

local function ResetSessionState()
    authToken, csrfToken, walletId = nil, nil, nil
    goals, goalsByKey, assetClassesByGoal = nil, nil, nil
end

local function GraphQL(operation, query, variables)
    if not authToken then
        Fail("Keine aktive Sitzung. Bitte erneut anmelden.")
    end
    local body = JSON():set({
        operationName = operation, query = query, variables = variables
    }):json()
    local headers = {
        Accept = "application/json", Authorization = "Bearer " .. authToken
    }
    local content = connection:request("POST", BASE_URL .. "/graphql", body, "application/json", headers)
    local result = ReadJSON(content, operation)

    -- GraphQL kann Daten und Fehler gemeinsam liefern. Eine solche Teilantwort
    -- wird nicht als gültiger Kontostand oder vollständiger Bestand übernommen.
    if result.errors ~= nil then
        RequireTable(result.errors, "errors")
        for _, item in pairs(result.errors) do
            if type(item) == "table" and type(item.extensions) == "table"
                and item.extensions.code == "UNAUTHENTICATED" then
                Fail("Sitzung abgelaufen. Bitte erneut anmelden.")
            end
            local message = type(item) == "table" and Text(item.message) or "GraphQL-Fehler"
            Fail("Die Datenabfrage " .. operation .. " wurde abgewiesen: " .. message)
        end
    end
    return RequireTable(result.data, operation .. ".data")
end

-- ---------------------------------------------------------------------------
-- Anlagen und Depotzuordnung: Kennungen immer vom Server übernehmen
-- ---------------------------------------------------------------------------

local function LoadGoals()
    if goals then
        return
    end
    local data = GraphQL("MoneyMoneyGoals", GOALS_QUERY, {walletId = walletId})
    local loaded = RequireTable(data.wealthGoals, "wealthGoals")
    local byKey = {}
    for _, goal in ipairs(loaded) do
        RequireTable(goal, "wealthGoals[]")
        if Text(goal.id) == "" then
            Fail("Die Anlagenkennung fehlt.")
        end
        -- Den vollständigen Slug erhalten, auch Suffixe und Ziffern. Nur so
        -- passen bestehende KONTO_<slug> usw. weiterhin zur richtigen Anlage.
        local key = Text(goal.slug)
        if key == "" then
            key = Text(goal.id)
        end
        if byKey[key] then
            Fail("Whitebox hat doppelte Anlagenkennungen geliefert.")
        end
        goal.accountKey = key
        byKey[key] = goal
    end
    goals, goalsByKey = loaded, byKey
end

local function OnePortfolio(data, portfolioId)
    local portfolios = RequireTable(data.portfolios, "portfolios")
    if #portfolios ~= 1 or Text(portfolios[1].id) ~= portfolioId then
        Fail("Das angeforderte Depot konnte nicht eindeutig zugeordnet werden.")
    end
    return portfolios[1]
end

-- ---------------------------------------------------------------------------
-- Optionale Anlageklassen: nach Slug und ISIN zuordnen, pro Sitzung zwischenspeichern
-- ---------------------------------------------------------------------------

local function AddAssetClass(byIsin, row)
    if type(row) ~= "table" or type(row.isin) ~= "string" or row.isin == ""
        or type(row.className) ~= "string" then
        return
    end
    local className = row.className:match("^%s*(.-)%s*$")
    if className == "" then
        return
    end
    if byIsin[row.isin] == nil then
        byIsin[row.isin] = className
    elseif byIsin[row.isin] ~= className then
        -- false markiert einen Widerspruch. Auch ein späterer Treffer darf
        -- diese Mehrdeutigkeit nicht wieder durch eine geratene Klasse ersetzen.
        byIsin[row.isin] = false
    end
end

local function CollectGoalAssetClasses(classesByGoal, entry)
    RequireTable(entry, "wallet.goals.nodes[]")
    if type(entry.slug) ~= "string" or entry.slug == "" or entry.portfolio == nil then
        return
    end
    local portfolio = RequireTable(entry.portfolio, "Anlageklassen-Depot")
    if portfolio.depotAssets == nil then
        return
    end
    local rows = RequireTable(portfolio.depotAssets, "depotAssets")
    local byIsin = classesByGoal[entry.slug] or {}
    classesByGoal[entry.slug] = byIsin
    for _, row in ipairs(rows) do
        AddAssetClass(byIsin, row)
    end
end

local function LoadAssetClasses()
    local classesByGoal, after, seenCursors = {}, nil, {}
    while true do
        local data = GraphQL("MoneyMoneyAssetClasses", ASSET_CLASSES_QUERY, {
            walletId = walletId, after = after
        })
        local page = RequireTable(RequireTable(data.wallet, "wallet").goals, "wallet.goals")
        for _, entry in ipairs(RequireTable(page.nodes, "wallet.goals.nodes")) do
            CollectGoalAssetClasses(classesByGoal, entry)
        end

        local info = RequireTable(page.pageInfo, "wallet.goals.pageInfo")
        if info.hasNextPage == false then
            return classesByGoal
        end
        if info.hasNextPage ~= true or type(info.endCursor) ~= "string" or info.endCursor == ""
            or seenCursors[info.endCursor] then
            Fail("Ungültige Seitennavigation der Anlageklassen.")
        end
        after = info.endCursor
        seenCursors[after] = true
    end
end

local function PortfolioAssetClasses(goal)
    if type(goal.slug) ~= "string" or goal.slug == "" then
        return {}
    end
    if not assetClassesByGoal then
        -- securityData.type beschreibt ETF/FUND, nicht die Anlageklasse.
        -- DepotAsset.className ist ergänzende Anzeigeinformation. Ein Fehler
        -- verwirft alle bislang geladenen Klassen, aber keine Finanzdaten.
        local ok, classes = pcall(LoadAssetClasses)
        if ok and type(classes) == "table" then
            assetClassesByGoal = classes
        else
            print("Whitebox: Anlageklassen nicht verfügbar; Namen und Buchungstexte werden ohne Zusatz übernommen.")
            assetClassesByGoal = {}
        end
    end
    return assetClassesByGoal[goal.slug] or {}
end

-- ---------------------------------------------------------------------------
-- Texte und MoneyMoney-Daten aufbauen
-- ---------------------------------------------------------------------------

local function SecurityName(name, className)
    name = Text(name)
    if type(className) ~= "string" or className == "" then
        return name
    end
    local suffix = " (" .. className .. ")"
    if name:sub(-#suffix) == suffix then
        return name
    end
    return name .. suffix
end

local function ApproximatePrice(amount, quantity)
    -- Der centgerundete Buchungsbetrag enthält keinen exakten Ausführungskurs.
    -- Sein Quotient mit der Stückzahl darf nur als Näherungswert erscheinen.
    local shares
    if type(quantity) == "number" or type(quantity) == "string" then
        shares = tonumber(quantity)
    end
    if not shares or shares == 0 or shares ~= shares or math.abs(shares) == math.huge then
        return nil
    end
    local price = math.abs(amount / shares)
    if price == 0 or price ~= price or price == math.huge then
        return nil
    end
    local formatted = string.format("%.3f", price):gsub("0+$", ""):gsub("%.$", "")
    if tonumber(formatted) == 0 then
        formatted = string.format("%.6g", price)
    end
    return formatted
end

local function CashOrderText(description, number)
    -- Beispiel mit künstlichen Kennungen: "Ausführung ORDER Verkauf IE00TEST0001 987654321".
    -- Der Titel erhält die kanonische Schreibweise; beide Referenzen gehören
    -- in purpose. name wird ausdrücklich gesetzt, statt Zeilen aufzuteilen.
    local normalized = Text(description):gsub("%s+", " "):match("^%s*(.-)%s*$")
    local orderText, reference = normalized:match("^(.-) (%d+)$")
    orderText = orderText or normalized
    local orderWord, action, isin = orderText:match("^Ausführung (%S+) (%S+) (%u%u[%u%d]+)$")
    if not orderWord or orderWord:lower() ~= "order" then
        return nil
    end
    local actionNames = {kauf = "Kauf", verkauf = "Verkauf"}
    action = actionNames[action:lower()]
    if not action or #isin ~= 12 then
        return nil
    end
    local title = "Ausführung Order " .. action .. " " .. isin
    local references = {}
    if reference then
        table.insert(references, reference)
    end
    number = Text(number)
    if number ~= "" and number ~= reference then
        table.insert(references, number)
    end
    return title, table.concat(references, " ")
end

local function CashTransactionText(row)
    local name, purpose = CashOrderText(row.description, row.number)
    if name then
        return name, purpose
    end
    -- Andere Buchungsarten unverändert als Beschreibung behandeln.
    purpose = Text(row.description)
    local number = Text(row.number)
    if number ~= "" then
        if purpose ~= "" then
            purpose = number .. " " .. purpose
        else
            purpose = "Referenz " .. number
        end
    end
    return nil, purpose
end

local function DepotTransactionText(row, classes, amount)
    local lines = {}
    local description = Text(row.description)
    if description ~= "" then
        table.insert(lines, description)
    end
    local className = classes[Text(row.isin)]
    if type(className) == "string" and className ~= "" then
        table.insert(lines, className)
    end
    if Text(row.productName) ~= "" then
        table.insert(lines, Text(row.productName))
    end
    if Text(row.quantity) ~= "" then
        local shares = "Anteile " .. Text(row.quantity)
        local price = ApproximatePrice(amount, row.quantity)
        if price then
            shares = shares .. " Kurs ca. " .. price
        end
        table.insert(lines, shares)
    end
    local reference = ""
    if Text(row.isin) ~= "" then
        reference = "ISIN " .. Text(row.isin)
    end
    if Text(row.number) ~= "" then
        local separator = reference ~= "" and " " or ""
        reference = reference .. separator .. "TAN " .. Text(row.number)
    end
    if reference ~= "" then
        table.insert(lines, reference)
    end
    return table.concat(lines, "\n")
end

local function ReadTransactions(rows, isDepot, classes)
    RequireTable(rows, isDepot and "depotTransactions" or "cashTransactions")
    local transactions = {}
    for _, row in ipairs(rows) do
        RequireTable(row, "Umsatz")
        -- Der gebuchte Betrag samt Vorzeichen ist maßgeblich, nie Anteile * Kurs.
        local amount, currency = Amount(row.value, "Umsatzbetrag")
        local name, purpose
        if isDepot then
            purpose = DepotTransactionText(row, classes, amount)
        else
            name, purpose = CashTransactionText(row)
        end
        table.insert(transactions, {
            bookingDate = IsoDateStr2Timestamp(row.date),
            name = name, purpose = purpose, amount = amount, currency = currency
        })
    end
    table.sort(transactions, function(a, b)
        return a.bookingDate > b.bookingDate
    end)
    return transactions
end

local function PerformanceSecurities(report)
    RequireTable(report, "performanceReport")
    local securities = {}
    local function Add(key, label, value, unit)
        local formatted = "nicht verfügbar"
        if value ~= nil then
            formatted = string.format("%.2f", Number(value, key)) .. unit
        end
        -- Reine Informationszeilen: Sie dürfen den Kontogesamtwert nicht erhöhen.
        table.insert(securities, {
            name = label .. ": " .. formatted,
            isin = "Performance " .. key, market = "Whitebox",
            quantity = 0, price = 0, amount = 0, tradeTimestamp = Now()
        })
    end
    Add("end_assets", "Vermögensstand", Amount(report.endAssets, "endAssets", "EUR"), " €")
    -- Die neue API liefert bereits Prozentwerte; keine Multiplikation mit 100.
    Add("mwr", "Geldgewichtete Rendite", report.moneyWeightedReturnInPercentage, " %")
    Add("yearly_mwr", "Geldgewichtete Rendite annualisiert", report.moneyWeightedReturnAnnualizedInPercentage, " %")
    -- Anzeigename und Kennung bleiben kompatibel zum bisherigen MoneyMoney-Depot.
    -- returnInEuro stimmte beim API-Abgleich mit den alten Erträgen + Kosten überein.
    Add("sum_of_erfolgsrelevante_kapitalveraenderungen", "Erfolgsrelevante Kapitalveränderungen",
        Amount(report.returnInEuro, "returnInEuro", "EUR"), " €")
    return {securities = securities}
end

-- ---------------------------------------------------------------------------
-- Abrufe für die unterschiedlichen Kontoansichten
-- ---------------------------------------------------------------------------

local function RefreshHoldings(account, goal, variables)
    local data = GraphQL("MoneyMoneyAssets", ASSETS_QUERY, variables)
    local rows = RequireTable(RequireTable(data.assets, "assets").securityData, "assets.securityData")
    local classes = #rows > 0 and PortfolioAssetClasses(goal) or {}
    local securities = {}
    for _, row in ipairs(rows) do
        RequireTable(row, "Depotposition")
        if Text(row.isin) == "" then
            Fail("ISIN einer Depotposition fehlt.")
        end
        local amount = Amount(row.totalValue, "Depotposition", account.currency or "EUR")
        local security = {
            name = SecurityName(row.name, classes[row.isin]), isin = row.isin,
            quantity = Number(row.shares, "shares"), amount = amount,
            tradeTimestamp = Now()
        }
        -- Fehlende optionale Kurse auslassen, statt einen Nullkurs zu erfinden.
        if row.marketPrice ~= nil then
            security.price = Number(row.marketPrice, "marketPrice")
        end
        if row.averagePurchasePrice ~= nil then
            security.purchasePrice = Number(row.averagePurchasePrice, "averagePurchasePrice")
        end
        table.insert(securities, security)
    end
    return {securities = securities}
end

local function RefreshBalancesAndTransactions(account, goal, isDepot, since, variables)
    -- Ohne since wird keine künstliche Untergrenze gesetzt; der Server bestimmt
    -- dann, wie viel Historie verfügbar ist. Alle Daten nur für dieses Depot laden.
    if since then
        variables.from = os.date("%Y-%m-%d", math.floor(since))
    end
    variables.to = os.date("%Y-%m-%d", Now())
    local operation, query = "MoneyMoneyCash", CASH_QUERY
    if isDepot then
        operation, query = "MoneyMoneyDepot", DEPOT_QUERY
    end
    local data = GraphQL(operation, query, variables)
    local portfolio = OnePortfolio(data, Text(goal.portfolioId))
    local balanceMoney
    if isDepot then
        balanceMoney = RequireTable(portfolio.depotAccount, "depotAccount").currentValue
    else
        balanceMoney = RequireTable(portfolio.cashAccount, "cashAccount").balance
    end
    local balance = Amount(balanceMoney, "Kontostand", account.currency or "EUR")
    local rows
    if isDepot then
        rows = RequireTable(portfolio.depotTransactions, "depotTransactions")
    else
        rows = portfolio.cashTransactions
    end
    local classes = isDepot and #rows > 0 and PortfolioAssetClasses(goal) or {}
    return {balance = balance, transactions = ReadTransactions(rows, isDepot, classes)}
end

-- ---------------------------------------------------------------------------
-- MoneyMoney-Einsprungspunkte
-- ---------------------------------------------------------------------------

function SupportsBank(protocol, bankCode)
    return protocol == ProtocolWebBanking and bankCode == "Whitebox"
end

-- MoneyMoney gibt die Signatur vor; username2 und username3 werden nicht benötigt.
function InitializeSession(protocol, bankCode, username, username2, password, username3)
    ResetSessionState()
    connection = Connection()
    connection.language = "de-DE"

    local page = HTML(connection:get(BASE_URL .. "/login"))
    local email = page:xpath("//input[@name='session[email]']")
    local pass = page:xpath("//input[@name='session[password]']")
    local button = page:xpath("//*[@id='login-btn']")
    if email:length() ~= 1 or pass:length() ~= 1 or button:length() ~= 1 then
        return "Whitebox: Das Anmeldeformular wurde geändert."
    end
    email:attr("value", username)
    pass:attr("value", password)
    -- Der native Formularversand erhält versteckte authenticity_token-Felder
    -- und die Cookies derselben Connection. Es wird kein POST-Body nachgebaut.
    local response = HTML(connection:request(button:click()))
    walletId = string.match(connection:getBaseURL(), "^https://inside%.whitebox%.eu/w/([^/?#]+)/")
    if not walletId then
        if response:xpath("//input[@name='session[password]']"):length() > 0 then
            return LoginFailed
        end
        return "Whitebox: Anmeldung nicht abgeschlossen. Bitte Hinweise auf der Whitebox-Webseite prüfen."
    end

    -- Die Rails-Sitzung liefert das Bearer-Token für die anschließenden Abfragen.
    local content = connection:request("GET", BASE_URL .. "/api/onboarding/session", "", nil, {
        Accept = "application/json", ["X-Requested-With"] = "XMLHttpRequest"
    })
    local session = ReadJSON(content, "Sitzung")
    if type(session.authToken) ~= "string" or session.authToken == "" then
        return "Whitebox: Die Sitzung liefert kein Zugriffstoken. Bitte erneut auf der Webseite anmelden."
    end
    authToken, csrfToken = session.authToken, session.csrfToken
end

-- knownAccounts bleibt unbenutzt: Die Server-Anlagen bestimmen die Kontenliste.
function ListAccounts(knownAccounts)
    LoadGoals()
    local accounts = {}
    local accountViews = {
        {prefix = "KONTO", label = "Konto", accountType = AccountTypeSavings, hasSecurities = false},
        {prefix = "DEPOT", label = "Depot", accountType = AccountTypePortfolio, hasSecurities = false},
        {prefix = "PERFORMANCE", label = "Performance", accountType = AccountTypePortfolio, hasSecurities = true},
        {prefix = "PORTFOLIO", label = "Portfolio", accountType = AccountTypePortfolio, hasSecurities = true}
    }
    for _, goal in ipairs(goals) do
        if goal.status == "ACTIVE" and Text(goal.portfolioId) ~= "" then
            local goalName = Text(goal.name) ~= "" and goal.name or goal.accountKey
            for _, view in ipairs(accountViews) do
                table.insert(accounts, {
                    name = view.label .. " " .. goalName,
                    accountNumber = view.prefix .. "_" .. goal.accountKey,
                    currency = "EUR", type = view.accountType, portfolio = view.hasSecurities
                })
            end
        end
    end
    if #accounts == 0 then
        Fail("Keine aktiven Anlagen mit zugeordnetem Depot gefunden. Bitte die Anlagen auf der Whitebox-Webseite prüfen.")
    end
    return accounts
end

function RefreshAccount(account, since)
    -- Beim normalen Rundruf ruft MoneyMoney ListAccounts nicht vorher auf.
    LoadGoals()
    local prefix, key = string.match(Text(account.accountNumber), "^([A-Z]+)_(.+)$")
    if prefix ~= "KONTO" and prefix ~= "DEPOT" and prefix ~= "PORTFOLIO" and prefix ~= "PERFORMANCE" then
        Fail("Unbekannte Kontoart. Bitte die Kontenliste erneut abrufen.")
    end
    local goal = goalsByKey[key]
    if not goal then
        Fail("Die gespeicherte Anlage wurde nicht gefunden. Bitte nach neuen Konten suchen.")
    end
    local portfolioId = Text(goal.portfolioId)
    if portfolioId == "" then
        Fail("Dieser Anlage ist noch kein Depot zugeordnet.")
    end
    local variables = {walletId = walletId, portfolioIds = {portfolioId}}
    if prefix == "PORTFOLIO" then
        return RefreshHoldings(account, goal, variables)
    end
    if prefix == "PERFORMANCE" then
        local data = GraphQL("MoneyMoneyPerformance", PERFORMANCE_QUERY, variables)
        return PerformanceSecurities(OnePortfolio(data, portfolioId).performanceReport)
    end
    return RefreshBalancesAndTransactions(account, goal, prefix == "DEPOT", since, variables)
end

function EndSession()
    if not connection then
        return
    end
    local headers = {Accept = "application/json", ["X-Requested-With"] = "XMLHttpRequest"}
    if type(csrfToken) == "string" and csrfToken ~= "" then
        headers["X-CSRF-Token"] = csrfToken
    end
    ResetSessionState()
    -- Die ursprüngliche Rails-Abmeldung verwendet POST mit Methodenüberschreibung.
    connection:request("POST", BASE_URL .. "/logout", "_method=delete",
        "application/x-www-form-urlencoded", headers)
end
