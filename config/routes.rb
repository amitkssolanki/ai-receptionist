Rails.application.routes.draw do
  devise_for :users, skip: [ :registrations ]

  namespace :admin do
    resources :menu_categories, shallow: true do
      resources :menu_items, shallow: true do
        resources :menu_item_modifiers, except: [ :index, :show ]
      end
    end
    resources :orders, only: [ :index, :show, :update ]
    resources :call_logs, only: [ :index, :show ]
    resource :restaurant, only: [ :edit, :update ]
  end

  namespace :api do
    namespace :voice do
      resources :calls, only: [ :create ], param: :external_call_id do
        member do
          get :menu
          get :cart
          post :submit
          post :transfer
          post :end_call
        end
        resources :cart_items, only: [ :create, :update, :destroy ]
      end
    end

    namespace :vapi do
      post :webhooks, to: "webhooks#create"
    end
  end

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  root "admin/dashboards#show"
end
