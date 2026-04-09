const POS_WORDS = Set([
    "great", "awesome", "thanks", "good", "fantastic", "excellent", "happy", "joy",
    "wonderful", "brilliant", "support", "clarity", "help", "solve", "guide", "create",
    "build", "innovate", "progress", "success", "win", "improve", "calm", "relaxed",
    "relief", "confident", "thankful", "appreciate", "grateful", "team", "collaborate", "ally",
    "energized", "motivated", "inspired", "bright", "spark", "positive", "optimistic",
    "steady", "resilient", "glad", "hopeful", "focus", "clarify", "achieve", "resolve",
    "empower", "assist",
])

const NEG_WORDS = Set([
    "bad", "hate", "angry", "annoyed", "frustrated", "upset", "broken", "issue",
    "problem", "confused", "lost", "stuck", "sad", "terrible", "awful", "worst",
    "fail", "error", "panic", "worry", "anxiety", "fear", "hurt", "tired",
    "exhausted", "depressed", "miserable", "scared", "danger", "crash", "stop",
    "delay", "weak", "stress", "tension", "dread", "overwhelmed", "rude",
    "hostile", "suck",
])

const DIRECTIVE_PHRASES = [
    "be concise", "just answer", "short answer", "no fluff", "get to the point",
    "bullet points", "keep it short", "fast summary", "direct answer",
    "only the essentials", "tell me the facts", "focus", "minimal words",
    "skip the fluff", "straight answer", "rapid response",
]

const CONFUSE_WORDS = Set([
    "confused", "lost", "stuck", "don't", "get", "not", "sure", "unclear",
    "huh", "what", "why", "help",
])

struct SignalScorer end

function _clamp_unit(value::Real)
    return max(0.0, min(1.0, Float64(value)))
end

function score(::SignalScorer, text::AbstractString)
    lowered = lowercase(text)
    words = [String(match.match) for match in eachmatch(r"[a-z']+", lowered)]
    wlen = length(words)

    pos_hits = count(word -> word in POS_WORDS, words)
    neg_hits = count(word -> word in NEG_WORDS, words)
    sentiment = (pos_hits - neg_hits) / max(1, wlen)
    sentiment = max(-1.0, min(1.0, sentiment * 6.0))

    directive = any(phrase -> occursin(phrase, lowered), DIRECTIVE_PHRASES)
    confusion_hits = count(word -> word in CONFUSE_WORDS, words) + count(==('?'), lowered)
    confusion = _clamp_unit(confusion_hits / max(3, wlen))

    exclaim = count(==('!'), lowered)
    upper_hits = 0
    arousal = (wlen * 0.04) + (exclaim > 0 ? 0.25 : 0.0) + max(0, exclaim - 1) * 0.05 + (upper_hits > 0 ? 0.2 : 0.0)
    arousal = _clamp_unit(arousal)

    pace = (min(wlen, 30) / 30.0) + (exclaim > 0 ? 0.10 : 0.0)
    pace = _clamp_unit(pace)

    memory_density = (wlen / 35.0) + (confusion_hits * 0.08)
    memory_density = _clamp_unit(memory_density)

    return TurnSignals(sentiment, arousal, directive, confusion, pace, memory_density)
end
