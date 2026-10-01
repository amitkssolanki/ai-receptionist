# The channel the voice console subscribes through (turbo_stream_from ..., channel: ConsoleChannel). It is Turbo's own
# streams channel plus an authorization step: a valid signed stream name is not enough, the stream must also belong to
# the signed-in user's restaurant. Deny by default.
#
#   [:console_session, key]   bootstrap stream of a console page: any signed-in admin holding the signed name
#   [call_log, :console]      everything about one call: only that call's restaurant
class ConsoleChannel < ApplicationCable::Channel
  extend Turbo::Streams::Broadcasts, Turbo::Streams::StreamName
  include Turbo::Streams::StreamName::ClassMethods

  def subscribed
    stream_name = verified_stream_name_from_params
    if stream_name.present? && subscription_allowed?(stream_name)
      stream_from stream_name
    else
      reject
    end
  end

  private

  # Turbo names a stream by joining its streamables: "console_session:<key>", or "<CallLog global id param>:console".
  def subscription_allowed?(stream_name)
    first, second, *rest = stream_name.split(":")
    return false if first.blank? || second.blank? || rest.any?

    if first == "console_session"
      true
    elsif second == "console"
      call_log = GlobalID::Locator.locate(GlobalID.parse(first))
      call_log.is_a?(CallLog) && call_log.restaurant_id == current_user.restaurant_id
    else
      false
    end
  rescue StandardError
    false
  end
end
