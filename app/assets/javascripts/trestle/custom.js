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
        multiple: true,
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
        minimumInputLength: 3,
        placeholder: $el.attr('placeholder') || 'Начните ввод для поиска...',
        allowClear: true
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
