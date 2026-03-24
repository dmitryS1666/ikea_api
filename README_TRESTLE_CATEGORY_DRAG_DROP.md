# Trestle drag-and-drop для категорий

Этот патч добавляет безопасное перемещение категорий по иерархии в Trestle.

Что делает:
- позволяет перетаскивать категорию в другую ветку;
- позволяет перетаскивать категорию в корень;
- не меняет `ikea_id`;
- пересчитывает `parent_ids` у всей подветки;
- не даёт создать цикл;
- чистит category cache.

---

## 1. Положить файлы в проект

Из архива нужно добавить:

- `app/services/categories/move_node_service.rb`
- `app/views/trestle/categories/_tree_drag_drop_assets.html.erb`

---

## 2. Изменить `app/admin/categories_admin.rb`

### 2.1. Добавить route

Внутрь блока `routes do`:

```ruby
post :move_node, on: :collection
```

### 2.2. Добавить action в `controller do`

```ruby
def move_node
  moved = Category.unscoped.find_by!(ikea_id: params[:moved_id].to_s)
  new_parent = params[:new_parent_id].present? ? Category.unscoped.find_by!(ikea_id: params[:new_parent_id].to_s) : nil

  result = Categories::MoveNodeService.new(
    moved_category: moved,
    new_parent_category: new_parent,
    actor: try(:current_user)
  ).call

  render json: {
    ok: true,
    moved_id: moved.ikea_id,
    new_parent_id: new_parent&.ikea_id,
    updated_ids: result.updated_ids
  }
rescue Categories::MoveNodeService::Error, ActiveRecord::RecordNotFound => e
  render json: { ok: false, error: e.message }, status: :unprocessable_entity
end
```

---

## 3. Изменить `app/views/trestle/categories/index.html.erb`

Перед рендером дерева добавь:

```erb
<%= render 'trestle/categories/tree_drag_drop_assets' %>

<div class="category-tree-drop-root" data-category-root-dropzone>
  Перетащи сюда, чтобы сделать категорию корневой
</div>

<div data-category-tree data-move-url="<%= admin.path(:move_node) %>">
  <%= render partial: 'trestle/categories/category_node', collection: @categories_tree, as: :node %>
</div>
```

Если дерево уже рендерится иначе, нужно просто обернуть текущий вывод дерева в:

```erb
<div data-category-tree data-move-url="<%= admin.path(:move_node) %>">
  ...
</div>
```

---

## 4. Изменить `app/views/trestle/categories/_category_node.html.erb`

Внутрь строки категории добавить drag handle.

Пример:

```erb
<div class="category-node" data-category-id="<%= category.ikea_id %>">
  <div class="category-item <%= 'disabled' if category.is_deleted? %>">
    <span class="category-drag-handle"
          data-category-drag-handle
          data-category-id="<%= category.ikea_id %>"
          draggable="true"
          title="Перетащить в другую категорию">
      <i class="fa fa-bars"></i>
    </span>

    <!-- дальше оставляешь текущий контент строки -->
  </div>

  <!-- дальше оставляешь текущий рендер children -->
</div>
```

Важно:
- `data-category-id` должен быть у `.category-node`
- `data-category-drag-handle` должен быть у handle
- handle должен иметь `draggable="true"`

---

## 5. Что проверить после установки

### Базовые сценарии
1. Перетащить leaf-категорию в другую ветку
2. Перетащить категорию с детьми
3. Перетащить категорию в корень
4. Попробовать перетащить категорию в саму себя
5. Попробовать перетащить категорию в собственного потомка

### Ожидаемый результат
- первые 3 сценария работают;
- последние 2 блокируются ошибкой;
- `ikea_id` не меняется;
- `parent_ids` у подветки пересчитываются;
- дерево после refresh отображается корректно.

---

## 6. Ограничения текущей версии

Это drag-and-drop **по иерархии**, но **без явного порядка внутри siblings**.

То есть:
- можно менять родителя;
- нельзя надёжно задавать порядок "выше/ниже" без отдельного поля `position`.

Если нужен ручной порядок внутри одной ветки, лучше добавить:
- `position: integer`

---

## 7. Как откатывать

Если нужно откатить патч:
- удалить route `move_node`;
- удалить action `move_node`;
- убрать partial `_tree_drag_drop_assets`;
- убрать drag handle из `_category_node.html.erb`;
- удалить `MoveNodeService`.

Данные, уже перемещённые этим сервисом, откатываются только обратным перемещением или через отдельный скрипт.
