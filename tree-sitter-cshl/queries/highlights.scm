; Neovim: patterns later in the file override earlier ones for the same node,
; so general captures come first and specific ones after.

(number) @number
(string) @string
(escape_sequence) @string.escape
(comment) @comment

(id) @variable

; The head of f x, f(x), f[x]
(call function: (id) @function.call)

; Member access and methods: a.b, a:m
(call function: "." argument: (id) @variable.member .)
(call function: ":" argument: (id) @function.method .)

; @ names are ordinary identifiers; only their appearance differs.
((id) @function.builtin
  (#lua-match? @function.builtin "^@"))

; Quote ' unquote ` escape \ splice .., and ? # ! $ on their own
((id) @punctuation.special
  (#any-of? @punctuation.special "'" "`" "\\" ".." "?" "#" "!" "$"))

[
  "<~" "<-" "|>" "=" "->" "and" "or" "xor"
  "==" "!=" "<" ">" "<=" ">=" "<=>"
  "band" "bor" "bxor" "shl" "shr"
  "+" "-" "*" "/" "%" "as"
] @operator

["(" ")" "[" "]" "{" "}"] @punctuation.bracket
["," ";" "." ":"] @punctuation.delimiter
