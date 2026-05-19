module ReturnRequestResponse
  extend ActiveSupport::Concern

  private

  def render_return_request_result(result)
    if result.return_request
      render json: { return_request: return_request_payload(result.return_request) }, status: result.status
    else
      render json: { error: result.error }, status: result.status
    end
  end

  def return_request_payload(r)
    {
      id: r.id,
      order_id: r.order_id,
      order_number: r.order_number,
      status: r.status,
      reason: r.reason,
      comment: r.comment,
      compensation_type: r.compensation_type,
      created_at: r.created_at.iso8601,
      attachments_count: r.attachments.count
    }
  end
end
