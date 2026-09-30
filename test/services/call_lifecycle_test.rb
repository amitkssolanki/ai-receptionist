require "test_helper"

class CallLifecycleTest < ActiveSupport::TestCase
  setup { @restaurant = Restaurant.create!(name: "Life Bistro", phone_number: "+15550004444") }

  def start(id: "life_1", dialed: @restaurant.phone_number, caller: "+15559990000")
    CallLifecycle.start(external_call_id: id, dialed_number: dialed, caller_number: caller)
  end

  test "start creates a call log and customer for the dialed restaurant" do
    call_log = start
    assert_equal @restaurant, call_log.restaurant
    assert_equal "+15559990000", call_log.customer.phone_number
    assert_predicate call_log, :in_progress?
    assert_predicate call_log.started_at, :present?
  end

  test "start without a caller number uses a synthetic unknown-<call id> customer" do
    assert_equal "unknown-life_2", start(id: "life_2", caller: nil).phone_number
  end

  test "start is a no-op for a blank id or a call that already exists" do
    assert_nil start(id: nil)
    start
    assert_nil start
    assert_equal 1, CallLog.count
  end

  test "start falls back to the only restaurant, but refuses when there are several and none match" do
    assert_equal @restaurant, start(id: "life_3", dialed: "+19998887777").restaurant

    Restaurant.create!(name: "Second", phone_number: "+15550005555")
    assert_nil start(id: "life_4", dialed: "+19998887777")
    assert_nil CallLog.find_by(external_call_id: "life_4")
  end

  test "transfer marks the call transferred and appends the reason to the transcript" do
    call_log = start
    CallLifecycle.transfer(call_log, "caller asked for a person")
    assert_predicate call_log.reload, :transferred?
    assert_equal "[Transferred to human: caller asked for a person]", call_log.transcript

    CallLifecycle.transfer(call_log, nil)
    assert_equal "[Transferred to human: caller asked for a person]\n[Transferred to human]", call_log.reload.transcript
  end

  test "finish completes a call with a confirmed order and abandons one without" do
    abandoned = start(id: "life_a")
    CallLifecycle.finish(external_call_id: "life_a", transcript: "AI: hi", recording_url: "https://example.test/r.wav")
    assert_predicate abandoned.reload, :abandoned?
    assert_equal [ "AI: hi", "https://example.test/r.wav" ], [ abandoned.transcript, abandoned.recording_url ]
    assert_predicate abandoned.ended_at, :present?

    completed = start(id: "life_c")
    completed.update!(order: @restaurant.orders.create!(customer: completed.customer, fulfillment_type: :pickup, status: :confirmed))
    CallLifecycle.finish(external_call_id: "life_c", transcript: nil, recording_url: nil)
    assert_predicate completed.reload, :completed?
  end

  test "finish for an unknown call does nothing" do
    assert_nil CallLifecycle.finish(external_call_id: "nope", transcript: "x", recording_url: nil)
  end
end
