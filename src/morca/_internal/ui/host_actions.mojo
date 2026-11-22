"""A self-hosted host's buttons on Ops > Pools, on its row and its page:
Drain (Undrain while it drains) and Remove, posting to
`/ops/pools/self-hosted/<id>/...` (`morca._internal.api.actions`), as
`morca host drain|undrain|remove` does over the database. Like the UI's
other inline actions (`act_button`), they're hidden, with a "Log in to ..."
link in their place, while login is on and no one is logged in; Remove asks
first where there's a script, and the server refuses it while the host has
runs running until that is confirmed on the page it answers.

And its image beside the server's (`MORCA_WORKER_IMAGE`), when both are
known.
"""

from std.os import getenv

from morca._internal.html import Html
from morca._internal.pool_boot import WORKER_IMAGE
from morca._internal.ui.layout import act_button
from morca._internal.views.pools import SELF_HOSTED, Machine


def has_host_actions(m: Machine) -> Bool:
    """Whether `m` is a self-hosted host whose token is still good: not
    revoked or expired."""
    return (
        m.kind == SELF_HOSTED
        and m.token > 0
        and m.detail != "revoked"
        and m.detail != "expired"
    )


def host_buttons(mut h: Html, m: Machine):
    """Drain (or Undrain) and Remove, for a host that has them."""
    if not has_host_actions(m):
        return
    var base = String("/ops/pools/self-hosted/", m.token)
    var busy = 0
    for r in m.runs:
        if r > 0:
            busy += 1
    if m.state == "draining":
        act_button(
            h,
            String(base, "/undrain"),
            "Undrain",
            "undrain",
            String("morca host undrain ", m.token),
        )
    else:
        act_button(
            h,
            String(base, "/drain"),
            "Drain",
            "drain",
            String("morca host drain ", m.token),
        )
    var tell = String(
        "Its token is revoked, so its worker exits at its next claim and",
        " can't rejoin with it.",
    )
    if busy > 0:
        tell.write(
            " It has ",
            busy,
            " run" if busy == 1 else " runs",
            " running: you'll be asked again, and they are queued again.",
        )
    act_button(
        h,
        String(base, "/remove"),
        "Remove",
        "remove",
        String("morca host remove ", m.token),
        danger=True,
        ask=String("Remove host ", m.name, "?"),
        tell=tell,
        yes="Remove host",
        no="Keep it",
    )


def server_image() -> String:
    """The image the server gives its workers (`MORCA_WORKER_IMAGE`), or
    empty."""
    return getenv(WORKER_IMAGE)


def image_tag(image: String) -> String:
    """`image`'s tag (after the `:` of its last segment), its digest, or
    the whole of it without either."""
    var at = image.find("@").or_else(-1)
    if at >= 0:
        return String(image[byte = at + 1 :])
    var slash = image.rfind("/").or_else(-1)
    var colon = image.rfind(":").or_else(-1)
    if colon > slash:
        return String(image[byte = colon + 1 :])
    return image


def image_cell(mut h: Html, m: Machine, server: String):
    """The Image cell: the machine's image, and for a self-hosted host the
    server's tag beside it when both are known."""
    h.raw('<td class="mono">')
    h.text(m.image if m.image else String("-"))
    if m.kind == SELF_HOSTED and m.image and server:
        h.raw(' <span class="muted" title="the server\'s image: ')
        h.text(server)
        h.raw('">')
        if server == m.image:
            h.raw("· the server's")
        else:
            h.text("· server ", image_tag(server))
        h.raw("</span>")
    h.raw("</td>")
