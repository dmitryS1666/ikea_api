FactoryBot.define do
  factory :phone_verification_request do
    phone { "MyString" }
    status { "MyString" }
    error_message { "MyText" }
    ip_address { "MyString" }
    user_agent { "MyString" }
    metadata { "" }
  end
end
