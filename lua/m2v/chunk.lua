-- Splits a file into retrieval units: top-level treesitter nodes, descending into
-- nodes that are too big, then merging small neighbours. Markdown and vim help are
-- split at their headings instead, each unit carrying its heading path.
-- Rows are 0-based inclusive.
local M = {}

local function windows(s, e, size, out, heading)
    for a = s, e, size do
        out[#out + 1] = { a, math.min(a + size - 1, e), heading }
    end
end

-- { row, level, title } for ATX headings outside fenced code
local function markdown_headings(lines)
    local out, fence = {}, nil
    for i, line in ipairs(lines) do
        local f = line:match("^%s*(```+)") or line:match("^%s*(~~~+)")
        if f and (not fence or f:sub(1, 1) == fence:sub(1, 1) and #f >= #fence) then
            fence = not fence and f or nil
        elseif not fence then
            local hashes, title = line:match("^(#+)%s+(.-)%s*#*%s*$")
            if hashes and #hashes <= 6 then
                out[#out + 1] = { i - 1, #hashes, (title:gsub("%[(.-)%]%b()", "%1")) }
            end
        end
    end
    return out
end

-- shorter runs of - or = are markdown-ish underlines or table rules inside a section
local HELP_RULE_MIN = 20

-- sections open after ===== (level 1) or ----- (level 2) rules, titled by their first line
local function help_headings(lines)
    local out = {}
    for i, line in ipairs(lines) do
        local rule = line:match("^(=+)%s*$") or line:match("^(%-+)%s*$")
        if rule and #rule >= HELP_RULE_MIN then
            local title = vim.trim(lines[i + 1] or "")
            if title ~= "" then
                out[#out + 1] = { i - 1, rule:sub(1, 1) == "=" and 1 or 2, (title:gsub("%s%s+", " ")) }
            end
        end
    end
    return out
end

local function doc_units(lines, headings, max_lines, out)
    local path = {}
    if #headings == 0 or headings[1][1] > 0 then
        local e = (headings[1] and headings[1][1] or #lines) - 1
        if e >= 0 then
            windows(0, e, max_lines, out)
        end
    end
    for i, h in ipairs(headings) do
        local row, level, title = h[1], h[2], h[3]
        for l = level, #path do
            path[l] = nil
        end
        path[level] = title
        local parts = {}
        for l = 1, level do
            parts[#parts + 1] = path[l]
        end
        local e = (headings[i + 1] and headings[i + 1][1] or #lines) - 1
        windows(row, e, max_lines, out, table.concat(parts, " > "))
    end
end

local function units(node, max_lines, out)
    for child in node:iter_children() do
        if child:named() then
            local s, _, e, ecol = child:range()
            if ecol == 0 and e > s then
                e = e - 1
            end
            if e - s + 1 <= max_lines then
                out[#out + 1] = { s, e }
            elseif child:named_child_count() > 0 then
                units(child, max_lines, out)
            else
                windows(s, e, max_lines, out)
            end
        end
    end
end

local function root(lines, lang)
    if not lang then
        return
    end
    local ok, parser = pcall(vim.treesitter.get_string_parser, table.concat(lines, "\n"), lang)
    if not ok or not parser then
        return
    end
    local ok_parse, trees = pcall(parser.parse, parser)
    return ok_parse and trees[1] and trees[1]:root() or nil
end

-- joins neighbours while the result stays within target lines; a merge keeps the first heading
local function merge(found, target_lines)
    local out, cur = {}, nil
    for _, u in ipairs(found) do
        if cur and u[1] <= cur[2] + 2 and math.max(u[2], cur[2]) - cur[1] + 1 <= target_lines then
            cur[2] = math.max(cur[2], u[2])
        else
            cur = { u[1], u[2], u[3] }
            out[#out + 1] = cur
        end
    end
    return out
end

-- units are { first row, last row, heading path or nil }
function M.split(lines, lang, opts)
    local found = {}
    if lang == "markdown" or lang == "vimdoc" then
        local headings = lang == "markdown" and markdown_headings(lines) or help_headings(lines)
        if #headings > 0 then
            doc_units(lines, headings, opts.max_lines, found)
            return merge(found, opts.target_lines)
        end
    end
    local parsed = root(lines, lang)
    if parsed then
        units(parsed, opts.max_lines, found)
        table.sort(found, function(a, b)
            return a[1] < b[1]
        end)
    end
    if #found == 0 then
        windows(0, #lines - 1, opts.max_lines, found)
        return found
    end
    return merge(found, opts.target_lines)
end

return M
