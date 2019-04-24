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

WebBanking{version     = 1.05,
           url         = "https://www.whitebox.eu/login",
           services    = {"Whitebox"},
           description = "Whitebox"}

function SupportsBank (protocol, bankCode)
  return protocol == ProtocolWebBanking and bankCode == "Whitebox"
end

local connection = nil
local loginresponse = nil
local connection = Connection()


--------------------------------------------------------------------------------------------------------------------------
-- Session

function InitializeSession (protocol, bankCode, username, username2, password, username3)
    connection.language = "de-de"

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
        local timeStr = os.date('%d.%m.%Y', since)

        -- Typ KONTO liefert Tabelle mit 3 Spalten
        if ( prefix == "KONTO" ) then
                type_text = 'Kontostand:'

                -- build url
                        url = "https://www.whitebox.eu/goals/" .. goal .. "/statements?statements_query[start_date]=" .. timeStr
                        local response = HTML(connection:get(url))

                -- Ermittle Kontostand vom KONTO
                local balance_text = response:xpath("//*/td[@class='gray' and text()='" .. type_text .."']/following-sibling::td"):text()
                balance = Text2Val ( balance_text)

                -- Ermittle Transaktionen
                response:xpath("//*/div[@id='account-statements']/div/table/tbody/tr"):each(
                        function(index, element)
                                local Buchtag = element:children():get(1)
                                local Buchungsinformationen = element:children():get(2)
                                local Betrag = element:children():get(3)

                                -- Trennen DD.MM.YYYY DD.MM.YYYY
                                -- Buchungstag Valuta

                                local buch1, buch2 = string.match(Buchtag:text() ,'(.+)%s+(.+)')

                                table.insert(transactions,
                                        {
                                                bookingDate = DateStr2Timestamp( buch1 ),
                                                valueDate = DateStr2Timestamp( buch2 ),
                                                purpose = Buchungsinformationen:text(),
                                                amount = Text2Val ( Betrag:text() )
                                        }
                                )
                        end
                )

        -- Typ DEPOT liefert Tabelle mit 6 Spalten
        elseif ( prefix == "DEPOT" ) then
                type_text = 'Depotbestand:'

                -- build url
                        url = "https://www.whitebox.eu/goals/" .. goal .. "/statements?statements_query[start_date]=" .. timeStr
                        local response = HTML(connection:get(url))

                -- Ermittle Kontostand vom DEPOT
                local balance_text = response:xpath("//*/td[@class='gray' and text()='" .. type_text .."']/following-sibling::td"):text()
                balance = Text2Val ( balance_text)

                response:xpath("//*/div[@id='depot-statements']/div/table/tbody/tr"):each(
                        function(index, element)
                                local Buchtag = element:children():get(1)
                                local Buchungsinformationen = element:children():get(2)
                                local Assetklasse = element:children():get(3)
                                local Produktbezeichnung = element:children():get(4)
                                local Anteile = element:children():get(5)
                                local Wert = element:children():get(6)

                                -- Beträge aufbereiten
                                -- . löschen
                                Wert = string.gsub(Wert:text(), "%.", "")

                                -- Trennen von Betrag und Währung
                                local Betrag, Waehrung = string.match(Wert, '(-?%d+,?%d+)%s*(%w+)' )

                                -- Trennen DD.MM.YYYY DD.MM.YYYY
                                -- Buchungstag Valuta

                                local buch1, buch2 = string.match(Buchtag:text() ,'(.+)%s+(.+)')

                                table.insert(transactions,
                                        {
                                                bookingDate = DateStr2Timestamp( buch1 ),
                                                valueDate = DateStr2Timestamp( buch2 ),
                                                purpose = Buchungsinformationen:text() .. "\n" .. Assetklasse:text() .. "\n" .. Produktbezeichnung:text() .. "\n" .. Anteile:text() ,
                                                amount = Text2Val ( Betrag ),
                                                currency = Waehrung
                                        }
                                )
                        end
                )
        -- Typ PERFORMANCE liefert JSON, wir werten nur 4 aus, weitere möglich
        elseif ( prefix == "PERFORMANCE" ) then

                -- build url
                        url = "https://www.whitebox.eu/goals/" .. goal .. "/performances"
                        local response = HTML(connection:get(url))

                        local sniplet = string.match(response:html(),'report":(.+})}')
                        --print (sniplet)
                        local json = JSON(sniplet):dictionary()
                        --print (dump (json))

                                table.insert(transactions,
                                                {
                                                                name = "Vermögensstand: " .. string.format("%.2f", json["end_assets"]) .. " €",
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
                                                                name = "Geldgewichtete Rendite: " .. round2(json["mwr"]*100,2) .. " %",
                                                                market = "Whitebox",
                                                                isin = "Performance mwr",
                                                                tradeTimestamp = os.time(),
                                                                currencyOfPurchasePrice = "EUR"
                                                }
                                )
                                table.insert(transactions,
                                                {
                                                                name = "Geldgewichtete Rendite annualisiert: " .. round2(json["yearly_mwr"]*100,2) .. " %",
                                                                market = "Whitebox",
                                                                isin = "Performance yearly_mwr",
                                                                tradeTimestamp = os.time(),
                                                                currencyOfPurchasePrice = "EUR"
                                                }
                                )
                                table.insert(transactions,
                                                {
                                                                name = "Erfolgsrelevante Kapitalveränderungen: " ..  string.format("%.2f", json["sum_of_erfolgsrelevante_kapitalveraenderungen"]) .. " €",
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
                        url = "https://www.whitebox.eu/goals/" .. goal .. "/portfolio"
                        local response = HTML(connection:get(url))
                        --print (response:html())

                                 response:xpath("//*/tr[contains(@id, 'portfolio_row_')]"):each(
                        function(index, element)
--                                print("------------------")
--                                print(index)

--                                print( "1=" .. element:children():get(1):text() )
--                                print( "1 1=" .. element:children():get(1):children():get(1):text() )
--                                print( "2=" .. element:children():get(2):text())
--                                print( "2 1=" .. element:children():get(2):children():get(1):text() )
--                                print( "3=" .. element:children():get(3):text())
--                                print( "3 1=" .. element:children():get(3):children():get(1):text() )
--                                print( "4=" .. element:children():get(4):text())
--                                print( "4 1=" .. element:children():get(4):children():get(1):text() )
--                                print( "5=" .. element:children():get(5):text())
--                                print( "5 1=" .. element:children():get(5):children():get(1):text() )
--                                print( "6=" .. element:children():get(6):text())
--                                print( "6 1=" .. element:children():get(6):children():get(1):text() )

                                                        local Name                                         = element:children():get(1):children():get(1):text()
                                                        local Anteile                                 = first_split_string( element:children():get(2):text() )
                                                        local ISIN                                         = element:children():get(2):children():get(1):text()
                                                        local Aktueller_Kurs                 = first_split_string( element:children():get(3):text() )
                                                        local Einstand_Kurs                        = element:children():get(3):children():get(1):text()
                                                        local Einstand_Wert                        = element:children():get(4):text()
                                                        local Akt_Wert                                 = first_split_string( element:children():get(5):text() )

--                                                        print ("Name=" .. Name)
--                                                        print ("Anteile=" .. Anteile )
--                                                        print ("ISIN=" .. ISIN )
--                                                        print ("Aktueller_Kurs=" .. Aktueller_Kurs)
--                                                        print ("Einstand_Kurs=" .. Einstand_Kurs)
--                                                        print ("Einstand_Wert=" .. Einstand_Wert)
--                                                        print ("Akt_Wert=" .. Akt_Wert)

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
                )

                        return {securities = transactions}
        end
        return {balance = balance, transactions = transactions}
end

--------------------------------------------------------------------------------------------------------------------------
-- Helper: Text in Betrag wandeln
-- 2 Fälle: € 3.126,18  und  2.12,12 EUR

function Text2Val ( text )
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
        url = "https://www.whitebox.eu/logout"
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

-- SIGNATURE: MCwCFGpu9yD6uAMjV2xOaEraY19VXy1AAhQqaRK8qMOIWChlsW6BKIeVXci3QQ==
