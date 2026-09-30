require "test_helper"
require "open3"

# The console's pure JavaScript modules (no DOM, no Vapi) are plain ES modules tested with Node's built-in runner.
# Skipped where Node is not installed (CI's Ruby-only image); run locally with `node --test test/javascript/*.test.mjs`.
class JavascriptModulesTest < ActiveSupport::TestCase
  test "console JavaScript unit tests pass" do
    node, = Open3.capture2("which", "node")
    skip "node is not installed" if node.strip.empty?

    files = Dir[Rails.root.join("test/javascript/*.test.mjs").to_s]
    output, status = Open3.capture2e("node", "--test", *files)
    assert status.success?, output
  end
end
