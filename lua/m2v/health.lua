local M = {}

function M.check()
    local health = vim.health
    local m2v = require("m2v")
    health.start("m2v")

    for _, bin in ipairs({ "rg", "curl" }) do
        if vim.fn.executable(bin) == 1 then
            health.ok(bin .. " found")
        else
            health.warn(bin .. " not found", bin == "rg" and "lexical ranking and file listing fall back" or nil)
        end
    end

    local ok = pcall(function()
        local ffi = require("ffi")
        ffi.cdef("const char *utf8proc_version(void);")
        health.ok("utf8proc " .. ffi.string(ffi.C.utf8proc_version()))
    end)
    if not ok then
        health.error("utf8proc not reachable through FFI", "non-ASCII text cannot be normalized")
    end

    local dir, download = m2v.model_dir()
    if not dir then
        health.info(("%s not downloaded yet, will go to %s"):format(m2v.config.model, download))
        return
    end
    local loaded, err = pcall(require("m2v.model").load, dir, m2v.config.max_tokens)
    if loaded then
        health.ok(("%s (%s)"):format(m2v.config.model, dir))
    else
        health.error(("%s cannot be used: %s"):format(m2v.config.model, err))
    end
end

return M
