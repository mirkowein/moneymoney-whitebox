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
-- scraping with the GraphQL queries used by Whitebox frontend 2.10.1.
-- 1.17 (2026-10-21): Restore asset-class suffixes in security names.
-- KONTO + DEPOT or KONTO + PORTFOLIO represent one goal's assets.
-- PERFORMANCE contains information only and contributes no balance.

local BASE_URL = "https://inside.whitebox.eu"

WebBanking {
    version = 1.17,
    url = BASE_URL .. "/login",
    services = {"Whitebox"},
    description = "Whitebox"
}

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

local function Fail(message)
    error("Whitebox: " .. message, 0)
end

local function ReadJSON(content, context)
    local ok, result = pcall(function() return JSON(content):dictionary() end)
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
    local number = (type(value) == "number" or type(value) == "string") and tonumber(value) or nil
    if not number or number ~= number or number == math.huge or number == -math.huge then
        Fail("Ungültiger Zahlenwert für " .. field .. ".")
    end
    return number
end

local function Text(value)
    if type(value) == "string" or type(value) == "number" then return tostring(value) end
    return ""
end

local function Now()
    if MM and MM.time then return math.floor(MM.time()) end
    return os.time()
end

local function Amount(money, field, expectedCurrency)
    RequireTable(money, field)
    local currency = RequireTable(money.currency, field .. ".currency").isoCode
    if type(currency) ~= "string" or currency == "" then Fail("Währung fehlt: " .. field .. ".") end
    if expectedCurrency and currency ~= expectedCurrency then
        Fail("Unerwartete Währung bei " .. field .. ": " .. currency .. ".")
    end
    return Number(money.amount, field .. ".amount"), currency
end

local function GraphQL(operation, query, variables)
    if not authToken then Fail("Keine aktive Sitzung. Bitte erneut anmelden.") end
    local body = JSON():set({operationName = operation, query = query, variables = variables}):json()
    local headers = {Accept = "application/json", Authorization = "Bearer " .. authToken}
    local content = connection:request("POST", BASE_URL .. "/graphql", body, "application/json", headers)
    local result = ReadJSON(content, operation)
    if result.errors ~= nil then
        RequireTable(result.errors, "errors")
        for _, item in pairs(result.errors) do
            if type(item) == "table" and type(item.extensions) == "table"
                and item.extensions.code == "UNAUTHENTICATED" then
                Fail("Sitzung abgelaufen. Bitte erneut anmelden.")
            end
            -- Do not print response bodies, credentials or session tokens.
            Fail("Die Datenabfrage " .. operation .. " wurde abgewiesen: " ..
                (type(item) == "table" and Text(item.message) or "GraphQL-Fehler"))
        end
    end
    return RequireTable(result.data, operation .. ".data")
end

local function LoadGoals()
    if goals then return end
    local data = GraphQL("MoneyMoneyGoals", GOALS_QUERY, {walletId = walletId})
    local loaded = RequireTable(data.wealthGoals, "wealthGoals")
    local byKey = {}
    for _, goal in ipairs(loaded) do
        RequireTable(goal, "wealthGoals[]")
        if Text(goal.id) == "" then Fail("Die Anlagenkennung fehlt.") end
        -- Keep the complete server-provided slug, including numeric suffixes.
        -- Existing KONTO_<slug>, DEPOT_<slug>, ... identifiers remain usable.
        local key = Text(goal.slug)
        if key == "" then key = Text(goal.id) end
        if byKey[key] then Fail("Whitebox hat doppelte Anlagenkennungen geliefert.") end
        goal.accountKey = key
        byKey[key] = goal
    end
    goals, goalsByKey = loaded, byKey
end

function SupportsBank(protocol, bankCode)
    return protocol == ProtocolWebBanking and bankCode == "Whitebox"
end

function InitializeSession(protocol, bankCode, username, username2, password, username3)
    authToken, csrfToken, walletId, goals, goalsByKey = nil, nil, nil, nil, nil
    assetClassesByGoal = nil
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
    -- MoneyMoney includes the hidden Rails authenticity_token and cookies.
    local response = HTML(connection:request(button:click()))
    walletId = string.match(connection:getBaseURL(), "^https://inside%.whitebox%.eu/w/([^/?#]+)/")
    if not walletId then
        if response:xpath("//input[@name='session[password]']"):length() > 0 then return LoginFailed end
        return "Whitebox: Anmeldung nicht abgeschlossen. Bitte Hinweise auf der Whitebox-Webseite prüfen."
    end

    -- The new frontend exchanges the Rails session cookie for a GraphQL token.
    local content = connection:request("GET", BASE_URL .. "/api/onboarding/session", "", nil,
        {Accept = "application/json", ["X-Requested-With"] = "XMLHttpRequest"})
    local session = ReadJSON(content, "Sitzung")
    if type(session.authToken) ~= "string" or session.authToken == "" then
        return "Whitebox: Die Sitzung liefert kein Zugriffstoken. Bitte erneut auf der Webseite anmelden."
    end
    authToken = session.authToken
    csrfToken = session.csrfToken
end

function ListAccounts(knownAccounts)
    LoadGoals()
    local accounts = {}
    local types = {
        {"KONTO", "Konto", AccountTypeSavings, false},
        {"DEPOT", "Depot", AccountTypePortfolio, false},
        {"PERFORMANCE", "Performance", AccountTypePortfolio, true},
        {"PORTFOLIO", "Portfolio", AccountTypePortfolio, true}
    }
    for _, goal in ipairs(goals) do
        if goal.status == "ACTIVE" and Text(goal.portfolioId) ~= "" then
            for _, kind in ipairs(types) do
                table.insert(accounts, {
                    name = kind[2] .. " " .. (Text(goal.name) ~= "" and goal.name or goal.accountKey),
                    accountNumber = kind[1] .. "_" .. goal.accountKey,
                    currency = "EUR", type = kind[3], portfolio = kind[4]
                })
            end
        end
    end
    if #accounts == 0 then
        Fail("Keine aktiven Anlagen mit zugeordnetem Depot gefunden. Bitte die Anlagen auf der Whitebox-Webseite prüfen.")
    end
    return accounts
end

function IsoDateStr2Timestamp(dateStr)
    local year, month, day = string.match(Text(dateStr), "^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
    if not year then Fail("Ungültiges Buchungsdatum.") end
    local timestamp = os.time({year = tonumber(year), month = tonumber(month), day = tonumber(day), hour = 12})
    if not timestamp or os.date("%Y-%m-%d", timestamp) ~= dateStr then Fail("Ungültiges Buchungsdatum.") end
    return timestamp
end

local function OnePortfolio(data, portfolioId)
    local portfolios = RequireTable(data.portfolios, "portfolios")
    -- Never aggregate all portfolios if the server ignored the requested ID.
    if #portfolios ~= 1 or Text(portfolios[1].id) ~= portfolioId then
        Fail("Das angeforderte Depot konnte nicht eindeutig zugeordnet werden.")
    end
    return portfolios[1]
end

local function PortfolioAssetClasses(goal)
    -- GraphQL's securityData.type is ETF/FUND/etc., not Whitebox's more
    -- specific allocation class (e.g. "Aktien Schwellenländer"). Detailed
    -- GraphQL DepotAsset metadata contains the original className instead.
    -- Treat it as optional display metadata, matched by goal slug and ISIN.
    if type(goal.slug) ~= "string" or goal.slug == "" then return {} end
    if assetClassesByGoal then return assetClassesByGoal[goal.slug] or {} end
    local ok, classes = pcall(function()
        local result, after, seenCursors = {}, nil, {}
        repeat
            local data = GraphQL("MoneyMoneyAssetClasses", ASSET_CLASSES_QUERY, {walletId = walletId, after = after})
            local page = RequireTable(RequireTable(data.wallet, "wallet").goals, "wallet.goals")
            for _, entry in ipairs(RequireTable(page.nodes, "wallet.goals.nodes")) do
                RequireTable(entry, "wallet.goals.nodes[]")
                if type(entry.slug) == "string" and entry.slug ~= "" and entry.portfolio ~= nil then
                    local portfolio = RequireTable(entry.portfolio, "Anlageklassen-Depot")
                    local rows = portfolio.depotAssets
                    if rows ~= nil then
                        RequireTable(rows, "depotAssets")
                        local byIsin = result[entry.slug] or {}
                        result[entry.slug] = byIsin
                        for _, row in ipairs(rows) do
                            if type(row) == "table" and type(row.isin) == "string" and row.isin ~= ""
                                and type(row.className) == "string" then
                                local className = row.className:match("^%s*(.-)%s*$")
                                if className ~= "" then
                                    -- Never guess between conflicting classifications.
                                    if byIsin[row.isin] == nil then byIsin[row.isin] = className
                                    elseif byIsin[row.isin] ~= className then byIsin[row.isin] = false end
                                end
                            end
                        end
                    end
                end
            end
            local info = RequireTable(page.pageInfo, "wallet.goals.pageInfo")
            if info.hasNextPage == false then break end
            if info.hasNextPage ~= true or type(info.endCursor) ~= "string" or info.endCursor == ""
                or seenCursors[info.endCursor] then Fail("Ungültige Seitennavigation der Anlageklassen.") end
            after = info.endCursor
            seenCursors[after] = true
        until false
        return result
    end)
    if not ok or type(classes) ~= "table" then
        print("Whitebox: Anlageklassen nicht verfügbar; Wertpapiernamen werden ohne Zusatz übernommen.")
        assetClassesByGoal = {}
    else
        assetClassesByGoal = classes
    end
    return assetClassesByGoal[goal.slug] or {}
end

local function SecurityName(name, className)
    name = Text(name)
    if type(className) ~= "string" or className == "" then return name end
    local suffix = " (" .. className .. ")"
    if name:sub(-#suffix) == suffix then return name end
    return name .. suffix
end

local function ReadTransactions(rows, isDepot)
    RequireTable(rows, isDepot and "depotTransactions" or "cashTransactions")
    local transactions = {}
    for _, row in ipairs(rows) do
        RequireTable(row, "Umsatz")
        local amount, currency = Amount(row.value, "Umsatzbetrag")
        local purpose = Text(row.description)
        if isDepot then
            if Text(row.productName) ~= "" then purpose = purpose .. "\n" .. row.productName end
            if Text(row.isin) ~= "" then purpose = purpose .. "\nISIN " .. row.isin end
            if row.quantity ~= nil then purpose = purpose .. "\nAnteile " .. Text(row.quantity) end
        end
        if Text(row.number) ~= "" then purpose = purpose .. "\n" .. Text(row.number) end
        table.insert(transactions, {
            bookingDate = IsoDateStr2Timestamp(row.date),
            purpose = purpose, amount = amount, currency = currency
        })
    end
    table.sort(transactions, function(a, b) return a.bookingDate > b.bookingDate end)
    return transactions
end

local function PerformanceSecurities(report)
    RequireTable(report, "performanceReport")
    local result = {}
    local function Add(key, label, value, unit)
        -- A return may legitimately be null before the first investment.
        local formatted = value == nil and "nicht verfügbar" or (string.format("%.2f", Number(value, key)) .. unit)
        table.insert(result, {
            name = label .. ": " .. formatted,
            isin = "Performance " .. key, market = "Whitebox",
            quantity = 0, price = 0, amount = 0, tradeTimestamp = Now()
        })
    end
    Add("end_assets", "Vermögensstand", Amount(report.endAssets, "endAssets", "EUR"), " €")
    -- These GraphQL fields already contain percentages (no multiplication by 100).
    Add("mwr", "Geldgewichtete Rendite", report.moneyWeightedReturnInPercentage, " %")
    Add("yearly_mwr", "Geldgewichtete Rendite annualisiert", report.moneyWeightedReturnAnnualizedInPercentage, " %")
    Add("return_in_euro", "Wertentwicklung nach Kosten und Steuern", Amount(report.returnInEuro, "returnInEuro", "EUR"), " €")
    return {securities = result}
end

function RefreshAccount(account, since)
    LoadGoals() -- MoneyMoney does not call ListAccounts during a normal refresh.
    local prefix, key = string.match(Text(account.accountNumber), "^([A-Z]+)_(.+)$")
    if prefix ~= "KONTO" and prefix ~= "DEPOT" and prefix ~= "PORTFOLIO" and prefix ~= "PERFORMANCE" then
        Fail("Unbekannte Kontoart. Bitte die Kontenliste erneut abrufen.")
    end
    local goal = goalsByKey[key]
    if not goal then Fail("Die gespeicherte Anlage wurde nicht gefunden. Bitte nach neuen Konten suchen.") end
    local portfolioId = Text(goal.portfolioId)
    if portfolioId == "" then Fail("Dieser Anlage ist noch kein Depot zugeordnet.") end
    local variables = {walletId = walletId, portfolioIds = {portfolioId}}

    if prefix == "PORTFOLIO" then
        local data = GraphQL("MoneyMoneyAssets", ASSETS_QUERY, variables)
        local rows = RequireTable(RequireTable(data.assets, "assets").securityData, "assets.securityData")
        local classes = #rows > 0 and PortfolioAssetClasses(goal) or {}
        local securities = {}
        for _, row in ipairs(rows) do
            RequireTable(row, "Depotposition")
            if Text(row.isin) == "" then Fail("ISIN einer Depotposition fehlt.") end
            local amount = Amount(row.totalValue, "Depotposition", account.currency or "EUR")
            local security = {
                name = SecurityName(row.name, classes[row.isin]), isin = row.isin,
                quantity = Number(row.shares, "shares"), amount = amount,
                tradeTimestamp = Now()
            }
            -- Prices in the frontend are shown in EUR; omit missing prices
            -- instead of manufacturing a zero purchase price.
            if row.marketPrice ~= nil then security.price = Number(row.marketPrice, "marketPrice") end
            if row.averagePurchasePrice ~= nil then security.purchasePrice = Number(row.averagePurchasePrice, "averagePurchasePrice") end
            table.insert(securities, security)
        end
        return {securities = securities}
    elseif prefix == "PERFORMANCE" then
        local data = GraphQL("MoneyMoneyPerformance", PERFORMANCE_QUERY, variables)
        return PerformanceSecurities(OnePortfolio(data, portfolioId).performanceReport)
    end

    -- A missing `since` means the complete history, not an arbitrary cutoff.
    if since then variables.from = os.date("%Y-%m-%d", math.floor(since)) end
    variables.to = os.date("%Y-%m-%d", Now())
    local isDepot = prefix == "DEPOT"
    local data = GraphQL(isDepot and "MoneyMoneyDepot" or "MoneyMoneyCash",
        isDepot and DEPOT_QUERY or CASH_QUERY, variables)
    local portfolio = OnePortfolio(data, portfolioId)
    local money
    if isDepot then money = RequireTable(portfolio.depotAccount, "depotAccount").currentValue
    else money = RequireTable(portfolio.cashAccount, "cashAccount").balance end
    local balance = Amount(money, "Kontostand", account.currency or "EUR")
    -- Use the signed transaction value provided by Whitebox, never shares * price.
    local rows
    if isDepot then rows = portfolio.depotTransactions else rows = portfolio.cashTransactions end
    return {balance = balance, transactions = ReadTransactions(rows, isDepot)}
end

function EndSession()
    if not connection then return end
    local headers = {Accept = "application/json", ["X-Requested-With"] = "XMLHttpRequest"}
    if type(csrfToken) == "string" and csrfToken ~= "" then headers["X-CSRF-Token"] = csrfToken end
    authToken, csrfToken, walletId, goals, goalsByKey = nil, nil, nil, nil, nil
    assetClassesByGoal = nil
    -- Preserve Whitebox's Rails logout endpoint and method override.
    connection:request("POST", BASE_URL .. "/logout", "_method=delete",
        "application/x-www-form-urlencoded", headers)
end
