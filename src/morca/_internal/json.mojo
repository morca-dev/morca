"""The little JSON morca writes: quoted strings."""


def quote(s: StringSpan) -> String:
    """`s` as a JSON string literal, quotes included."""
    comptime digits = "0123456789abcdef"
    var out = String('"')
    for cp in s.codepoint_slices():
        if cp == '"':
            out.write('\\"')
        elif cp == "\\":
            out.write("\\\\")
        elif cp == "\n":
            out.write("\\n")
        elif cp == "\t":
            out.write("\\t")
        elif cp.byte_length() == 1 and Int(cp.as_bytes()[0]) < 0x20:
            var b = Int(cp.as_bytes()[0])
            out.write("\\u00", digits[byte=b >> 4], digits[byte=b & 15])
        else:
            out.write(cp)
    out.write('"')
    return out^
