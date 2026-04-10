Rails.application.routes.draw do
  # Trestle Admin Panel автоматически монтируется на /admin
  # (см. config/initializers/trestle.rb, config.automount = true)

  # Sidekiq UI: локально без пароля; на проде — Basic Auth (SIDEKIQ_WEB_USER / SIDEKIQ_WEB_PASSWORD)
  unless Rails.env.test?
    require "sidekiq/web"

    if Rails.env.development?
      mount Sidekiq::Web => "/sidekiq"
    elsif ENV["SIDEKIQ_WEB_USER"].present? && ENV["SIDEKIQ_WEB_PASSWORD"].present?
      mount Rack::Builder.new {
        use Rack::Auth::Basic, "Sidekiq" do |username, password|
          ActiveSupport::SecurityUtils.secure_compare(username.to_s, ENV.fetch("SIDEKIQ_WEB_USER")) &&
            ActiveSupport::SecurityUtils.secure_compare(password.to_s, ENV.fetch("SIDEKIQ_WEB_PASSWORD"))
        end
        run Sidekiq::Web
      } => "/sidekiq"
    end
  end

  # Swagger авторизация
  get '/api-docs/login', to: 'swagger#login'
  post '/api-docs/login', to: 'swagger#login'
  get '/api-docs/logout', to: 'swagger#logout'
  
  mount Rswag::Api::Engine => '/api-docs'
  mount Rswag::Ui::Engine => '/api-docs'

  namespace :admin do
    get "products/by_category", to: "products#by_category"
    get "products/search", to: "products#search"
  end
  
  namespace :api do
    namespace :v1 do
      # Products
      resources :products, only: [:index, :show], param: :sku do
        collection do
          get :bestsellers
          get :new_arrivals
          get :recommended
          get :popular
#          get :categories
        end

        resources :reviews, only: [:create]
      end

      resources :reviews, only: [:update, :destroy] do
        member do
          post :helpful
          delete :helpful, action: :remove_helpful
        end
      end

      namespace :account do
        resources :reviews, only: [:index] do
          collection do
            get :available
          end
        end
        resources :orders, only: [:index, :show] do
          member do
            post :reorder
          end
        end
        resource :profile, only: [:show, :update], controller: 'profile' do
          post :change_phone_request
          post :change_phone_verify
          post :change_email_verify
        end

        resources :purchases, only: [:index]
        resources :returns, only: [:index, :create]
        resources :receipts, only: [:index]
      end
      
      # Categories
      resources :categories, only: [:index, :show] do
        collection do
          get :popular
          get :top
          get :custom
          get :header_menu
          get :tree
          get :map
        end
        member do
          get :products
        end
      end
      
      # Delivery
      resources :delivery, only: [] do
        collection do
          get :types
          post :calculate
          get :pickup_points
          get :pickup_points_search
          get :europost_offices
          get :autolight_offices
        end
      end
      
      # Auth
      post 'auth/login', to: 'auth#login'
      post 'auth/register', to: 'auth#register'
      post 'auth/phone/send', to: 'auth#send_phone_code'
      post 'auth/phone/verify', to: 'auth#verify_phone_code'
      post 'auth/phone/check', to: 'auth#check_phone'

      # A1 verification (stub for now)
      post 'a1/request', to: 'a1_verifications#request_call'
      post 'a1/verify', to: 'a1_verifications#verify_call'
      
      # Search
      resources :search, only: [] do
        collection do
          get :suggest
        end
      end

      # Homepage
      get 'homepage/slider/main', to: 'homepage#slider_main'
      get 'homepage/slider/banners', to: 'homepage#slider_banners'
      get 'homepage/recommendations', to: 'homepage#recommendations'

      # Cart
      resource :cart, controller: 'cart', only: [:show] do
        delete '/', action: :clear, on: :member
      end

      resources :cart_items, only: [:create] do
        patch ':sku', to: 'cart_items#update', on: :collection
        delete ':sku', to: 'cart_items#destroy', on: :collection
        delete '', to: 'cart_items#bulk_destroy', on: :collection
      end

      # Favorites
      resource :favorites, controller: 'favorites', only: [:show] do
        delete '/', action: :clear, on: :member
      end

      resources :favorites, only: [:create, :destroy]

      post 'cart/promo/apply', to: 'cart_promo#apply'
      delete 'cart/promo/remove', to: 'cart_promo#remove'

      # Content
      namespace :content do
        resources :articles, only: [:index, :show], param: :slug
      end

      # Reviews Export (API version)
      get 'reviews/export(.:format)', to: 'reviews_exports#index'
      
      # Checkout
      post 'checkout', to: 'checkout#create'

      # Debug & Integration (AmoCRM)
      namespace :debug do
        namespace :amo_crm do
          post 'sync_order/:id', to: 'amo_crm#sync_order'
          post 'sync_user/:id', to: 'amo_crm#sync_user'
          post 'exchange_token', to: 'amo_crm#exchange_token'
        end
      end

      # Webhooks
      namespace :webhooks do
        post 'amo_crm', to: 'amo_crm#receive'
      end
    end
  end

  # System & Feeds
  get '/up', to: 'health#check'
  get '/feeds/google.xml', to: 'feeds#google'
  get '/feeds/yandex.yml', to: 'feeds#yandex'
  get '/sitemap.xml', to: 'sitemaps#show'
  get '/robots.txt', to: 'robots#show'
end
