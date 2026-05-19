module ReturnRequests
  class CreateService
    class InvalidOrderNumber < StandardError; end

    Result = Struct.new(:return_request, :error, :status, keyword_init: true)

    ORDER_NUMBER_HINT = "Укажите номер заказа из 6–8 цифр (как в письме или личном кабинете).".freeze

    def self.call(params:, user: nil)
      new(params: params, user: user).call
    end

    def initialize(params:, user: nil)
      @params = params
      @user = user
    end

    def call
      order = resolve_order!
      req = ReturnRequest.create!(build_attributes(order))
      attach_files!(req)

      Result.new(return_request: req, status: :created)
    rescue InvalidOrderNumber => e
      Result.new(error: e.message, status: :unprocessable_entity)
    rescue ActiveRecord::RecordNotFound
      Result.new(error: "Заказ не найден", status: :not_found)
    end

    private

    attr_reader :params, :user

    def build_attributes(order)
      number = order_number_param
      attrs = {
        order: order,
        user: user || order.user,
        order_number: number.presence || order.public_uid,
        reason: params.require(:reason),
        comment: params[:comment],
        compensation_type: compensation_type_param
      }

      if user.nil?
        attrs.merge!(
          first_name: first_name_param,
          patronymic: params[:patronymic].presence || params[:middle_name],
          phone: params[:phone],
          email: params[:email]
        )
      end

      attrs
    end

    def resolve_order!
      number = order_number_param
      raise ActiveRecord::RecordNotFound if number.blank?

      validate_order_number_format!(number)

      if user
        Order.find_for_account!(user, number)
      elsif number.match?(Order::PUBLIC_UID_FORMAT)
        Order.find_by!(public_uid: number)
      else
        Order.find_by!(id: number)
      end
    end

    def validate_order_number_format!(number)
      return if number.match?(Order::PUBLIC_UID_FORMAT)
      return if number.match?(/\A\d+\z/)

      raise InvalidOrderNumber, ORDER_NUMBER_HINT
    end

    def order_number_param
      raw = params[:order_number].presence || params[:order_id].presence || params[:order_num]
      raw.to_s.strip
    end

    def first_name_param
      params[:first_name].presence || params[:name].to_s.split.first
    end

    def compensation_type_param
      raw = params[:compensation_type].presence || params[:compensation_method].presence ||
            params[:preferred_compensation]
      comment = params[:comment].to_s
      raw ||= comment[/компенсация:\s*(\S+)/i, 1] if comment.match?(/компенсац/i)

      return "exchange" if raw.to_s.match?(/обмен/i)
      return "refund" if raw.to_s.match?(/возврат|refund/i)

      raw.presence
    end

    def attach_files!(req)
      files = params[:attachments].presence || params[:photos].presence || params[:files]
      return if files.blank?

      Array(files).each { |f| req.attachments.attach(f) }
    end
  end
end
