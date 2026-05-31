module ReturnRequests
  class CreateService
    class InvalidOrderNumber < StandardError; end
    class InvalidAttachments < StandardError; end

    Result = Struct.new(:return_request, :error, :status, keyword_init: true)

    ORDER_NUMBER_HINT = "Укажите номер заказа из 6–10 цифр (как в письме или личном кабинете).".freeze
    ORDER_NUMBER_FORMAT = /\A\d{6,10}\z/.freeze

    MAX_ATTACHMENTS = 5
    ALLOWED_ATTACHMENT_TYPES = %w[
      image/avif
      image/heic
      image/heif
      image/webp
      image/jpeg
      image/png
    ].freeze

    def self.call(params:, user: nil)
      new(params: params, user: user).call
    end

    def initialize(params:, user: nil)
      @params = params
      @user = user
    end

    def call
      order = resolve_order!
      files = normalized_files
      validate_files!(files)

      req = ReturnRequest.create!(build_attributes(order))
      attach_files!(req, files)

      Result.new(return_request: req, status: :created)
    rescue InvalidOrderNumber, InvalidAttachments => e
      Result.new(error: e.message, status: :unprocessable_entity)
    rescue ActiveRecord::RecordNotFound
      Result.new(error: "Заказ не найден", status: :not_found)
    rescue ActionController::ParameterMissing => e
      Result.new(error: "Не заполнено обязательное поле: #{e.param}", status: :unprocessable_entity)
    rescue ActiveRecord::RecordInvalid => e
      Result.new(error: e.record.errors.full_messages.join(", "), status: :unprocessable_entity)
    end

    private

    attr_reader :params, :user

    def build_attributes(order)
      number = order_number_param

      {
        order: order,
        user: user || order.user,
        order_number: number.presence || order.public_uid,
        last_name: last_name_param,
        first_name: first_name_param,
        patronymic: patronymic_param,
        phone: phone_param,
        email: email_param,
        reason: params.require(:reason),
        comment: params[:comment],
        compensation_type: compensation_type_param
      }
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
      return if number.match?(ORDER_NUMBER_FORMAT)

      raise InvalidOrderNumber, ORDER_NUMBER_HINT
    end

    def order_number_param
      raw = params[:order_number].presence || params[:order_id].presence || params[:order_num]
      raw.to_s.strip
    end

    def last_name_param
      params[:last_name].presence ||
        params[:surname].presence ||
        params[:family_name].presence ||
        user&.try(:last_name)
    end

    def first_name_param
      params[:first_name].presence ||
        params[:name].presence ||
        user&.try(:first_name)
    end

    def patronymic_param
      params[:patronymic].presence ||
        params[:middle_name].presence ||
        user&.try(:patronymic)
    end

    def phone_param
      params[:phone].presence || user&.try(:phone)
    end

    def email_param
      params[:email].presence || user&.try(:email)
    end

    def compensation_type_param
      raw = params[:compensation_type].presence ||
            params[:compensation_method].presence ||
            params[:preferred_compensation].presence

      # Legacy fallback: временно поддерживаем старый фронт,
      # который писал "Компенсация: возврат/обмен" в comment.
      comment = params[:comment].to_s
      raw ||= comment[/компенсация:\s*(\S+)/i, 1] if comment.match?(/компенсац/i)

      return "exchange" if raw.to_s.match?(/обмен|exchange/i)
      return "refund" if raw.to_s.match?(/возврат|refund/i)

      raw.presence
    end

    def normalized_files
      files = params[:attachments].presence || params[:photos].presence || params[:files]
      Array(files).reject(&:blank?)
    end

    def validate_files!(files)
      return if files.blank?

      if files.size > MAX_ATTACHMENTS
        raise InvalidAttachments, "Можно загрузить не более 5 файлов"
      end

      files.each do |file|
        content_type = file.respond_to?(:content_type) ? file.content_type.to_s : ""
        next if ALLOWED_ATTACHMENT_TYPES.include?(content_type)

        raise InvalidAttachments, "Допустимые форматы файлов: avif, heic, webp, jpeg, png"
      end
    end

    def attach_files!(req, files)
      return if files.blank?

      files.each { |f| req.attachments.attach(f) }
    end
  end
end
