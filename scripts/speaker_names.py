"""Helpers for extracting person name fields from scraped speaker labels."""

import re


_TITLE_PREFIX_RE = re.compile(
    r"^(?:(?:President|Elder|Sister|Brother|Bishop|Apostle|Seventy)\s+)+",
    re.IGNORECASE,
)
_SUFFIX_RE = re.compile(r",?\s+(?:Jr|Sr|II|III|IV)\.?$", re.IGNORECASE)
_NAME_PART_RE = re.compile(
    r"[^\W\d_]+(?:[.'’\-][^\W\d_]+)*\.?",
    re.UNICODE,
)


def parse_speaker_name(speaker):
    """Return (first, middle, last), removing common ecclesiastical titles.

    The full scraped label remains available separately for display. If the
    label does not contain at least two name parts, the fields are all None.
    """
    if not isinstance(speaker, str):
        return None, None, None

    name = speaker.strip()
    name = _TITLE_PREFIX_RE.sub("", name)
    name = _SUFFIX_RE.sub("", name)
    parts = _NAME_PART_RE.findall(name)

    if len(parts) < 2:
        return None, None, None

    first_name = parts[0]
    last_name = parts[-1].rstrip(".")
    middle_name = " ".join(parts[1:-1]) or None
    return first_name, middle_name, last_name
