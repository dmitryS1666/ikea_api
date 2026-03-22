Trestle.resource(:return_requests, model: ReturnRequest) do
  menu do
    item :return_requests, icon: "fa fa-undo", group: :sales, label: "Возвраты"
  end

  table do
    column :id, label: "ID", link: true
    column :user, label: "Пользователь"
    column :order, label: "Заказ"
    column :reason, label: "Причина"
    column :status, label: "Статус" do |r|
      status_tag(r.status, :info)
    end
    column :created_at, label: "Дата", align: :center
    actions
  end

  form do |r|
    static_field :user, label: "Пользователь"
    static_field :order, label: "Заказ"
    text_area :reason, label: "Причина возврата"
    text_area :comment, label: "Комментарий администратора"
    select :status, ReturnRequest::STATUSES.map { |s| [s, s] }, label: "Статус"
  end
end
