namespace :evidence do
  desc "Regenerate docs/phase1/evidence/*.json (garlic-knots probe, latency, idempotency, cart versions, manifest)"
  task generate: :environment do
    abort "Run with RAILS_ENV=test (scenarios build their own data in a rolled-back transaction)." unless Rails.env.test?

    Evaluation::Evidence.generate.each { |name| puts "wrote docs/phase1/evidence/#{name}" }
  end

  desc "Record test-suite counts in docs/phase1/evidence/test_suite.json (runs the suite)"
  task suite: :environment do
    abort "Run with RAILS_ENV=test." unless Rails.env.test?

    body = Evaluation::Evidence.suite
    Evaluation::Evidence::DIR.join("test_suite.json").write(JSON.pretty_generate(body) + "\n")
    puts JSON.pretty_generate(body["results"])
  end
end
