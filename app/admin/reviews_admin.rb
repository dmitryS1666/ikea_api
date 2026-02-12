Trestle.resource(:reviews, model: Review) do
  menu do
    item :reviews, icon: "fa fa-star", label: "Отзывы", group: "Content"
  end

  scopes do
    scope :all, default: true
    scope :pending, -> { Review.pending }
    scope :published, -> { Review.published }
    scope :rejected, -> { Review.rejected }
    scope :hidden, -> { Review.hidden }
  end

  table do
    column :id, link: true
    column :product_sku
    column :user do |review|
      review.user&.username || review.user_id
    end
    column :rating
    column :status do |review|
      status_tag(review.status, review.status == 'published' ? :success : :secondary)
    end
    column :helpful_count
    column "Фото" do |review|
      "#{review.photos.count} шт."
    end
    column :pinned do |review|
      status_tag(review.pinned? ? 'Да' : 'Нет',
                 review.pinned? ? :success : :secondary)
    end
    column :excluded_from_rating do |review|
      status_tag(review.excluded_from_rating? ? 'Да' : 'Нет',
                 review.excluded_from_rating? ? :warning : :secondary)
    end
    column :created_at
    actions
  end

  form do |review|
    row do
      col(sm: 4) { number_field :rating }
      col(sm: 4) do
        select :status,
               Review.statuses.keys.map { |status| [status.humanize, status] },
               label: "Статус"
      end
      col(sm: 4) { check_box :pinned }
    end

    row do
      col(sm: 6) { check_box :excluded_from_rating, label: "Исключить из рейтинга" }
      col(sm: 6) { text_field :product_sku, disabled: true, hint: "SKU товара" }
    end

    row do
      col(sm: 12) { text_area :body, rows: 4 }
    end

    row do
      col(sm: 12) { text_area :admin_note, rows: 3, label: "Примечание модератора" }
    end

    if review.photos.attached?
      row do
        col do
          form_group :existing_photos, label: "Текущие фотографии" do
            content_tag(:div, class: "row") do
              review.photos.each do |photo|
                concat(
                  content_tag(:div, class: "col-xs-3 col-sm-2", style: "margin-bottom: 20px;") do
                    content_tag(:div, class: "thumbnail", style: "margin-bottom: 5px;") do
                      image_tag(main_app.rails_blob_path(photo, only_path: true), style: "width: 100%; height: 100px; object-fit: cover;")
                    end +
                    link_to("Удалить", admin.instance_path(review, action: :delete_photo, photo_id: photo.id), 
                      class: "btn btn-danger btn-xs btn-block", 
                      data: { confirm: "Удалить это фото?" })
                  end
                )
              end
            end
          end
        end
      end
    end

    row do
      col do
        file_field :photos, multiple: true, label: "Добавить фото (макс. 5)", id: "js-review-photos-input"
        content_tag(:div, id: "js-photos-preview", class: "row", style: "margin-top: 10px;") do
          # Сюда JS будет вставлять превью
        end
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
