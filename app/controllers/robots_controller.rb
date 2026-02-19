class RobotsController < ApplicationController
  def show
    render "robots/show", layout: false, content_type: "text/plain"
  end
end
