--
-- MoneyMoney Web Banking extension
-- http://moneymoney-app.com/api/webbanking
--
--
-- The MIT License (MIT)
--
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
--
-- Get balances for Whitebox.eu
--
-- Es werden 2 Accounts für jedes aktive Ziel angelegt
-- KONTO und DEPOT
-- Tipp: Zusammen als Kontogruppe mit Kontostand in Saldenleiste zusammenfassen, dann hat man den Gesamtwert des Ziels
--
-- Historie:
-- 1.00                        Initial
-- 1.01                        Fix for Currencies in Depot
-- 1.02                        Fix for ListAccounts
-- 1.03                        Fix for Login
-- 1.04                        New performance account for displaying Whitebox performance
-- 1.05                        New portfolio account. You may have to choose from DEPOT or PORTFOLIO.
-- 1.06                        Fix for new subdomain inside.whitebox.eu
-- 1.07                        Fix for new design
-- 1.08                        Fix for new portfolio design
-- 1.09                        Fix for Login
-- 1.10                        Fix for new urls
-- 1.11                        Remove debug on non-existing value; Fix Portfolio Import by https://github.com/calcosta
-- 1.12                        json for KONTO and DEPOT

WebBanking{version     = 1.12,
           url         = "https://inside.whitebox.eu",
           services    = {"Whitebox"},
           description = "Whitebox"}

function SupportsBank (protocol, bankCode)
  return protocol == ProtocolWebBanking and bankCode == "Whitebox"
end

local connection = nil
local loginresponse = nil
local connection = Connection()
local debug = false
local sub_url = ""

--------------------------------------------------------------------------------------------------------------------------
-- Session

function InitializeSession (protocol, bankCode, username, username2, password, username3)
    connection.language = "de-de"

        print ("Version" .. version)
    local response = HTML(connection:get(url))

    response:xpath("//input[@name='session[email]']"):attr("value", username)
    response:xpath("//input[@name='session[password]']"):attr("value", password)
    loginresponse = HTML(connection:request(response:xpath("//*[@id='login-btn']"):click()))
    if debug then
                print("Extract sub url")
    end
    -- https://inside.whitebox.eu/w/8d667b52-c8ec-48ce-9b0a-0e680a7123f5/goals
    sub_url = string.match(connection:getBaseURL() , "whitebox.eu/(.+)goals")

    -- should now be w/8d667b52-c8ec-48ce-9b0a-0e680a7123f5/
    if debug then
            print ("sub_url=", sub_url)
        end
    if (loginresponse:xpath("//*[@class='msg msg-large msg-error']"):text() == "Keine gültigen Zugangsdaten.") then
        return LoginFailed
    end
    if debug then
                print("End InitializeSession")
    end
end

--------------------------------------------------------------------------------------------------------------------------
-- Accounts
-- Es werden 2 Accounts für jedes aktive Ziel angelegt
-- KONTO und DEPOT
-- Tipp: Zusammen als Kontogruppe mit Kontostand in Saldenleiste zusammenfassen, dann hat man den Gesamtwert des Ziels

function ListAccounts(knownAccounts)
    local accounts = {}

        -- Buttons Einzahlen, um alle aktiven Goals zu bekommen
    loginresponse:xpath("//*/a[@class='js-deposit deposit-btn']"):each(
        function(index, element)
            local accountType = AccountTypeGiro
            local goal = string.match(element:attr("href") , "/goals/(.+)/projection")

                -- Insert Konto
                -- Präfix KONTO_
            table.insert(accounts,
            {
                name = "Konto " .. goal,
                accountNumber = "KONTO_" .. goal,
                currency = "EUR",
                type = AccountTypeSavings
            })

            -- Insert Portfolio / Depot
            -- Präfix DEPOT_
            table.insert(accounts,
            {
                name = "Depot " .. goal,
                accountNumber = "DEPOT_" .. goal,
                currency = "EUR",
                type = AccountTypePortfolio
            })
            -- Insert Portfolio / Performance
            -- Präfix PERFORMANCE_
            table.insert(accounts,
            {
                name = "Performance " .. goal,
                accountNumber = "PERFORMANCE_" .. goal,
                currency = "EUR",
                portfolio = true,
                type = AccountTypePortfolio
            })
            -- Insert Portfolio / Portfolio
            -- Präfix PORTFOLIO_
            table.insert(accounts,
            {
                name = "Portfolio " .. goal,
                accountNumber = "PORTFOLIO_" .. goal,
                currency = "EUR",
                portfolio = true,
                type = AccountTypePortfolio
            })
        end
    )
    return accounts
end

--------------------------------------------------------------------------------------------------------------------------
-- Transaktionen

function RefreshAccount(account, since)
        local transactions = {}
        local balance = nil
        local type_text = nil

        -- Prefix KONTO oder DEPOT erkennen
        local prefix, goal = string.match(account.accountNumber , "^(.+)_(.+)$")

        -- Seit wann als Text DD.MM.YYYY
        local timeStrStart = os.date('%d.%m.%Y', since)
        local timeStrEnd = os.date('%d.%m.%Y', MM.time())

        if debug then
                        print("timeStrStart:", timeStrStart)
                        print("timeStrEnd:", timeStrEnd)
        end

        -- Typ KONTO
        if ( prefix == "KONTO" ) then
                type_text = 'Kontostand'

                -- build url
                -- https://inside.whitebox.eu/w/8d667b52-c8ec-48ce-9b0a-0e680a7123f5/goals/sparen-2024/statements
                                url = "https://inside.whitebox.eu/" .. sub_url .. "goals/" .. goal .. "/statements?statements_query[query_class]=account&statements_query[timespan]=none&statements_query[start_date]=" .. timeStrStart .. "&statements_query[end_date]=" .. timeStrEnd

                                -- unbedingt den header setzten, sonst antwortet whitebox mit Fehler
                                headers={
                                        ["Accept"]="application/json",
                                }

                                -- Abfrage starten
                                local content, charset, mimeType = connection:request("GET",
                                                                                url,
                                                                                '',
                                                                                "application/x-www-form-urlencoded; charset=UTF-8",
                                                                                headers
                                                                                )

                                -- whitebox schickt html als json
                                -- Felder umwandeln
                                local fields = JSON(content):dictionary()

                                if debug then
                                        print("Fetched account:", account)
                                        print("  charset:", charset)
                                        print("  mimeType:", mimeType)
                                        print("  fields:", fields.html)
                                end

                                balance = fields.statements.cash_value

                                if debug then
                                        print("balance:", balance)
                                end

                                                                 for k, v in pairs(fields.statements.account_statements) do
                                            table.insert(transactions,
                                            {
                                                    bookingDate = IsoDateStr2Timestamp(v.bookingDate),
                                                    valueDate = IsoDateStr2Timestamp(v.valuta),
                                                    purpose = v.paymentPurpose[1] .. " " .. v.paymentPurpose[2] .. " " .. v.taNumber,
                                                    amount = v.amount.value



                                            })
                                            if debug then
                                                                                                   print("bookingDate:", v.bookingDate)
                                                                                                   print("  valueDate:", v.valuta)
                                                                                                   print("  purpose:", v.paymentPurpose[1] .. " " .. v.paymentPurpose[2])
                                                                                                   print("  amount:", v.amount.value)
                                                                                        end
                                end


        -- Typ DEPOT
        elseif ( prefix == "DEPOT" ) then
                type_text = 'Depotbestand'

                -- build url
                                url = "https://inside.whitebox.eu/" .. sub_url .. "goals/" .. goal .. "/statements?statements_query[query_class]=account&statements_query[timespan]=none&statements_query[start_date]=" .. timeStrStart .. "&statements_query[end_date]=" .. timeStrEnd

                                -- unbedingt den header setzten, sonst antwortet whitebox mit Fehler
                                headers={
                                        ["Accept"]="application/json",
                                }

                                -- Abfrage starten
                                local content, charset, mimeType = connection:request("GET",
                                                                                url,
                                                                                '',
                                                                                "application/x-www-form-urlencoded; charset=UTF-8",
                                                                                headers
                                                                                )

                                -- whitebox schickt html als json
                                -- Felder umwandeln
                                local fields = JSON(content):dictionary()

                                if debug then
                                        print("Fetched account:", account)
                                        print("  charset:", charset)
                                        print("  mimeType:", mimeType)
                                        print("  fields:", fields.html)
                                end


                                 balance = fields.statements.depot_value

                                if debug then
                                        print("balance:", balance)
                                end

                                                                 for k, v in pairs(fields.statements.depot_statements) do
                                            table.insert(transactions,
                                            {
                                                    bookingDate = IsoDateStr2Timestamp(v.bookingDate),
                                                    valueDate = IsoDateStr2Timestamp(v.valuta),
                                                    purpose = v.purposeLine[1] .. "\n" .. v.asset_class .. "\n" .. v.paper.name .. "\nAnteile " .. v.value.value .. " Kurs " .. v.price.value .. "\nISIN " .. v.paper.isin .. " TAN " .. v.taNumber,
                                                    amount = v.value.value * v.price.value,
                                                    currency =  v.price.currency


                                            })
                                            if debug then
                                                                                                   print("bookingDate:", v.bookingDate)
                                                                                                   print("  valueDate:", v.valuta)
                                                                                                   print("  purpose:", v.purposeLine[1])
                                                                                                   print("  amount:", v.value.value * v.price.value)
                                                                                        end
                                end

        -- Typ PERFORMANCE liefert JSON, wir werten nur 4 aus, weitere möglich
        elseif ( prefix == "PERFORMANCE" ) then

                -- build url
                url = "https://inside.whitebox.eu/" .. sub_url .. "goals/" .. goal .. "/performances?from=&to=&with_whitebox_fees=true&with_taxes=true"

                                -- unbedingt den header setzten, sonst antwortet whitebox mit Fehler
                                headers={
                                        ["Accept"]="application/json",
                                }

                                -- Abfrage starten
                                local content, charset, mimeType = connection:request("GET",
                                                                                url,
                                                                                '',
                                                                                "application/x-www-form-urlencoded; charset=UTF-8",
                                                                                headers
                                                                                )

                                -- whitebox schickt html als json
                                -- Felder umwandeln
                                local fields = JSON(content):dictionary()

                                if debug then
                                        print("Fetched account:", account)
                                        print("  charset:", charset)
                                        print("  mimeType:", mimeType)
                                        print("  fields:", fields.report)
                                end



                                table.insert(transactions,
                                                                {
                                                                                                name = "Vermögensstand: " .. string.format("%.2f", fields.report["end_assets"]) .. " €",
                                                                                                market = "Whitebox",
                                                                                                isin = "Performance end_assets",
                                                                                                currency = "EUR",
                                                                                                tradeTimestamp = os.time(),
                                                                                                currencyOfPrice = "EUR",
                                                                                                currencyOfPurchasePrice = "EUR"
                                                                }
                                )
                                table.insert(transactions,
                                                                {
                                                                                                name = "Geldgewichtete Rendite: " .. round2(fields.report["mwr"]*100,2) .. " %",
                                                                                                market = "Whitebox",
                                                                                                isin = "Performance mwr",
                                                                                                tradeTimestamp = os.time(),
                                                                                                currencyOfPurchasePrice = "EUR"
                                                                }
                                )
                                table.insert(transactions,
                                                                {
                                                                                                name = "Geldgewichtete Rendite annualisiert: " .. round2(fields.report["yearly_mwr"]*100,2) .. " %",
                                                                                                market = "Whitebox",
                                                                                                isin = "Performance yearly_mwr",
                                                                                                tradeTimestamp = os.time(),
                                                                                                currencyOfPurchasePrice = "EUR"
                                                                }
                                )
                                table.insert(transactions,
                                                                {
                                                                                                name = "Erfolgsrelevante Kapitalveränderungen: " ..  string.format("%.2f", fields.report["sum_of_erfolgsrelevante_kapitalveraenderungen"]) .. " €",
                                                                                                market = "Whitebox",
                                                                                                isin = "Performance sum_of_erfolgsrelevante_kapitalveraenderungen",
                                                                                                tradeTimestamp = os.time(),
                                                                                                currencyOfPurchasePrice = "EUR"
                                                                }
                                )


                --end

                return {securities = transactions}

        -- Typ PORTFOLIO
        elseif ( prefix == "PORTFOLIO" ) then

                -- build url
                                        url = "https://inside.whitebox.eu/" .. sub_url .. "goals/" .. goal .. "/portfolio"

                                -- unbedingt den header setzten, sonst antwortet whitebox mit Fehler
                                headers={
                                        ["Accept"]="application/json",
                                }

                                -- Abfrage starten
                                local content, charset, mimeType = connection:request("GET",
                                                                                url,
                                                                                '',
                                                                                "application/x-www-form-urlencoded; charset=UTF-8",
                                                                                headers
                                                                                )

                                -- whitebox schickt html als json
                                -- Felder umwandeln
                                local fields = JSON(content):dictionary()

                                if debug then
                                        print("Fetched account:", account)
                                        print("  charset:", charset)
                                        print("  mimeType:", mimeType)
                                end

                                 for k, v in pairs(fields.active_portfolio.table_data) do
                                            table.insert(transactions,
                                            {
                                                       name = v.fund_name .. " (" .. v.class_name .. ")",
                                                       isin = v.isin,
                                                       quantity = v.paper_quantity,
                                                       amount = v.rating_value,
                                                       tradeTimestamp = os.time(),
                                                       price = v.rating_price,
                                                       purchasePrice = v.buying_price

                                            })
                                end

                        return {securities = transactions}
        end
        return {balance = balance, transactions = transactions}
end

--------------------------------------------------------------------------------------------------------------------------
-- Helper: Text in Betrag wandeln
-- 2 Fälle: € 3.126,18  und  2.12,12 EUR

function Text2Val ( text )
        text = string.gsub(text, "â‚¬", "")
        text = string.gsub(text, "€ +", "")
        text = string.gsub(text, "EUR", "")
    text = string.gsub(text, "%.", "")
    text = string.gsub(text, ",", '.')
    text = tonumber(text)
    return text
end

--------------------------------------------------------------------------------------------------------------------------
-- Helper: Datum in Timestamp wandeln
-- DD.MM.YYYY

function DateStr2Timestamp(dateStr)
    local dayStr, monthStr, yearStr = string.match(dateStr, "(%d%d)%.(%d%d)%.(%d%d%d%d)")

    return os.time({
        year = tonumber(yearStr),
        month = tonumber(monthStr),
        day = tonumber(dayStr)
    })
end

--------------------------------------------------------------------------------------------------------------------------
-- Helper: Datum in Timestamp wandeln
-- YYYY-MM-DD

function IsoDateStr2Timestamp(dateStr)
    local yearStr, monthStr, dayStr  = string.match(dateStr, "(%d%d%d%d)%-(%d%d)%-(%d%d)")

    return os.time({
        year = tonumber(yearStr),
        month = tonumber(monthStr),
        day = tonumber(dayStr)
    })
end

--------------------------------------------------------------------------------------------------------------------------
-- Logout
-- Tricky, geht nur als POST

function EndSession ()
        url = "https://inside.whitebox.eu/logout"
        local content, charset, mimeType = connection:post(url ,"_method=delete")
end

--------------------------------------------------------------------------------------------------------------------------
-- Helper: dump

function dump(o)
   if type(o) == 'table' then
      local s = '{ '
      for k,v in pairs(o) do
         if type(k) ~= 'number' then k = '"'..k..'"' end
         s = s .. '['..k..'] = ' .. dump(v) .. ','
      end
      return s .. '} '
   else
      return tostring(o)
   end
end

--------------------------------------------------------------------------------------------------------------------------
-- Helper: first_split_string
-- liefert nur den ersten Text zurück, bis zu whitespaces

function first_split_string(s)
        for i in string.gmatch(s, "%S+") do
                return tostring(i)
        end
end

--------------------------------------------------------------------------------------------------------------------------
-- Helper: round2
-- Rundes aus Anzahl Nachkommastellen

function round2(num, numDecimalPlaces)
  return tonumber(string.format("%." .. (numDecimalPlaces or 0) .. "f", num))
end

-- SIGNATURE: MC0CFQCGBGxvHP1i8flamyNPQhX0In8bEwIUSYefD/AxwSTMXAg7Nph0E4iJfl8=
