local root = vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
local grammar = root .. "/tree-sitter-cshl"
local source = grammar .. "/src/parser.c"
local cache = vim.fn.stdpath("cache") .. "/cshl/" .. vim.fn.sha256(root):sub(1, 12)
local parser = cache .. "/cshl.so"

-- Build the generated parser when it changes; no global parser install needed.
if vim.fn.getftime(parser) < vim.fn.getftime(source) then
  vim.fn.mkdir(cache, "p")
  local result = vim.system({
    "cc", "-shared", "-fPIC", "-O2", "-I", grammar .. "/src",
    source, "-o", parser,
  }, { text = true }):wait()
  if result.code ~= 0 then
    vim.notify("CSHL parser build failed:\n" .. result.stderr, vim.log.levels.ERROR)
    return
  end
end

vim.treesitter.language.add("cshl", { path = parser })
vim.treesitter.query.set("cshl", "highlights",
  table.concat(vim.fn.readfile(grammar .. "/queries/highlights.scm"), "\n"))
vim.filetype.add({ extension = { cshl = "cshl" } })

local function start(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  if vim.bo[buf].filetype == "cshl" and name:sub(1, #root + 1) == root .. "/" then
    vim.treesitter.start(buf, "cshl")
  end
end

vim.api.nvim_create_autocmd("FileType", {
  group = vim.api.nvim_create_augroup("CshlProjectHighlight", { clear = true }),
  pattern = "cshl",
  callback = function(args) start(args.buf) end,
})
for _, buf in ipairs(vim.api.nvim_list_bufs()) do
  if vim.api.nvim_buf_is_loaded(buf) then start(buf) end
end
