# View-models for the voice console's server-authoritative panels. Everything here is derived from committed database
# state (Order, ToolInvocation, CallLog) and never from a transcript or a raw Vapi payload. They decide what is safe to
# show: ids are resolved to names, free text and addresses are summarised, nothing from a provider payload is exposed.
module ConsoleView
  # A DOM-id-safe token from a provider-supplied id (tool call ids are attacker-influenced strings).
  def self.dom_token(value) = value.to_s.gsub(/[^\w-]/, "_").first(80)

  # "14:05:09" in the restaurant's own time zone (server clock, never mixed with browser time).
  def self.clock(time, restaurant)
    time&.in_time_zone(restaurant.timezone)&.strftime("%H:%M:%S")
  end

  # "01:47": seconds since the call started, from server timestamps only.
  def self.offset(time, since)
    return "--:--" unless time && since

    total = [ (time - since).to_i, 0 ].max
    format("%02d:%02d", total / 60, total % 60)
  end
end
