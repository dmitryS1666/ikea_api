# Расширение тулбара TinyMCE в Trestle: размер и гарнитура шрифта, блоки (заголовки/абзац).
# Должно выполняться после trestle-tinymce (см. after_initialize).
Rails.application.config.after_initialize do
  next unless defined?(Trestle::TinyMCE)

  Trestle.configure do |config|
    config.tinymce.default.configure do |c|
      c.font_size_formats = "8pt 9pt 10pt 11pt 12pt 14pt 16pt 18pt 20pt 22pt 24pt 28pt 32pt 36pt"
      c.font_family_formats = [
        "Arial=arial,helvetica,sans-serif",
        "Georgia=georgia,palatino,serif",
        "Times New Roman=times new roman,times,serif",
        "Verdana=verdana,geneva,sans-serif",
        "Trebuchet MS=trebuchet ms,geneva,sans-serif",
        "Courier New=courier new,courier,monospace"
      ].join("; ")

      if Trestle::TinyMCE.tinymce_major_version >= 6
        c.toolbar = [
          "blocks fontsize fontfamily",
          "styles",
          "bold italic underline strikethrough",
          "subscript superscript hr",
          "alignleft aligncenter alignright alignjustify",
          "bullist numlist",
          "indent outdent",
          "undo redo",
          "link unlink",
          "image charmap table",
          "code"
        ].join(" | ")
      else
        c.toolbar = [
          "formatselect fontsizeselect fontselect",
          "styleselect",
          "bold italic underline strikethrough",
          "subscript superscript hr",
          "alignleft aligncenter alignright alignjustify",
          "bullist numlist",
          "indent outdent",
          "undo redo",
          "link unlink",
          "image charmap table",
          "code"
        ].join(" | ")
      end
    end
  end
end
