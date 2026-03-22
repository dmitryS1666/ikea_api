Trestle.resource(:reviews, model: Review) do
  menu do
    item :reviews, icon: "fa fa-star", group: :sales, label: "Отзывы"
  end

  scopes do
    scope :all, default: true
    scope :pending, -> { Review.pending }
    scope :published, -> { Review.published }
    scope :rejected, -> { Review.rejected }
    scope :hidden, -> { Review.hidden }
  end

  table do
    column :id, label: "ID", link: true
    column :product_sku, label: "SKU товара"
    column :user, label: "Пользователь" do |review|
      review.user&.username || review.user_id
    end
    column :rating, label: "Рейтинг"
    column :status, label: "Статус" do |review|
      status_tag(review.status, review.status == 'published' ? :success : :secondary)
    end
    column :helpful_count, label: "Полезно"
    column "Фото" do |review|
      "#{review.photos.count} шт."
    end
    column :pinned, label: "Закреплен" do |review|
      status_tag(review.pinned? ? 'Да' : 'Нет',
                 review.pinned? ? :success : :secondary)
    end
    column :excluded_from_rating, label: "Исключен" do |review|
      status_tag(review.excluded_from_rating? ? 'Да' : 'Нет',
                 review.excluded_from_rating? ? :warning : :secondary)
    end
    column :created_at, label: "Дата", align: :center
    actions
  end

  form do |review|
    tab :basic, label: "Основное" do
      row do
        col(sm: 12) { text_field :product_sku, disabled: true, label: "SKU товара", help: "Артикул товара" }
      end

      row do
        col(sm: 12) { text_area :body, rows: 4, label: "Текст отзыва" }
      end

      row do
        col(sm: 12) { text_area :admin_note, rows: 3, label: "Примечание модератора" }
      end
    end

    tab :photos, label: "Фотографии" do
      # ...
    end

    sidebar do
      form_group :status_group, label: "Статус и оценка" do
        number_field :rating, label: "Рейтинг"
        select :status,
               Review.statuses.keys.map { |status| [status.humanize, status] },
               label: "Статус"
      end

      form_group :flags, label: "Настройки" do
        check_box :pinned, label: "Закрепить вверху"
        check_box :excluded_from_rating, label: "Исключить из рейтинга"
      end

      form_group :meta, label: "Метаданные" do
        static_field :created_at, label: "Дата создания"
        static_field :updated_at, label: "Дата изменения"
      end
    end
  end

  # Используем хук для вставки JS кода. 
  # Хук "resource.form.footer" вставит контент сразу после формы.
  hook("resource.form.footer") do
    content_tag(:script) do
      <<-JS.html_safe
        $(function() {
          $(document).on('change', '#js-review-photos-input', function() {
            var $preview = $('#js-photos-preview');
            $preview.empty();
            if (this.files) {
              $.each(this.files, function(i, file) {
                if (!file.type.match('image.*')) return;
                var reader = new FileReader();
                reader.onload = function(e) {
                  var html = '<div class="col-xs-3 col-sm-2"><div class="thumbnail">' +
                             '<img src="' + e.target.result + '" style="height: 80px; width: 100%; object-fit: cover;">' +
                             '</div></div>';
                  $preview.append(html);
                }
                reader.readAsDataURL(file);
              });
            }
          });
        });
      JS
    end
  end

  routes do
    get :delete_photo, on: :member
  end

  controller do
    def delete_photo
      review = admin.find_instance(params)
      photo = review.photos.find(params[:photo_id])
      photo.purge
      redirect_to admin.instance_path(review, action: :edit), notice: "Фото удалено"
    end
  end

  params do |params|
    params.require(:review).permit(
      :rating,
      :status,
      :body,
      :admin_note,
      :pinned,
      :excluded_from_rating,
      photos: []
    )
  end
end
