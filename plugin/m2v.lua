if vim.g.loaded_m2v then
    return
end
vim.g.loaded_m2v = 1

local function picker()
    return require("m2v.picker")
end

local subcommands = {
    search = function(cmd)
        if cmd.args == "" then
            picker().search_prompt()
        else
            picker().search(cmd.args)
        end
    end,
    live = function()
        picker().live()
    end,
    similar = function(cmd)
        picker().similar(cmd.range > 0 and { range = { cmd.line1, cmd.line2 } } or nil)
    end,
    build = function()
        local m2v = require("m2v")
        local root = m2v.root(vim.api.nvim_get_current_buf())
        if not root then
            return vim.notify("m2v: no project root for this buffer", vim.log.levels.WARN)
        end
        m2v.build(root)
    end,
}

vim.api.nvim_create_user_command("M2v", function(cmd)
    local name, rest = cmd.args:match("^(%S+)%s*(.*)$")
    local run = subcommands[name]
    if not run then
        return vim.notify("m2v: unknown subcommand " .. (name or ""), vim.log.levels.ERROR)
    end
    run({ args = rest, range = cmd.range, line1 = cmd.line1, line2 = cmd.line2 })
end, {
    nargs = "+",
    range = true,
    desc = "Semantic code search",
    complete = function(lead, line)
        if line:match("^%S*M2v!?%s+%S*$") then
            local names = vim.tbl_filter(function(name)
                return vim.startswith(name, lead)
            end, vim.tbl_keys(subcommands))
            table.sort(names)
            return names
        end
        return {}
    end,
})

vim.keymap.set("n", "<Plug>(m2v-search)", function()
    picker().search_prompt()
end, { desc = "Semantic search" })
vim.keymap.set("n", "<Plug>(m2v-live)", function()
    picker().live()
end, { desc = "Semantic search (live)" })
vim.keymap.set({ "n", "x" }, "<Plug>(m2v-similar)", function()
    picker().similar()
end, { desc = "Similar code" })
