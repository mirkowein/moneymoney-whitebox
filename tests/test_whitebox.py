"""Offline behavioral tests. All credentials, identifiers and balances are synthetic."""
import copy
import json
import re
from pathlib import Path
from urllib.parse import parse_qs, urlencode, urljoin

import pytest
from lxml import html
from lupa.lua54 import LuaRuntime, LuaError, lua_type
from graphql import parse, print_ast


ROOT = Path(__file__).resolve().parents[1]
BASE = "https://inside.whitebox.eu"
WALLET = "V2FsbGV0LTEyMw"
LOGIN = """<html><form action='/' method='post'>
<input name='authenticity_token' value='test-csrf-form'>
<input name='session[email]' type='email'>
<input name='session[password]' type='password'>
<button id='login-btn' type='submit'>Anmelden</button></form></html>"""


def money(amount, currency="EUR"):
    return {"amount": amount, "currency": {"isoCode": currency}}


def goal(slug="anlage-mit_suffix-42", **overrides):
    return dict(id="goal-123", slug=slug, name="Meine Anlage", status="ACTIVE",
                portfolioId="portfolio-456", **overrides)


def asset_class_page(rows, slug="anlage-mit_suffix-42", more=False, cursor=None):
    return {"wallet": {"goals": {"nodes": [{"slug": slug, "portfolio": {"depotAssets": rows}}],
                               "pageInfo": {"hasNextPage": more, "endCursor": cursor}}}}


def to_python(value):
    if lua_type(value) != "table":
        return value
    keys = list(value.keys())
    if keys and set(keys) == set(range(1, len(keys) + 1)):
        return [to_python(value[i]) for i in range(1, len(keys) + 1)]
    return {k: to_python(value[k]) for k in keys}


class Elements:
    def __init__(self, nodes):
        self.nodes = nodes

    def length(self):
        return len(self.nodes)

    def attr(self, name, *value):
        if value:
            for node in self.nodes:
                node.set(name, value[0])
        else:
            return self.nodes[0].get(name) if self.nodes else None

    def click(self):
        node = self.nodes[0]
        form = node.getparent()
        while form.tag != "form":
            form = form.getparent()
        fields = [(n.get("name"), n.get("value", "")) for n in form.xpath(".//input[@name]")]
        return (form.get("method").upper(), urljoin(BASE, form.get("action")),
                urlencode(fields), "application/x-www-form-urlencoded")


class Document:
    def __init__(self, content, *_):
        self.root = html.fromstring(content)

    def xpath(self, query):
        return Elements(self.root.xpath(query))


class Harness:
    def __init__(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.requests = []
        self.responses = {"MoneyMoneyGoals": {"wealthGoals": [goal()]},
                          "MoneyMoneyAssetClasses": asset_class_page([])}
        self.login_result = "<html><div>Ladegerüst ohne Konten</div></html>"
        self.login_url = f"{BASE}/w/{WALLET}/wealth"
        self.session = {"authToken": "synthetic-access-token", "csrfToken": "synthetic-csrf"}
        self.raw_response = None
        self.graphql_errors = None
        self.asset_class_pages = {}
        self.metadata_content = None
        self.metadata_error = False
        self.base_url = BASE
        runtime = self.lua

        class JSONDocument:
            def __init__(self, content=None):
                self.content = content

            def dictionary(self):
                return runtime.table_from(json.loads(self.content), recursive=True)

            def set(self, data):
                self.content = json.dumps(to_python(data))
                return self

            def json(self):
                return self.content

        runtime.globals().JSON = JSONDocument
        runtime.globals().HTML = Document
        runtime.globals().py_request = self.request
        runtime.globals().py_base_url = lambda: self.base_url
        runtime.execute("""
            ProtocolWebBanking = 'web'
            AccountTypeSavings = 'savings'
            AccountTypePortfolio = 'portfolio'
            LoginFailed = 'LOGIN_FAILED'
            MM = {time = function() return 1792584000.25 end}
            function WebBanking(config) registered = config end
            function Connection()
                return {
                    request = function(self, ...) return py_request(...) end,
                    get = function(self, url) return py_request('GET', url) end,
                    getBaseURL = function(self) return py_base_url() end
                }
            end
        """)
        runtime.execute((ROOT / "Whitebox.lua").read_text())

    def request(self, method, url, body=None, content_type=None, headers=None):
        self.base_url = url
        headers = to_python(headers) if headers else {}
        request = dict(method=method, url=url, body=body, content_type=content_type, headers=headers)
        self.requests.append(request)
        if url.endswith("/login"):
            return LOGIN
        if method == "POST" and url == BASE + "/":
            self.base_url = self.login_url
            return self.login_result
        if url.endswith("/api/onboarding/session"):
            return json.dumps(self.session)
        if url.endswith("/logout"):
            return "{}"
        assert url == BASE + "/graphql"
        assert method == "POST"
        assert content_type == "application/json"
        assert headers["Authorization"] == "Bearer synthetic-access-token"
        query = json.loads(body)
        request["query"] = query
        assert re.search(r"\bquery\s+" + query["operationName"] + r"\b", query["query"])
        assert not re.search(r"\bmutation\b", query["query"])
        assert query["variables"]["walletId"] == WALLET
        if "productType:" in query["query"]:
            assert "productType: WEALTH" in query["query"]
        if query["operationName"] == "MoneyMoneyAssetClasses":
            if self.metadata_error:
                raise RuntimeError("Synthetic unavailable metadata query")
            if self.metadata_content is not None:
                return self.metadata_content
            if self.asset_class_pages:
                return json.dumps({"data": self.asset_class_pages[query["variables"].get("after")]})
        if self.raw_response is not None:
            return self.raw_response
        response = {"data": copy.deepcopy(self.responses[query["operationName"]])}
        if self.graphql_errors is not None:
            response["errors"] = self.graphql_errors
        return json.dumps(response)

    def login(self):
        return self.lua.globals().InitializeSession("web", "Whitebox", "test@example.invalid", "", "a&b +?", "")

    def refresh(self, prefix, since=1767225600, key="anlage-mit_suffix-42"):
        account = self.lua.table_from({"accountNumber": prefix + "_" + key, "currency": "EUR"})
        return to_python(self.lua.globals().RefreshAccount(account, since))

    def portfolio_response(self, operation, **fields):
        self.responses[operation] = {"portfolios": [{"id": "portfolio-456", **fields}]}


@pytest.fixture
def h():
    harness = Harness()
    assert harness.login() is None
    return harness


def test_login_preserves_csrf_cookies_flow_and_encodes_password(h):
    post = h.requests[1]
    assert parse_qs(post["body"]) == {
        "authenticity_token": ["test-csrf-form"],
        "session[email]": ["test@example.invalid"], "session[password]": ["a&b +?"]}
    assert h.requests[2]["url"] == BASE + "/api/onboarding/session"


def test_new_setup_finds_four_accounts_without_html_deposit_buttons(h):
    accounts = to_python(h.lua.globals().ListAccounts(h.lua.table()))
    assert [a["accountNumber"] for a in accounts] == [
        p + "_anlage-mit_suffix-42" for p in ("KONTO", "DEPOT", "PERFORMANCE", "PORTFOLIO")]
    assert accounts[0]["name"] == "Konto Meine Anlage"
    assert [a["portfolio"] for a in accounts] == [False, False, True, True]


def test_only_active_goals_with_a_portfolio_are_offered(h):
    h.responses["MoneyMoneyGoals"]["wealthGoals"] += [
        dict(goal("inactive"), status="INACTIVE"), dict(goal("uninvested"), portfolioId=None),
        dict(goal("draft"), status="CREATED")]
    assert len(h.lua.globals().ListAccounts(h.lua.table())) == 4


def test_refresh_without_listaccounts_uses_full_slug_and_correct_portfolio(h):
    h.portfolio_response("MoneyMoneyCash", cashAccount={"balance": money("12.34")}, cashTransactions=[])
    assert h.refresh("KONTO")["balance"] == 12.34
    request = h.requests[-1]["query"]
    assert request["variables"]["portfolioIds"] == ["portfolio-456"]
    assert request["variables"]["from"] == "2026-01-01"
    assert re.fullmatch(r"\d{4}-\d{2}-\d{2}", request["variables"]["to"])


def test_missing_since_requests_entire_history(h):
    h.portfolio_response("MoneyMoneyCash", cashAccount={"balance": money(0)}, cashTransactions=[])
    h.refresh("KONTO", since=None)
    assert "from" not in h.requests[-1]["query"]["variables"]


def test_cash_transactions_keep_sign_currency_reference_and_newest_first(h):
    rows = [dict(date="2026-01-02", description="Einzahlung", number="T1", value=money(1000)),
            dict(date="2026-01-03", description="Gebühr", number="T2", value=money(-1.25))]
    h.portfolio_response("MoneyMoneyCash", cashAccount={"balance": money(998.75)}, cashTransactions=rows)
    result = h.refresh("KONTO")
    assert result["balance"] == 998.75
    assert [t["amount"] for t in result["transactions"]] == [-1.25, 1000]
    assert result["transactions"][0]["currency"] == "EUR"
    assert "T2" in result["transactions"][0]["purpose"]
    assert "valueDate" not in result["transactions"][0]  # Not supplied by this API.


def test_depot_uses_signed_booked_value_instead_of_quantity_times_price(h):
    rows = [dict(date="2026-09-20", description="Kauf", number="D1", isin="IE00TEST00001",
                 productName="Test ETF", quantity="5.5", value=money(-555.75))]
    h.portfolio_response("MoneyMoneyDepot", depotAccount={"currentValue": money(601.23)}, depotTransactions=rows)
    result = h.refresh("DEPOT")
    assert result["balance"] == 601.23
    assert result["transactions"][0]["amount"] == -555.75
    assert "IE00TEST00001" in result["transactions"][0]["purpose"]


def test_assets_preserve_fractional_quantity_valuation_and_purchase_price(h):
    h.responses["MoneyMoneyAssets"] = {"assets": {"securityData": [dict(
        isin="IE00TEST00001", name="Test ETF", shares="1.2345", marketPrice=100,
        averagePurchasePrice=90, totalValue=money(123.45))]}}
    security = h.refresh("PORTFOLIO")["securities"][0]
    assert (security["quantity"], security["amount"], security["price"], security["purchasePrice"]) == (1.2345, 123.45, 100, 90)
    assert "balance" not in h.refresh("PORTFOLIO")


def test_missing_optional_prices_are_omitted(h):
    h.responses["MoneyMoneyAssets"] = {"assets": {"securityData": [dict(
        isin="IE00TEST00001", name="Test ETF", shares=1, marketPrice=None,
        averagePurchasePrice=None, totalValue=money(100))]}}
    security = h.refresh("PORTFOLIO")["securities"][0]
    assert "purchasePrice" not in security and "price" not in security


def asset_response(h, name="AMUNDI IS MSCI EMERGING M"):
    h.responses["MoneyMoneyAssets"] = {"assets": {"securityData": [dict(
        isin="IE00TEST00001", name=name, shares="1.2345", marketPrice=100,
        averagePurchasePrice=90, totalValue=money(123.45))]}}


def test_security_name_restores_whitebox_asset_class_by_isin(h):
    asset_response(h)
    h.responses["MoneyMoneyAssetClasses"] = asset_class_page([
        {"isin": "IE00OTHER0001", "className": "Andere Anlageklasse"},
        {"className": "Cash"},
        {"isin": "IE00TEST00001", "className": "Aktien Schwellenländer"},
    ])
    security = h.refresh("PORTFOLIO")["securities"][0]
    assert security["name"] == "AMUNDI IS MSCI EMERGING M (Aktien Schwellenländer)"
    assert (security["quantity"], security["amount"], security["isin"]) == (1.2345, 123.45, "IE00TEST00001")
    assert h.requests[-1]["query"]["operationName"] == "MoneyMoneyAssetClasses"


@pytest.mark.parametrize("class_name", [None, "", "  "])
def test_missing_asset_class_keeps_name_without_empty_parentheses(h, class_name):
    asset_response(h)
    h.responses["MoneyMoneyAssetClasses"] = asset_class_page([
        {"isin": "IE00TEST00001", "className": class_name}])
    assert h.refresh("PORTFOLIO")["securities"][0]["name"] == "AMUNDI IS MSCI EMERGING M"


def test_asset_class_suffix_is_not_duplicated(h):
    asset_response(h, "AMUNDI IS MSCI EMERGING M (Aktien Schwellenländer)")
    h.responses["MoneyMoneyAssetClasses"] = asset_class_page([
        {"isin": "IE00TEST00001", "className": "  Aktien Schwellenländer  "}])
    assert h.refresh("PORTFOLIO")["securities"][0]["name"] == "AMUNDI IS MSCI EMERGING M (Aktien Schwellenländer)"


@pytest.mark.parametrize("metadata", ["<html>Login</html>", '{"data":{}}', '{"errors":[{"message":"Unavailable"}]}'])
def test_unavailable_metadata_does_not_block_graphql_holdings(h, metadata):
    asset_response(h)
    h.metadata_content = metadata
    security = h.refresh("PORTFOLIO")["securities"][0]
    assert security["name"] == "AMUNDI IS MSCI EMERGING M"
    assert security["amount"] == 123.45


def test_failed_metadata_request_does_not_block_graphql_holdings(h):
    asset_response(h)
    h.metadata_error = True
    assert h.refresh("PORTFOLIO")["securities"][0]["amount"] == 123.45


def test_ambiguous_asset_class_is_not_guessed(h):
    asset_response(h)
    h.responses["MoneyMoneyAssetClasses"] = asset_class_page([
        {"isin": "IE00TEST00001", "className": "Aktien Schwellenländer"},
        {"isin": "IE00TEST00001", "className": "Andere Anlageklasse"},
        {"isin": "IE00TEST00001", "className": "Aktien Schwellenländer"}])
    assert h.refresh("PORTFOLIO")["securities"][0]["name"] == "AMUNDI IS MSCI EMERGING M"


def test_asset_classes_are_scoped_by_goal_and_isin(h):
    asset_response(h)
    h.responses["MoneyMoneyAssetClasses"] = asset_class_page([
        {"isin": "IE00TEST00001", "className": "Falsche Anlage"}], slug="anderes-ziel")
    assert h.refresh("PORTFOLIO")["securities"][0]["name"] == "AMUNDI IS MSCI EMERGING M"


def test_empty_holdings_do_not_fetch_asset_class_metadata(h):
    h.responses["MoneyMoneyAssets"] = {"assets": {"securityData": []}}
    h.refresh("PORTFOLIO")
    assert not any(request.get("query", {}).get("operationName") == "MoneyMoneyAssetClasses" for request in h.requests)


def test_asset_class_metadata_follows_all_pages_and_is_cached(h):
    asset_response(h)
    h.asset_class_pages = {
        None: asset_class_page([], slug="erstes-ziel", more=True, cursor="page-two"),
        "page-two": asset_class_page([{"isin": "IE00TEST00001", "className": "Aktien Schwellenländer"}]),
    }
    for _ in range(2):
        assert h.refresh("PORTFOLIO")["securities"][0]["name"].endswith(" (Aktien Schwellenländer)")
    requests = [r["query"] for r in h.requests if r.get("query", {}).get("operationName") == "MoneyMoneyAssetClasses"]
    assert len(requests) == 2
    assert requests[1]["variables"]["after"] == "page-two"


def test_repeated_metadata_cursor_does_not_loop_or_import_partial_classes(h):
    asset_response(h)
    page = asset_class_page([{"isin": "IE00TEST00001", "className": "Unvollständig"}], more=True, cursor="same")
    h.asset_class_pages = {None: page, "same": page}
    assert h.refresh("PORTFOLIO")["securities"][0]["name"] == "AMUNDI IS MSCI EMERGING M"


def test_metadata_cache_is_reset_on_new_session(h):
    asset_response(h)
    h.responses["MoneyMoneyAssetClasses"] = asset_class_page([{"isin": "IE00TEST00001", "className": "Erste Klasse"}])
    assert h.refresh("PORTFOLIO")["securities"][0]["name"].endswith(" (Erste Klasse)")
    h.lua.globals().EndSession()
    assert h.login() is None
    h.responses["MoneyMoneyAssetClasses"] = asset_class_page([{"isin": "IE00TEST00001", "className": "Neue Klasse"}])
    assert h.refresh("PORTFOLIO")["securities"][0]["name"].endswith(" (Neue Klasse)")


def test_performance_percentage_is_not_multiplied_and_information_has_zero_value(h):
    h.portfolio_response("MoneyMoneyPerformance", performanceReport=dict(
        endAssets=money(1100), returnInEuro=money(100), moneyWeightedReturnInPercentage=10.25,
        moneyWeightedReturnAnnualizedInPercentage=None))
    securities = h.refresh("PERFORMANCE")["securities"]
    assert securities[1]["name"].endswith("10.25 %")
    assert securities[2]["name"].endswith("nicht verfügbar")
    assert sum(s["amount"] for s in securities) == 0


@pytest.mark.parametrize("prefix,operation,fields", [
    ("KONTO", "MoneyMoneyCash", {"cashAccount": {"balance": money(10)}}),
    ("DEPOT", "MoneyMoneyDepot", {"depotAccount": {"currentValue": money(10)}}),
    ("PERFORMANCE", "MoneyMoneyPerformance", {}),
])
def test_missing_response_fields_abort_instead_of_clearing_accounts(h, prefix, operation, fields):
    h.portfolio_response(operation, **fields)
    with pytest.raises(LuaError, match="unvollständig"):
        h.refresh(prefix)


def test_missing_asset_list_does_not_clear_holdings(h):
    h.responses["MoneyMoneyAssets"] = {"assets": {}}
    with pytest.raises(LuaError, match="unvollständig"):
        h.refresh("PORTFOLIO")


def test_explicit_empty_holdings_are_accepted(h):
    h.responses["MoneyMoneyAssets"] = {"assets": {"securityData": []}}
    assert len(h.refresh("PORTFOLIO")["securities"]) == 0


def test_partial_graphql_error_never_becomes_empty_success(h):
    h.graphql_errors = [{"message": "Test validation failure"}]
    with pytest.raises(LuaError, match="abgewiesen"):
        h.lua.globals().ListAccounts(h.lua.table())


def test_expired_graphql_session_is_explicit(h):
    h.graphql_errors = [{"message": "Unauthorized", "extensions": {"code": "UNAUTHENTICATED"}}]
    with pytest.raises(LuaError, match="Sitzung abgelaufen"):
        h.lua.globals().ListAccounts(h.lua.table())


def test_html_instead_of_json_is_reported_without_leaking_body(h):
    h.raw_response = "<html>synthetic-private-content</html>"
    with pytest.raises(LuaError, match="keine gültige JSON") as error:
        h.lua.globals().ListAccounts(h.lua.table())
    assert "synthetic-private-content" not in str(error.value)


def test_wrong_portfolio_cannot_be_imported(h):
    h.responses["MoneyMoneyCash"] = {"portfolios": [dict(id="wrong", cashAccount={"balance": money(9999)}, cashTransactions=[])]}
    with pytest.raises(LuaError, match="nicht eindeutig"):
        h.refresh("KONTO")


@pytest.mark.parametrize("date", ["2026-02-30", "2026-13-01", "broken"])
def test_invalid_dates_are_rejected(h, date):
    with pytest.raises(LuaError, match="Ungültiges Buchungsdatum"):
        h.lua.globals().IsoDateStr2Timestamp(date)


@pytest.mark.parametrize("amount", [None, "NaN", "unknown"])
def test_invalid_amounts_do_not_become_zero(h, amount):
    h.portfolio_response("MoneyMoneyCash", cashAccount={"balance": money(amount)}, cashTransactions=[])
    with pytest.raises(LuaError, match="Zahlenwert"):
        h.refresh("KONTO")


def test_wrong_account_currency_is_rejected(h):
    h.portfolio_response("MoneyMoneyCash", cashAccount={"balance": money(100, "USD")}, cashTransactions=[])
    with pytest.raises(LuaError, match="Unerwartete Währung"):
        h.refresh("KONTO")


def test_rejected_credentials_stop_before_token_request():
    h = Harness()
    h.login_url = BASE + "/login"
    h.login_result = LOGIN
    assert h.login() == "LOGIN_FAILED"
    assert len(h.requests) == 2


def test_missing_session_token_is_actionable_and_not_logged():
    h = Harness()
    h.session = {}
    assert "kein Zugriffstoken" in h.login()


def test_unknown_old_account_is_not_assigned_to_another_goal(h):
    with pytest.raises(LuaError, match="gespeicherte Anlage wurde nicht gefunden"):
        h.refresh("KONTO", key="unrelated-old-slug")


def test_logout_uses_csrf_and_clears_token(h):
    h.lua.globals().EndSession()
    assert h.requests[-1]["body"] == "_method=delete"
    assert h.requests[-1]["headers"]["X-CSRF-Token"] == "synthetic-csrf"
    with pytest.raises(LuaError, match="Keine aktive Sitzung"):
        h.lua.globals().ListAccounts(h.lua.table())


def test_all_query_fields_arguments_and_variable_types_exist_in_public_frontend():
    """Compatibility check against actual published queries, not a guessed schema.

    This deliberately cannot establish server authorization or response values.
    """
    reference = parse((ROOT / "tests/fixtures/frontend_queries.graphql").read_text() + "\n" +
                      (ROOT / "tests/fixtures/api_asset_classes.graphql").read_text())
    paths, types = {}, {}

    def fields(selection, prefix=()):
        for field in selection.selections:
            path = (*prefix, field.name.value)
            yield path, field
            if field.selection_set:
                yield from fields(field.selection_set, path)

    for operation in reference.definitions:
        for variable in operation.variable_definitions:
            name = variable.variable.name.value
            types.setdefault(name, set()).add(print_ast(variable.type))
        for path, field in fields(operation.selection_set):
            paths.setdefault(path, set()).update(a.name.value for a in (field.arguments or ()))

    source = (ROOT / "Whitebox.lua").read_text()
    queries = re.findall(r"local (\w+_QUERY) = \[\[(.*?)\]\]", source, re.S)
    assert len(queries) == 6
    for name, query in queries:
        operation, = parse(query).definitions
        for variable in operation.variable_definitions:
            assert print_ast(variable.type) in types[variable.variable.name.value], name
        for path, field in fields(operation.selection_set):
            assert path in paths, (name, path)
            assert {a.name.value for a in (field.arguments or ())} <= paths[path], (name, path)
            for argument in (field.arguments or ()):
                if argument.name.value == "productType":
                    # ProductTypeEnum from the same generated frontend module.
                    assert argument.value.value == "WEALTH"
                if argument.name.value == "input":
                    assert {f.name.value for f in argument.value.fields} == {"withWhiteboxFees", "withTaxes"}
