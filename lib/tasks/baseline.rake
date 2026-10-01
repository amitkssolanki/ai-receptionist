require "digest"
require "fileutils"
require "tmpdir"
require "open3"

# Phase 1 / Step 0. The Phase 0 evidence under test/fixtures/files/baseline is frozen:
#   baseline:manifest  checks every file against SHA256SUMS (no git, no DB; also run from the test suite)
#   baseline:verify    manifest + re-runs the ORIGINAL characterization (23) and replay (2) tests against a
#                      throwaway worktree of the portfolio-baseline tag, in a throwaway database
module Baseline
  TAG = "portfolio-baseline"
  COMMIT = "257a9e71c5a3f6cc5ef45b224732857773b12ef3"
  DIR = Rails.root.join("test/fixtures/files/baseline")
  TESTS = %w[reliability_characterization_test.rb live_call_replay_test.rb].freeze

  def self.manifest_problems
    expected = File.readlines(DIR.join("SHA256SUMS"), chomp: true).reject(&:blank?).to_h do |line|
      digest, path = line.split(/\s+/, 2)
      [ path, digest ]
    end
    actual = Dir.chdir(DIR) { Dir.glob("**/*", File::FNM_DOTMATCH).select { |f| File.file?(f) } } -
             %w[SHA256SUMS FROZEN.md]

    problems = (expected.keys - actual).map { |f| "missing: #{f}" } +
               (actual - expected.keys).map { |f| "unlisted: #{f}" }
    (expected.keys & actual).each do |f|
      problems << "modified: #{f}" unless Digest::SHA256.file(DIR.join(f)).hexdigest == expected[f]
    end
    problems.sort
  end
end

namespace :baseline do
  desc "Check the frozen Phase 0 evidence against SHA256SUMS"
  task :manifest do
    problems = Baseline.manifest_problems
    abort "Frozen baseline evidence changed:\n  #{problems.join("\n  ")}" if problems.any?
    puts "baseline:manifest OK (frozen evidence matches SHA256SUMS)"
  end

  desc "Verify frozen evidence and re-run the original R01-R23 + live-call replay tests against the tag"
  task verify: :manifest do
    root = Rails.root.to_s
    sha, = Open3.capture2("git", "-C", root, "rev-parse", "#{Baseline::TAG}^{commit}")
    abort "Tag #{Baseline::TAG} is #{sha.strip.inspect}, expected #{Baseline::COMMIT}" unless sha.strip == Baseline::COMMIT

    work = Dir.mktmpdir("baseline-verify")
    tree = File.join(work, "tree")
    db = "ai_receptionist_baseline_verify"
    env = { "RAILS_ENV" => "test", "DATABASE_URL" => "postgres:///#{db}", "PARALLEL_WORKERS" => "1" }
    bundle_env = { "BUNDLE_GEMFILE" => nil }
    ok = false
    begin
      system("git", "-C", root, "worktree", "add", "--detach", tree, Baseline::TAG, out: File::NULL, err: File::NULL) || abort("git worktree add failed")

      # Originals, with the .frozen suffix removed, next to their fixtures - exactly how Phase 0 ran them.
      dest = File.join(tree, "tmp/baseline_frozen")
      FileUtils.mkdir_p(dest)
      FileUtils.cp_r(Dir.glob(Baseline::DIR.join("*")), dest)
      Baseline::TESTS.each { |t| File.rename(File.join(dest, "#{t}.frozen"), File.join(dest, t)) }

      run = ->(*cmd) { system(env.merge(bundle_env), *cmd, chdir: tree) }
      run.call("bin/rails", "db:drop", "db:create", "db:schema:load") || abort("could not prepare #{db}")
      files = Baseline::TESTS.map { |t| File.join(dest, t) }
      ok = run.call("bin/rails", "test", *files)
    ensure
      system(env.merge(bundle_env), "bin/rails", "db:drop", chdir: tree, out: File::NULL, err: File::NULL) if File.directory?(tree)
      system("git", "-C", root, "worktree", "remove", "--force", tree, out: File::NULL, err: File::NULL)
      FileUtils.rm_rf(work)
    end
    abort "baseline:verify FAILED" unless ok
    puts "baseline:verify OK (originals pass against #{Baseline::TAG} #{Baseline::COMMIT[0, 7]})"
  end
end
