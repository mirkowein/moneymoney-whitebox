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
-- 1.00			Initial
-- 1.01			Fix for Currencies in Depot
-- 1.02			Fix for ListAccounts 

WebBanking{version     = 1.02,
           url         = "https://www.whitebox.eu/sessions/new",
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

        -- build url
        url = "https://www.whitebox.eu/goals/" .. goal .. "/statements?statements_query[start_date]=" .. timeStr

        local response = HTML(connection:get(url))

        -- Typ KONTO liefert Tabelle mit 3 Spalten
        if ( prefix == "KONTO" ) then
                type_text = 'Kontostand:'

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
        else
                type_text = 'Depotbestand:'

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

-- SIGNATURE: MC4CFQCPX512JvAf0d/8pa6y1uuH+wTEOQIVAIw7cnRNzdj0yaYlGQsLWpgMherg
