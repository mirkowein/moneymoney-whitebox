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

WebBanking{version     = 1.08,
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

--------------------------------------------------------------------------------------------------------------------------
-- Session

function InitializeSession (protocol, bankCode, username, username2, password, username3)
    connection.language = "de-de"

        print ("Version" .. version)
    local response = HTML(connection:get(url))

    response:xpath("//input[@name='session[email]']"):attr("value", username)
    response:xpath("//input[@name='session[password]']"):attr("value", password)
    loginresponse = HTML(connection:request(response:xpath("//*[@id='new_session']/*/button"):click()))

    if (loginresponse:xpath("//*[@class='msg msg-large msg-error']"):text() == "Keine gültigen Zugangsdaten.") then
        return LoginFailed
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
                                url = "https://inside.whitebox.eu/goals/" .. goal .. "/statements?statements_query[query_class]=account&statements_query[timespan]=none&statements_query[start_date]=" .. timeStrStart .. "&statements_query[end_date]=" .. timeStrEnd

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

                                -- Wie bisher weiter als HTML
                                -- Gleichzeitig Wandlung von UTF-8 in ISO-8859-1
                                local response = HTML(MM.toEncoding('ISO-8859-1', fields.html))



                                -- https://devhints.io/xpath
                                -- //*/div[@class='data' ]
                                -- //*/span[@class='big' and contains(text(),"Go")]
                                -- [contains(text(),"Go")]
                                -- //*/sup[contains(text(),"Kontostand")]
                                -- //*/sup[contains(text(),"Kontostand")]/following-sibling::span

                -- Ermittle Kontostand vom KONTO
                local balance_text = response:xpath("//*/sup[contains(text(),'" .. type_text .. "')]/following-sibling::span"):text()

                if debug then
                                                        print("balance_text:", balance_text)
                                end

                                -- Wert aus Text
                balance = Text2Val ( balance_text)

                                if debug then
                                                        print("balance_text:", balance_text)
                                                        print("balance:", balance)
                                end

                                -- //*/sup[contains(text(),"Kontostand")]/following-sibling::span
                                -- //*/tbody[@class="table-row-group"]/*/*/div
                                -- //*/tbody[contains(id(),"account-statement"]/*/*/div
                                -- //*/tbody[contains(@id, 'account-statement')]/*/*/div


                -- Ermittle Transaktionen
                response:xpath("//*/tbody[contains(@id, 'account-statement')]"):each(
                        function(index, element)

                                        -- Valuta ist erstes span im tbody
                                        local Valuta = element:xpath(".//span"):text()
                                        -- Buchungsinformation ist erstes div mit class 'data subject'
                                        local Buchungsinformationen = element:xpath(".//div[@class='data subject']"):text()
                                                                -- Betrag ist das erste span mit class '*-label'
                                                                local Betrag = element:xpath(".//span[contains(@class, '-label')]"):text()
                                                                -- Buchtag bei Whitebox
                                                                local  Buchtag = element:xpath(".//tr[@class='tr-collapsed']//div[@class='data date']//span"):text()
                                                                -- TAN bei Whitebox
                                                                local TAN = element:xpath(".//tr[@class='tr-collapsed']//div[@class='data']//span"):text()

                                -- //*/tbody[contains(@id, 'account-statement')]//tr[@class='tr-collapsed']//div[@class='data date']
                                -- //*/tbody[contains(@id, 'account-statement')]//tr[@class='tr-collapsed']//div[@class='data date']//span


                                                                if debug then
                                                                        print("Valuta:", Valuta)
                                                                        print("Buchungsinformationen:", Buchungsinformationen)
                                                                        print("Betrag:", Betrag)
                                                                        print("Buchtag:", Buchtag)
                                                                        print("TAN:", TAN)
                                                                end


                                                                -- Tabelle der Transaktionen füllen
                                table.insert(transactions,
                                       {
                                               bookingDate = DateStr2Timestamp( Buchtag ),
                                               valueDate = DateStr2Timestamp( Valuta ),
                                               purpose = Buchungsinformationen .. " " .. TAN,
                                               amount = Text2Val ( Betrag )
--                                                                                          transactionCode = TAN
                                       }
                               )
                        end
                )

        -- Typ DEPOT
        elseif ( prefix == "DEPOT" ) then
                type_text = 'Depotbestand'

                -- build url
                                url = "https://inside.whitebox.eu/goals/" .. goal .. "/statements?statements_query[query_class]=account&statements_query[timespan]=none&statements_query[start_date]=" .. timeStrStart .. "&statements_query[end_date]=" .. timeStrEnd

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

                                -- Wie bisher weiter als HTML
                                -- Gleichzeitig Wandlung von UTF-8 in ISO-8859-1
                                local response = HTML(MM.toEncoding('ISO-8859-1', fields.html))

                -- Ermittle Kontostand vom DEPOT
                local balance_text = response:xpath("//*/sup[contains(text(),'" .. type_text .. "')]/following-sibling::span"):text()

                if debug then
                                                        print("balance_text:", balance_text)
                                end

                                -- Wert aus Text
                balance = Text2Val ( balance_text)

                                if debug then
                                                        print("balance_text:", balance_text)
                                                        print("balance:", balance)
                                end


                -- Ermittle Transaktionen
                response:xpath("//*/tbody[contains(@id, 'depot-statement')]"):each(
                        function(index, element)
                                -- Immer //*/tbody[contains(@id, 'depot-statement')]    + unten ohne führenden .
                                -- bspw. //*/tbody[contains(@id, 'depot-statement')]//tr[@class='tr-collapsed']//div[@class='data date']//span

                                -- Valuta ist erstes span im tbody
                                        local Valuta = element:xpath(".//span"):text()
                                        -- Buchungsinformation ist erstes div mit class 'data subject'
                                        local Buchungsinformationen = element:xpath(".//div[@class='data subject']"):text()
                                                                -- Betrag ist das erste span mit class '*-label'
                                                                local Wert = element:xpath(".//span[contains(@class, '-label')]"):text()
                                                                -- Buchtag bei Whitebox
                                                                local  Buchtag = element:xpath(".//tr[@class='tr-collapsed']//div[@class='data date']//span"):text()
                                                                -- Assetklasse
                                                                local Assetklasse = element:xpath(".//tr[@class='tr-collapsed']//div[@class='data date-spacing']//span"):text()
                                                                -- Produktbezeichnung
                                                                local Produktbezeichnung = element:xpath(".//tr[@class='tr-collapsed']//div[@class='data']//span"):text()
                                                                -- Anteile
                                                                local Anteile = element:xpath(".//tr[@class='tr-collapsed']//div[@class='data text-right']//span"):text()
                                                                -- Kurs
                                                                local Kurs         = element:xpath(".//tr[@class='tr-collapsed']//div[@class='data text-right']//span[3]"):text()
                                                                -- ISIN
                                                                local ISIN = element:xpath(".//tr[@class='tr-collapsed']//div[2][@class='data text-right']//span"):text()
                                                                -- TAN
                                                                local TAN         = element:xpath(".//tr[@class='tr-collapsed']//div[2][@class='data text-right']//span[3]"):text()

                                                                 -- Trennen von Betrag und Währung
                                local Betrag, Waehrung = string.match(Wert, '(-?%d+,?%d+)%s*(%w+)' )

                                                                if debug then
                                                                        print("Valuta:", Valuta)
                                                                        print("Buchungsinformationen:", Buchungsinformationen)
                                                                        print("Betrag:", Betrag)
                                                                        print("Waehrung:", Waehrung)
                                                                        print("Buchtag:", Buchtag)
                                                                        print("Assetklasse:", Assetklasse)
                                                                        print("Produktbezeichnung:", Produktbezeichnung        )
                                                                        print("Anteile:", Anteile)
                                                                        print("Kurs:", Kurs)
                                                                        print("ISIN:", ISIN)
                                                                        print("TAN:", TAN)
                                                                end

                                    table.insert(transactions,
                                       {
                                               bookingDate = DateStr2Timestamp( Buchtag         ),
                                               valueDate = DateStr2Timestamp( Valuta ),
                                               purpose = Buchungsinformationen .. "\n" .. Assetklasse .. "\n" .. Produktbezeichnung .. "\nAnteile " .. Anteile .. " Kurs " .. Kurs .. "\nISIN " .. ISIN .. " TAN " .. TAN,
                                               amount = Text2Val ( Betrag ),
                                               currency = Waehrung
                                       }
                               )
                        end
                )
        -- Typ PERFORMANCE liefert JSON, wir werten nur 4 aus, weitere möglich
        elseif ( prefix == "PERFORMANCE" ) then

                -- build url
                url = "https://inside.whitebox.eu/goals/" .. goal .. "/performances?from=&to=&with_whitebox_fees=true&with_taxes=true"

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
                                        url = "https://inside.whitebox.eu/goals/" .. goal .. "/portfolio"

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

                                -- Wie bisher weiter als HTML
                                -- Gleichzeitig Wandlung von UTF-8 in ISO-8859-1
                                local response = HTML(MM.toEncoding('ISO-8859-1', fields.html))

                                local Name
                                local ISIN
                                local Einstand_Wert
                                local Anteile


                        -- Ermittle Transaktionen
                        -- class="table depot-table"
                                response:xpath("//*/table[contains(@class, 'depot-table')]//tbody//tr"):each(
                                function(index, element)


                                        -- nur jedes 2. tr ist ein eigenes security. Es gehören immer 2 tr zusammen
                                        if (index % 2 == 1) then
                                                if debug then
                                                                                print("1. tr:")
                                                end
                                                -- Name
                                                Name = element:xpath(".//ul[@class='dropdown-menu dropdown-menu--dark']//li[1]//p"):text()
                                                -- ISIN
                                                ISIN = element:xpath(".//ul[@class='dropdown-menu dropdown-menu--dark']//li[3]//p"):text()
                                                -- Einstand_Kurs
                                                Einstand_Wert = element:xpath(".//ul[@class='dropdown-menu dropdown-menu--dark']//li[4]//p"):text()
                                                -- Anteile
                                                Anteile = element:xpath(".//ul[@class='dropdown-menu dropdown-menu--dark']//li[5]//p"):text()

                                                if debug then
                                                        print("  Name:", Name)
                                                        print("  ISIN:", ISIN)
                                                        print("  Einstand_Wert:", Einstand_Wert)
                                                        print("  Anteile:", Anteile)
                                                                        end
                                        else
                                                if debug then
                                                                                print("2. tr:")
                                                end
                                                -- Aktueller_Kurs
                                                local Aktueller_Kurs = element:xpath(".//div[@class='table-data']//span[1]"):text()
                                                -- Einstand_Kurs
                                                local Einstand_Kurs = element:xpath(".//div[@class='table-data']//span[3]"):text()

                                                        -- anderer div
                                                -- Aktueller_Kurs
                                                local Akt_Wert = element:xpath(".//div[@class='data text-right m-text-left']//span[1]"):text()
                                                -- Einstand_Kurs
                                                local Anteil_Portfolio = element:xpath(".//div[@class='data text-right m-text-left']//span[3]"):text()
                                                                        if debug then
                                                        print("  Name:", Name)
                                                        print("  ISIN:", ISIN)
                                                        print("  Einstand_Wert:", Einstand_Wert)
                                                        print("  Anteile:", Anteile)
                                                                        end

                                                if debug then
                                                        print("  Aktueller_Kurs:", Aktueller_Kurs)
                                                        print("  Einstand_Kurs:", Einstand_Kurs)
                                                        print("  Akt_Wert:", Akt_Wert)
                                                        print("  Anteil_Portfolio:", Anteil_Portfolio)
                                                                        end



                                                                        table.insert(transactions,
                                                                        {

--                                                                String name: Bezeichnung des Wertpapiers
                                                                                  name = Name,
--                                                                String isin: ISIN
                                                                                  isin = ISIN,
--                                                                String securityNumber: WKN
--                                                                String market: Börse
--                                                                String currency: Währung bei Nominalbetrag oder nil bei Stückzahl
--                                                                Number quantity: Nominalbetrag oder Stückzahl
                                                                                  quantity = tonumber(Text2Val(Anteile)),
--                                                                Number amount: Wert der Depotposition in Kontowährung
                                                                                  amount = tonumber(Text2Val(Akt_Wert)),
--                                                                Number originalCurrencyAmount: Wert der Depotposition in Originalwährung
--                                                                String currencyOfOriginalAmount: Originalwährung
--                                                                Number exchangeRate: Wechselkurs
--                                                                Number tradeTimestamp: Notierungszeitpunkt; Die Angabe erfolgt in Form eines POSIX-Zeitstempels.
                                                                                  tradeTimestamp = os.time(),
--                                                                Number price: Aktueller Preis oder Kurs
                                                                                  price = tonumber(Text2Val(Aktueller_Kurs)),
--                                                                String currencyOfPrice: Von der Kontowährung abweichende Währung des Preises
--                                                                Number purchasePrice: Kaufpreis oder Kaufkurs
                                                                                  purchasePrice = tonumber(Text2Val(Einstand_Kurs))
--                                                                String currencyOfPurchasePrice: Von der Kontowährung abweichende Währung des Kaufpreises

                                                                         })
                                                                end

                                    end
                )

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

-- SIGNATURE: MC0CFQCNAz6UySvxtA81gAUKe/HJx0DAwQIUWFfZlP2Ja2IZiQ3PHmYw8Xufjm4=
