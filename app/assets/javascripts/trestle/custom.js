// This file may be used for providing additional customizations to the Trestle
// admin. It will be automatically included within all admin pages.
//
// For organizational purposes, you may wish to define your customizations
// within individual partials and `require` them here.
//
//  e.g. //= require "trestle/custom/my_custom_js"

//= require activestorage
//= require trestle/content_article_builder

(function() {
  function initSelect2Ajax() {
    $('[data-ui="select2-ajax"]').each(function() {
      const $el = $(this);
      const url = $el.data('ajax-url');

      $el.select2({
        theme: 'bootstrap',
        width: '100%',
        multiple: $el.prop('multiple'),
        tags: $el.data('tags') === true,
        tokenSeparators: [',', ' ', '\n', '\r'],
        ajax: {
          url: url,
          dataType: 'json',
          delay: 250,
          data: function(params) {
            return {
              q: params.term,
              page: params.page
            };
          },
          processResults: function(data, params) {
            params.page = params.page || 1;
            return {
              results: data.map(function(item) {
                return {
                  id: item.sku,
                  text: item.text
                };
              }),
              pagination: {
                more: false
              }
            };
          },
        cache: true
      },
      minimumInputLength: 2,
      placeholder: $el.attr('placeholder') || 'Начните ввод для поиска...',
      allowClear: true
    });

      // Make search active by default and visible
      setTimeout(function() {
        if ($el.data('select2')) {
          $el.select2('open');
        }
      }, 0);
    });

    // Handle "add product" button for article links
    $('.article-links-add-btn').off('click.articleLinks').on('click.articleLinks', function() {
      var $btn = $(this);
      var addUrl = $btn.data('add-url');
      if (!addUrl) return;

      var $select = $btn.closest('.article-links-box').find('select.article-links-search');
      if (!$select.length) return;

      var data = $select.select2('data');
      var selected = data && data.length ? (data[0].id || data[0].sku || data[0].text) : $select.val();
      if (selected && typeof selected === 'string') {
        var match = selected.match(/\(([^)]+)\)\s*$/);
        if (match) selected = match[1].trim();
      }
      if (!selected) {
        alert("Выберите товар.");
        return;
      }

      var csrf = document.querySelector('meta[name="csrf-token"]');
      var params = new URLSearchParams();
      params.append('sku', selected);

      $btn.prop('disabled', true).text('Добавляем...');

      fetch(addUrl, {
        method: 'POST',
        headers: {
          'Accept': 'text/html',
          'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8',
          'X-CSRF-Token': csrf ? csrf.content : ''
        },
        body: params.toString()
      }).then(function(resp) {
        if (!resp.ok) throw new Error('Request failed');
        window.location.reload();
      }).catch(function() {
        alert("Не удалось добавить товар. Проверьте логи.");
      }).finally(function() {
        $btn.prop('disabled', false).text('Добавить товар');
      });
    });
  }

  document.addEventListener('turbo:load', initSelect2Ajax);
  document.addEventListener('turbolinks:load', initSelect2Ajax);
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', initSelect2Ajax);
  } else {
    initSelect2Ajax();
  }
})();
