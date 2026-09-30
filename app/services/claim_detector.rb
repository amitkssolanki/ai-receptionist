# The "unbacked claim" heuristic: does an assistant line claim it changed the order ("I'll add garlic knots", "I've
# removed the fries")? It is pure text matching and NEVER authoritative: it only tells the console and the evaluation
# which assistant lines to compare with the server's record. The patterns are plain enough to be identical in Ruby and
# JavaScript; the console receives them from here (data attribute), so there is one list.
module ClaimDetector
  APOS = "['’]?".freeze

  PATTERNS = {
    "add" => "\\b(i#{APOS}ll add|i will add|i#{APOS}ve added|i have added|i added|i#{APOS}m adding|adding (it|that|those|them|one|two|three))\\b",
    "remove" => "\\b(i#{APOS}ve removed|i have removed|i removed|i#{APOS}ll remove|i will remove|taking (it|that|those|them) off)\\b",
    "change" => "\\b(i#{APOS}ve (changed|updated)|i have (changed|updated)|i (changed|updated)|i#{APOS}ll (change|update)|i will (change|update)) (that|your|the|it|them|to)\\b"
  }.freeze

  # Patterns as plain data for the browser: [{ kind:, source: }] (compile with the "i" flag).
  def self.browser_patterns = PATTERNS.map { |kind, source| { kind: kind, source: source } }

  # The first matching kind ("add" / "remove" / "change") or nil.
  def self.kind(text)
    PATTERNS.each { |kind, source| return kind if text.to_s.match?(Regexp.new(source, Regexp::IGNORECASE)) }
    nil
  end

  def self.claim?(text) = !kind(text).nil?
end
