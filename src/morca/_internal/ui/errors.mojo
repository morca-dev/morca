"""The pages a handler answers when it can't do what was asked: 404 and
400, as HTML or JSON (`Page`)."""

from morca._internal.html import Html
from morca._internal.json import quote
from morca._internal.ui.layout import page_html
from morca._internal.web.page import Page


def not_found(what: String) -> Page:
    var h = Html()
    h.raw("<h1>Not found</h1><p>")
    h.text(what)
    h.raw("</p>")
    return Page(
        404,
        String('{"error": ', quote(what), "}"),
        page_html("Not found", "", h),
    )


def bad_request(why: String) -> Page:
    """A 400: the form asked for something the UI never does."""
    var h = Html()
    h.raw("<h1>Refused</h1><p>")
    h.text(why)
    h.raw("</p>")
    return Page(
        400, String('{"error": ', quote(why), "}"), page_html("Refused", "", h)
    )
