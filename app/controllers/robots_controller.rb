class RobotsController < ApplicationController
  skip_before_action :authenticate_user

  def show
    body = <<~ROBOTS
      User-agent: *
      Disallow: /
    ROBOTS

    render plain: body, content_type: "text/plain"
  end
end
