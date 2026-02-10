Trestle.resource(:return_requests, model: ReturnRequest) do
  menu do
    item :return_requests, icon: "fa fa-undo", label: "Возвраты", group: "Support"
  end

  table do
    column :id, link: true
    column :user
    column :order
    column :reason
    column :status do |r|
      status_tag(r.status, :info)
    end
    column :created_at
    actions
  end

  form do |r|
    static_field :user
    static_field :order
    text_area :reason
    text_area :comment
    select :status, ReturnRequest::STATUSES.map { |s| [s, s] }
  end
end
