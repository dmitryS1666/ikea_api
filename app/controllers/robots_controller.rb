class RobotsController < ApplicationController
  def show
    body = <<~ROBOTS
      User-agent: *
      Disallow: /
    ROBOTS

    render plain: body, content_type: "text/plain"
  end
end
