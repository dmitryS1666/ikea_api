Trestle.resource(:return_requests, model: ReturnRequest) do
  menu do
    item :return_requests, icon: "fa fa-undo", group: :sales, label: "Возвраты"
  end

  table do
    column :id, link: true
    column :user do |r|
      link_to r.user.full_name, Trestle.lookup(:users).path(:show, id: r.user_id) if r.user
    end
    column :order do |r|
      link_to "Заказ ##{r.order_id}", Trestle.lookup(:orders).path(:show, id: r.order_id) if r.order
    end
    column :reason
    column :status do |r|
      status_tag(r.status, :info)
    end
    column :created_at, align: :center
    actions
  end

  form do |r|
    static_field :user, label: "Пользователь" do
      link_to r.user.full_name, Trestle.lookup(:users).path(:show, id: r.user_id) if r.user
    end
    static_field :order, label: "Заказ" do
      link_to "Заказ ##{r.order_id}", Trestle.lookup(:orders).path(:show, id: r.order_id) if r.order
    end
    text_area :reason, label: "Причина возврата"
    text_area :comment, label: "Комментарий администратора"
    select :status, ReturnRequest::STATUSES.map { |s| [s, s] }, label: "Статус"
  end
end
