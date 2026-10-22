"""Deterministic second layer before TTS. Never calls another model."""
from dataclasses import dataclass
import re

NUMBER = r"(?:\d+(?:[.,]\d+)?|one|two|three|four|five|six|seven|eight|nine|ten|half|quarter)"
DOSE = re.compile(rf"\b{NUMBER}\s*(?:mg|mcg|μg|ug|g|kg|ml|milligrams?|micrograms?|grams?|millilit(?:er|re)s?|pills?|tablets?|capsules?|teaspoons?|tablespoons?|doses?)\b", re.I)
BANNED = re.compile(r"\b(?:calm(?:ing)? down|let'?s calm down|relax|don't panic|do not panic|everything will be fine|you(?:'re| are) fine|you(?:'ll| will) be (?:okay|ok)|it's nothing|it(?:'s| is) (?:not )?your fault|(?:you are|you're) uninjured)\b", re.I)
SCORING = re.compile(r"C-SSRS|SAFE-T|Columbia.{0,20}(?:score|scale)|(?:low|moderate|high)[ -](?:acute[ -])?risk|lethality.{0,15}(?:score|scale)|hospitalization disposition", re.I)
ACTION = re.compile(r"\b(?:done(?=[.!]?$)|sent(?=[.!]?$)|i(?:'ve| have)? (?:called|sent|notified|alerted|contacted|shared|booked)|help (?:is|are) (?:coming|on the way)|help knows where you are|they(?:'re| are) on the way)\b", re.I)
DOSE_FALLBACK = "I can't give a medication dose."


@dataclass(frozen=True)
class Decision:
    action: str
    text: str
    reason: str


def filter_sentence(text, successful_actions=(), medication_question=False):
    normalized = text.strip().replace("’", "'")
    # Clean leading list markers like '- ', '* ', '1. ', '• ' so speech sounds natural
    normalized = re.sub(r"^(?:[-*•]\s+|\d+[.)]\s+)", "", normalized).strip()
    if not normalized:
        return Decision("drop", "", "empty")
    if DOSE.search(normalized):
        return Decision("rewrite", DOSE_FALLBACK, "dose_pattern")
    if medication_question and re.search(r"\b(?:take|give|swallow|use)\b.{0,30}" + NUMBER, normalized, re.I):
        return Decision("rewrite", DOSE_FALLBACK, "medication_quantity")
    if BANNED.search(normalized):
        return Decision("drop", "", "banned_phrase")
    if SCORING.search(normalized):
        return Decision("drop", "", "clinical_scoring")
    if ACTION.search(normalized) and not successful_actions:
        return Decision("rewrite", "I don't have confirmation that worked.", "unconfirmed_action")
    # Match claimed action to a specific successful flag, not any unrelated success.
    required = [(r"called|help|on the way", "emergency_call_prompt"), (r"sent|notified|alerted|contacted", "alert_contacts"),
                (r"shared", "share_location"), (r"booked", "book_tow_or_submit_claim")]
    for pattern, action in required:
        if ACTION.search(normalized) and re.search(pattern, normalized, re.I) and action not in successful_actions:
            return Decision("rewrite", "I don't have confirmation that worked.", "unmatched_action")
    # Showing a call prompt never establishes dispatch or a connected emergency call.
    if ACTION.search(normalized) and re.search(r"called|help (?:is|are)|on the way", normalized, re.I):
        return Decision("drop", "", "call_prompt_not_dispatch_confirmation")
    if re.search(r"https?://|[\[\]{}*_#<>]|\b(?:tool_call|function_name)\b", normalized):
        return Decision("drop", "", "not_speech")
    return Decision("pass", normalized, "accepted")


class SentenceStream:
    def __init__(self):
        self.buffer = ""

    def push(self, text, final=False):
        self.buffer += text
        result = []
        # Don't split a decimal dose such as 2.5 mg across sentences.
        while True:
            m = re.search(r"(?<!\d)[.!?](?=\s|$)|(?<=\d)[!?](?=\s|$)", self.buffer)
            if not m:
                break
            result.append(self.buffer[:m.end()].strip())
            self.buffer = self.buffer[m.end():].lstrip()
        if final and self.buffer.strip():
            result.append(self.buffer.strip())
            self.buffer = ""
        if len(self.buffer) > 1500:
            # Never speak an unbounded unfinished fragment.
            self.buffer = ""
        return result
