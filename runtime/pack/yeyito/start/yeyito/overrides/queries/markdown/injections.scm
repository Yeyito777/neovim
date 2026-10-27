; Work around nvim-treesitter master/v0.10 markdown injection queries on Neovim 0.12.
; The old query uses #set-lang-from-info-string!, whose handler expects a single
; TSNode; Neovim 0.12 passes a list of nodes, causing "attempt to call method
; 'range' (a nil value)" when opening fenced-code Markdown files.
;
; This local query shadows the plugin's old markdown injections and uses the
; Neovim 0.12-compatible @injection.language capture instead.

(fenced_code_block
  (info_string
    (language) @injection.language)
  (code_fence_content) @injection.content)

((html_block) @injection.content
  (#set! injection.language "html")
  (#set! injection.combined)
  (#set! injection.include-children))

((minus_metadata) @injection.content
  (#set! injection.language "yaml")
  (#offset! @injection.content 1 0 -1 0)
  (#set! injection.include-children))

((plus_metadata) @injection.content
  (#set! injection.language "toml")
  (#offset! @injection.content 1 0 -1 0)
  (#set! injection.include-children))

([
  (inline)
  (pipe_table_cell)
] @injection.content
  (#set! injection.language "markdown_inline"))

; ```zsh fences highlight as bash.
((fenced_code_block
  (info_string) @language
  (code_fence_content) @injection.content)
  (#eq? @language "zsh")
  (#set! injection.language "bash"))
