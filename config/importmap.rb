# Pin npm packages by running ./bin/importmap

pin "application"
pin "@hotwired/turbo-rails", to: "turbo.min.js"
pin "@hotwired/stimulus", to: "stimulus.min.js"
pin "@hotwired/stimulus-loading", to: "stimulus-loading.js"
pin_all_from "app/javascript/controllers", under: "controllers"
pin_all_from "app/javascript/console", under: "console"

# Vapi Web SDK, vendored from jsDelivr's +esm builds (see docs/phase1/EXECUTION_LOG.md, Step 12)
pin "@vapi-ai/web", to: "vapi-web.js"       # @2.7.1
pin "@daily-co/daily-js", to: "daily-js.js" # @0.87.0
