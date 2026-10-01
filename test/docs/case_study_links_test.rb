require "test_helper"

# The case study links its claims to evidence in the repository; every relative link must point at a file that exists.
class CaseStudyLinksTest < ActiveSupport::TestCase
  DOCS = Rails.root.join("docs")

  def relative_links(path)
    path.read.scan(/\]\(([^)\s]+)\)/).flatten.reject { |href| href.match?(%r{\A(?:[a-z]+:|#)}i) }
  end

  test "every relative link in the case study points at a file in the repository" do
    links = relative_links(DOCS.join("CASE_STUDY.md"))
    assert_operator links.size, :>=, 20, "the case study should link its evidence"

    missing = links.reject { |href| DOCS.join(href.split("#").first).exist? }
    assert_empty missing, "broken links in docs/CASE_STUDY.md"
  end

  test "the README links to the case study" do
    assert_includes relative_links(Rails.root.join("README.md")), "docs/CASE_STUDY.md"
  end
end
