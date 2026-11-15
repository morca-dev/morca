"""`morca_maintain`, as the morca-mojo package builds it into its bin/
(#455): bin/morca_maintain.mojo's two lines, here for the reason
src/morca_bin.mojo gives."""

from morca.maintain import maintain_main


def main() raises:
    maintain_main()
