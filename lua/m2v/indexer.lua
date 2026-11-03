-- nvim -l lua/m2v/indexer.lua <root> <index dir> <model dir> <opts json>
-- nvim -l lua/m2v/indexer.lua --worker <root> <model dir> <opts json> <shard prefix>
-- parent of m2v/: lua/ in a checkout, share/lua/5.1 in a luarocks tree
local lua_dir = vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)))
package.path = ("%s/?.lua;%s/?/init.lua;"):format(lua_dir, lua_dir) .. package.path
local index = require("m2v.index")

local function progress(done, total)
    io.stdout:write(("%d %d\n"):format(done, total))
    io.stdout:flush()
end

if _G.arg[1] == "--worker" then
    local root, model_dir, opts, prefix = _G.arg[2], _G.arg[3], vim.json.decode(_G.arg[4]), _G.arg[5]
    local model = require("m2v.model").load(model_dir, opts.max_tokens)
    index.embed_shard(root, model, opts, prefix, progress)
else
    local root, dir, model_dir, opts = _G.arg[1], _G.arg[2], _G.arg[3], vim.json.decode(_G.arg[4])
    index.build(root, dir, model_dir, opts, progress)
end
