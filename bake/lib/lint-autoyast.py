"""Catch the AutoYaST profile mistakes that XML well-formedness cannot.

YaST validates the profile against an RNG schema before using it, and a profile
that is perfectly well-formed XML can still fail:

  ERROR: Extra element bootloader in interleave
  ERROR: Element profile failed to validate content
  WARNING: The AutoYaST profile is not a valid XML document.

That is what `<serial>` and `<terminal>` inside `<bootloader><global>` did - they
are not members of that element's content model. The run then fell through to
'A profile for this machine could not be found or retrieved' and sat on a
[Retry][Abort] dialog, which reads like a network problem and was not one.

This checks the parts that are checkable without the schema: no duplicated keys
where the schema allows one, and only known children in the few elements the
bakes actually set.

Usage: lint-autoyast.py <profile.xml>
"""

import sys
import xml.etree.ElementTree as ET

# Children each element may have more than one of. Everything else here appears
# at most once, and a repeat is "Extra element ... in interleave".
MULTI = {
    "profile": set(),                 # every top-level section appears once
    "interfaces": {"interface"},
    "partitioning": {"drive"},
    "users": {"user"},
    "patterns": {"pattern"},
    "packages": {"package"},
    "chroot-scripts": {"script"},
    "post-scripts": {"script"},
    "pre-scripts": {"script"},
    "init-scripts": {"script"},
}

# The content model of <bootloader><global>, as far as the bakes touch it. This is
# the list that `<serial>` and `<terminal>` were not on.
GLOBAL_ALLOWED = {
    "append", "timeout", "activate", "generic_mbr", "boot_boot", "boot_custom",
    "boot_extended", "boot_mbr", "boot_root", "cpu_mitigations", "hidpi",
    "os_prober", "trusted_grub", "vgamode", "terminal", "secure_boot",
}


def tag(e):
    return e.tag.split("}")[-1]


def second_stage_disabled(root) -> bool:
    """Is <general><mode><second_stage> explicitly false?"""
    for general in root:
        if tag(general) != "general":
            continue
        for mode in general:
            if tag(mode) != "mode":
                continue
            for child in mode:
                if tag(child) == "second_stage":
                    return (child.text or "").strip().lower() == "false"
    return False


def main(path):
    problems = []
    try:
        root = ET.parse(path).getroot()
    except ET.ParseError as e:
        print(f"{path}: not well-formed XML: {e}", file=sys.stderr)
        return 1

    for parent in root.iter():
        pname = tag(parent)
        seen = {}
        for child in parent:
            cname = tag(child)
            seen[cname] = seen.get(cname, 0) + 1
        allowed_multi = MULTI.get(pname, set())
        for cname, count in seen.items():
            if count > 1 and cname not in allowed_multi:
                problems.append(f"<{pname}> has {count} <{cname}> elements; the schema allows one")

    # <bootloader><global> is where the wrong-element mistake happened.
    for bl in root.iter():
        if tag(bl) != "bootloader":
            continue
        for g in bl:
            if tag(g) != "global":
                continue
            for child in g:
                if tag(child) not in GLOBAL_ALLOWED and not tag(child).startswith("boot_"):
                    problems.append(
                        f"<bootloader><global> contains <{tag(child)}>, which is not in that "
                        f"element's content model - YaST will reject the whole profile"
                    )

    # AutoYaST is a two-stage installer. Stage two boots the installed system and
    # runs YaST again to finish configuration, and a profile with scripts or a
    # services-manager section makes it 'strictly necessary'. The machine then
    # reboots into YaST and waits on a [Next] button, which in a screenshot looks
    # exactly like an installed system that booted to a login screen.
    if not second_stage_disabled(root):
        problems.append(
            "<general><mode> does not set <second_stage>false</second_stage>: AutoYaST may "
            "boot the installed system into a second YaST stage that waits for a key"
        )

    if problems:
        for p in problems:
            print(f"{path}: {p}", file=sys.stderr)
        return 1
    print(f"{path}: ok")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("usage: lint-autoyast.py <profile.xml>", file=sys.stderr)
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
