class LegalPageSerializer
  include FastJsonapi::ObjectSerializer

  set_id :slug

  attributes :title, :slug, :updated_at

  attribute :body, if: proc { |_record, params| params&.dig(:detail) }
end
