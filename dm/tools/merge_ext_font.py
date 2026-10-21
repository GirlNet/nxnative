#!/usr/bin/env python3
# Merge the generated Nintendo button-icon font into the standard shared-font
# stand-in. Some game strings request private-use button glyphs through a
# standard font slot, where an icon-only extension font is not consulted.
# Usage: merge_ext_font.py standard.ttf nintendo_ext.ttf out.ttf
import sys

from fontTools.merge import Merger
from fontTools.ttLib import TTFont
from fontTools.ttLib.scaleUpem import scale_upem


def main() -> None:
    if len(sys.argv) != 4:
        raise SystemExit(__doc__)
    standard_path, extension_path, output_path = sys.argv[1:]
    standard = TTFont(standard_path)
    extension = TTFont(extension_path)
    target_upem = standard["head"].unitsPerEm
    if extension["head"].unitsPerEm != target_upem:
        scale_upem(extension, target_upem)
    temporary = extension_path + ".scaled.ttf"
    extension.save(temporary)
    merged = Merger().merge([standard_path, temporary])
    merged.save(output_path)


if __name__ == "__main__":
    main()
