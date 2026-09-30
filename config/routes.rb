Rails.application.routes.draw do
  devise_for :users, skip: [ :registrations ], controllers: { sessions: "users/sessions" }

  namespace :admin do
    resources :menu_categories, shallow: true do
      resources :menu_items, shallow: true do
        resources :menu_item_modifiers, except: [ :index, :show ]
      end
    end
    resources :orders, only: [ :index, :show, :update ]
    resources :call_logs, only: [ :index, :show ]
    resource :restaurant, only: [ :edit, :update ]

    # Voice test console: start a browser call, watch the conversation (Vapi) next to what the server did (Rails).
    get "console", to: "console#show", as: :console
    post "console/token", to: "console#token", as: :console_token
    post "console/attach", to: "console#attach", as: :console_attach
    get "console/calls/:id", to: "console#call", as: :console_call
    get "console/calls/:id/state", to: "console#state", as: :console_call_state
  end

  namespace :api do
    namespace :vapi do
      post :webhooks, to: "webhooks#create"
    end
  end

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  root "admin/dashboards#show"
end
