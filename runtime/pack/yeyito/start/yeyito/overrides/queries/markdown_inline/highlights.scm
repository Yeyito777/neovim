; Local override: markdown_links.lua owns link concealment so individual links
; can be revealed. Keep other Markdown source punctuation visible as before.
; Based on the installed nvim-treesitter Markdown inline highlights.
; From MDeiml/tree-sitter-markdown
(code_span) @markup.raw @nospell

(emphasis) @markup.italic

(strong_emphasis) @markup.strong

(strikethrough) @markup.strikethrough

(shortcut_link
  (link_text) @nospell)

[
  (backslash_escape)
  (hard_line_break)
] @string.escape

; Preserve code and text style source markers
([
  (code_span_delimiter)
  (emphasis_delimiter)
] @conceal
  (#set! priority 100))

; Inline link punctuation (concealment is managed by markdown_links.lua)
(inline_link
  [
    "["
    "]"
    "("
    (link_destination)
    ")"
  ] @markup.link
  (#set! priority 100))

[
  (link_label)
  (link_text)
  (link_title)
  (image_description)
] @markup.link.label

((inline_link
  (link_destination) @_url) @_label
  (#set! @_label url @_url))

((image
  (link_destination) @_url) @_label
  (#set! @_label url @_url))

; Image link punctuation
(image
  [
    "!"
    "["
    "]"
    "("
    (link_destination)
    ")"
  ] @markup.link
  (#set! priority 100))

; Full reference link punctuation
(full_reference_link
  [
    "["
    "]"
    (link_label)
  ] @markup.link
  (#set! priority 100))

; Collapsed reference link punctuation
(collapsed_reference_link
  [
    "["
    "]"
  ] @markup.link
  (#set! priority 100))

; Shortcut link punctuation
(shortcut_link
  [
    "["
    "]"
  ] @markup.link
  (#set! priority 100))

[
  (link_destination)
  (uri_autolink)
  (email_autolink)
] @markup.link.url @nospell

((uri_autolink) @_url
  (#offset! @_url 0 1 0 -1)
  (#set! @_url url @_url))

(entity_reference) @nospell

; Highlight common HTML entities, keeping their source spelling visible.
((entity_reference) @character.special
  (#eq? @character.special "&nbsp;")
  (#set! priority 100))

((entity_reference) @character.special
  (#eq? @character.special "&lt;")
  (#set! priority 100))

((entity_reference) @character.special
  (#eq? @character.special "&gt;")
  (#set! priority 100))

((entity_reference) @character.special
  (#eq? @character.special "&amp;")
  (#set! priority 100))

((entity_reference) @character.special
  (#eq? @character.special "&quot;")
  (#set! priority 100))

((entity_reference) @character.special
  (#any-of? @character.special "&ensp;" "&emsp;")
  (#set! priority 100))
