class RobotsController < ApplicationController
  skip_before_action :authenticate_user

  def show
    body = <<~ROBOTS
      User-agent: *
      # Поиск закрыт через noindex. URL должен открываться, иначе робот не прочитает директиву.
      Allow: /search
      Disallow: /
    ROBOTS

    render plain: body, content_type: "text/plain"
  end
end
