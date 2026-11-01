-- snacks.nvim pickers over m2v.search
local M = {}

M.config = {
    n = 30,
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

-- never index a directory without a project marker, like ~
local function root(cwd)
    local r = require("m2v").root(cwd)
    if not r then
        vim.notify("m2v: no project root above " .. cwd, vim.log.levels.WARN)
    end
    return r
end

local function to_items(hits, query, cwd)
    local keep_tests = query:lower():find("test") or query:lower():find("spec")
    local items = {}
    for _, hit in ipairs(hits) do
        local rel = vim.fs.relpath(cwd, hit.path) or hit.path
        if keep_tests or not is_test(rel) then
            local line = vim.fn.readfile(hit.path, "", hit.start)[hit.start] or ""
            table.insert(items, {
                file = hit.path,
                pos = { hit.start, 0 },
                end_pos = { hit["end"], 0 },
                comment = hit.similarity and (" %.2f"):format(hit.similarity),
                text = rel .. " " .. vim.trim(line),
            })
        end
    end
    return items
end

function M.search(query)
    local cwd = vim.fn.getcwd()
    local r = root(cwd)
    if not r then
        return
    end
    require("m2v").search(r, query, M.config.n, function(hits)
        require("snacks").picker({ title = "m2v: " .. query, items = to_items(hits, query, cwd), format = "file" })
    end)
end

function M.live()
    require("snacks").picker({
        title = "m2v (live)",
        live = true,
        supports_live = true,
        format = "file",
        finder = function(_, ctx)
            local query = vim.trim(ctx.filter.search)
            local r = #vim.split(query, "%s+") >= M.config.min_live_words and root(ctx.filter.cwd)
            if not r then
                return {}
            end
            return function(cb)
                local items
                vim.schedule(function()
                    local job = require("m2v").search(r, query, M.config.n, function(h)
                        items = to_items(h, query, ctx.filter.cwd)
                        ctx.async:resume()
                    end)
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
function M.search_prompt()
    vim.ui.input({ prompt = "Semantic search: " }, function(q)
        if q and q ~= "" then
            M.search(q)
        end
    end)
end

return M
