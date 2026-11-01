-- snacks.nvim pickers over m2v.search, quickfix list without snacks
local M = {}

M.config = {
    n = 30,
    -- "auto" uses snacks.nvim when installed, "quickfix" always fills the quickfix list
    ui = "auto",
    -- other project roots searched alongside the current one
    roots = {},
    -- live picker waits for this many words before searching
    min_live_words = 3,
    -- hits in tests are hidden unless the query mentions test or spec
    test_patterns = {
        "^tests?/",
        "/tests?/",
        "^spec/",
        "/spec/",
        "test_[^/]*$",
        "_test%.[^/]*$",
        "%.test%.[^/]*$",
        "%.spec%.[^/]*$",
    },
}

local function is_test(path)
    for _, pat in ipairs(M.config.test_patterns) do
        if path:find(pat) then
            return true
        end
    end
    return false
end

local warned = {}

-- never index a directory without a project marker, like ~
local function roots(cwd, opts)
    local r = require("m2v").root(cwd)
    if not r then
        vim.notify("m2v: no project root above " .. cwd, vim.log.levels.WARN)
        return
    end
    local out = { r }
    for _, extra in ipairs(opts and opts.roots or M.config.roots) do
        extra = vim.fs.normalize(vim.fn.expand(extra))
        if vim.fn.isdirectory(extra) == 0 then
            if not warned[extra] then
                warned[extra] = true
                vim.notify("m2v: not a directory: " .. extra, vim.log.levels.WARN)
            end
        elseif not vim.list_contains(out, extra) then
            out[#out + 1] = extra
        end
    end
    return out
end

local function wants_tests(query)
    return query:lower():find("test") or query:lower():find("spec")
end

local function to_items(hits, keep_tests, cwd)
    local items = {}
    for _, hit in ipairs(hits) do
        local rel = vim.fs.relpath(cwd, hit.path) or vim.fn.fnamemodify(hit.path, ":~")
        if keep_tests or not is_test(rel) then
            local line = vim.trim(vim.fn.readfile(hit.path, "", hit.start)[hit.start] or "")
            table.insert(items, {
                file = hit.path,
                pos = { hit.start, 0 },
                end_pos = { hit["end"], 0 },
                comment = hit.similarity and (" %.2f"):format(hit.similarity),
                text = rel .. " " .. line,
                snippet = line,
            })
        end
    end
    return items
end

local function snacks()
    return M.config.ui ~= "quickfix" and pcall(require, "snacks")
end

local function quickfix(title, items)
    vim.fn.setqflist({}, " ", {
        title = title,
        items = vim.tbl_map(function(item)
            return {
                filename = item.file,
                lnum = item.pos[1],
                end_lnum = item.end_pos[1],
                text = (item.comment and vim.trim(item.comment) .. " " or "") .. item.snippet,
            }
        end, items),
    })
    vim.cmd.copen()
end

local function show(title, items)
    if snacks() then
        require("snacks").picker({ title = title, items = items, format = "file" })
    else
        quickfix(title, items)
    end
end

-- path:GLOB and -path:GLOB tokens scope the search, -lex skips ripgrep
local function parse(input, opts)
    opts = opts or {}
    local words, filter = {}, { paths = vim.list_extend({}, opts.paths or {}), lexical = opts.lexical }
    for w in input:gmatch("%S+") do
        local negated, glob = w:match("^(%-?)path:(.+)$")
        if glob then
            table.insert(filter.paths, (negated == "-" and "!" or "") .. glob)
        elseif w == "-lex" then
            filter.lexical = false
        else
            words[#words + 1] = w
        end
    end
    return table.concat(words, " "), filter
end

-- opts.roots replaces config.roots for this search, opts.paths adds globs, opts.lexical = false skips rg
function M.search(input, opts)
    local cwd = vim.fn.getcwd()
    local r = roots(cwd, opts)
    if not r then
        return
    end
    local query, filter = parse(input, opts)
    require("m2v").search(r, query, M.config.n, function(hits)
        show("m2v: " .. input, to_items(hits, wants_tests(query), cwd))
    end, filter)
end

-- falls back to search_prompt without snacks
function M.live(opts)
    if not snacks() then
        return M.search_prompt(opts)
    end
    require("snacks").picker({
        title = "m2v (live)",
        live = true,
        supports_live = true,
        format = "file",
        finder = function(_, ctx)
            local query, filter = parse(ctx.filter.search, opts)
            local r = #vim.split(query, "%s+") >= M.config.min_live_words and roots(ctx.filter.cwd, opts)
            if not r then
                return {}
            end
            return function(cb)
                local items
                vim.schedule(function()
                    local job = require("m2v").search(r, query, M.config.n, function(h)
                        items = to_items(h, wants_tests(query), ctx.filter.cwd)
                        ctx.async:resume()
                    end, filter)
                    ctx.async:on("abort", function()
                        if job then
                            job:kill(15)
                        end
                    end)
                end)
                ctx.async:suspend()
                for _, item in ipairs(items or {}) do
                    cb(item)
                end
            end
        end,
    })
end

-- prompts for the query when none is given
function M.search_prompt(opts)
    vim.ui.input({ prompt = "Semantic search: " }, function(q)
        if q and q ~= "" then
            M.search(q, opts)
        end
    end)
end

-- chunks similar to the visual selection, or to the indexed chunk under the cursor;
-- opts.roots and opts.paths as for search
function M.similar(opts)
    local m2v = require("m2v")
    local buf, cwd = vim.api.nvim_get_current_buf(), vim.fn.getcwd()
    local path = vim.api.nvim_buf_get_name(buf)
    local r = roots(cwd, opts)
    if not r then
        return
    end
    local s, e
    if vim.fn.mode():find("^[vV\22]") then
        s, e = vim.fn.line("v"), vim.fn.line(".")
        if s > e then
            s, e = e, s
        end
        vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
    else
        local row, own = vim.fn.line("."), m2v.root(path)
        if own then
            s, e = m2v.chunk_at(own, path, row)
        end
        if not s then
            local half = math.floor(m2v.config.chunk.target_lines / 2)
            s, e = math.max(1, row - half), math.min(vim.api.nvim_buf_line_count(buf), row + half)
        end
    end
    local text = table.concat(vim.api.nvim_buf_get_lines(buf, s - 1, e, false), "\n")
    local name = vim.fs.relpath(cwd, path) or vim.fn.fnamemodify(path, ":~")
    m2v.similar(r, text, M.config.n, function(hits)
        if #hits == 0 then
            return vim.notify("m2v: nothing similar found, the index may still be building", vim.log.levels.INFO)
        end
        show(("m2v: similar to %s:%d-%d"):format(name, s, e), to_items(hits, true, cwd))
    end, { skip = { path = path, start = s, ["end"] = e }, paths = opts and opts.paths })
end

return M
