# Deterministic, speakable text generated from server state. The model is told to say these words as given, so
# what the caller hears is what the server has - not the model's memory of the conversation.
module OrderTaking::Readback
  ONES = %w[zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen
            seventeen eighteen nineteen].freeze
  TENS = %w[_ _ twenty thirty forty fifty sixty seventy eighty ninety].freeze

  module_function

  # "One Margherita Pizza with extra cheese and two Garlic Knots. Total sixteen dollars."
  def cart(order)
    return "The cart is empty." if order.nil? || order.order_items.none?

    sentence = lines(order).to_sentence
    "#{sentence[0].upcase}#{sentence[1..]}. Total #{money(order.total_cents)}."
  end

  def added(order_item, order)
    "Added #{line(order_item)}. The total is now #{money(order.total_cents)}."
  end

  def changed(order_item, order)
    "Changed #{order_item.menu_item.name} to #{words(order_item.quantity)}. The total is now #{money(order.total_cents)}."
  end

  def removed(name, order)
    "Removed #{name}. #{order.order_items.none? ? 'The cart is now empty.' : "The total is now #{money(order.total_cents)}."}"
  end

  def lines(order) = order.order_items.map { |item| line(item) }

  def line(item)
    text = "#{words(item.quantity)} #{item.menu_item.name}"
    modifiers = item.selected_modifiers.map { |m| spoken(m["name"]) }
    modifiers.any? ? "#{text} with #{modifiers.to_sentence}" : text
  end

  # Lower-case a leading capital ("Extra cheese" -> "extra cheese") but leave acronyms ("BBQ sauce") alone.
  def spoken(name) = name.sub(/\A[A-Z](?=[a-z])/) { |c| c.downcase }

  def money(cents)
    dollars, rest = cents.divmod(100)
    text = "#{words(dollars)} #{dollars == 1 ? 'dollar' : 'dollars'}"
    rest.zero? ? text : "#{text} and #{words(rest)} #{rest == 1 ? 'cent' : 'cents'}"
  end

  def words(number)
    return ONES[number] if number < 20
    return TENS[number / 10] + (number % 10).then { |r| r.zero? ? "" : "-#{ONES[r]}" } if number < 100
    return "#{ONES[number / 100]} hundred#{number % 100 > 0 ? " #{words(number % 100)}" : ''}" if number < 1000
    return number.to_s if number >= 1_000_000

    "#{words(number / 1000)} thousand#{number % 1000 > 0 ? " #{words(number % 1000)}" : ''}"
  end
end
