-- model2vec static embeddings: mean of token rows, L2-normalized.
-- Vocabulary-quantized models add mapping (token id -> row) and per-token weights.
local ffi = require("ffi")
local tokenizer = require("m2v.tokenizer")

ffi.cdef([[
    void *mmap(void *addr, size_t length, int prot, int flags, int fd, int64_t offset);
    int munmap(void *addr, size_t length);
]])

local M = {}
M.__index = M

local half_table

-- LuaJIT has no half type; decode all 65536 bit patterns once
local function halves()
    if half_table then
        return half_table
    end
    half_table = ffi.new("float[65536]")
    for h = 0, 65535 do
        local sign = bit.band(h, 0x8000) ~= 0 and -1 or 1
        local exp = bit.band(bit.rshift(h, 10), 0x1f)
        local mant = bit.band(h, 0x3ff)
        local v
        if exp == 0 then
            v = mant * 2 ^ -24
        elseif exp == 31 then
            v = mant == 0 and math.huge or 0 / 0
        else
            v = (1 + mant / 1024) * 2 ^ (exp - 15)
        end
        half_table[h] = sign * v
    end
    return half_table
end

-- read-only private mapping: the page cache is shared by the editor and the indexer workers,
-- and nothing is copied into the Lua heap; falls back to reading the file where mmap is missing
local function map_file(path)
    local fd = assert(vim.uv.fs_open(path, "r", 420))
    local size = vim.uv.fs_fstat(fd).size
    local ok, ptr = pcall(function()
        return ffi.C.mmap(nil, size, 1, 2, fd, 0)
    end)
    vim.uv.fs_close(fd)
    if ok and ptr ~= nil and ffi.cast("intptr_t", ptr) ~= -1 then
        return ffi.gc(ffi.cast("const uint8_t*", ptr), function(p)
            ffi.C.munmap(ffi.cast("void*", p), size)
        end), size
    end
    local f = assert(io.open(path, "rb"))
    local data = f:read("*a")
    f:close()
    return ffi.cast("const uint8_t*", data), #data, data
end

-- dir holds tokenizer.json and model.safetensors
function M.load(dir, max_tokens)
    local data, _, keep = map_file(dir .. "/model.safetensors")
    local header_len = tonumber(ffi.cast("const uint64_t*", data)[0])
    local header = vim.json.decode(ffi.string(data + 8, header_len))
    local t = assert(header.embeddings, "m2v: safetensors has no embeddings tensor")
    local known = { embeddings = true, mapping = true, weights = true, __metadata__ = true }
    for name in pairs(header) do
        assert(known[name], "m2v: unsupported tensor " .. name)
    end
    assert(t.dtype == "F16" or t.dtype == "F32", "m2v: unsupported dtype " .. t.dtype)
    local function tensor(name, dtype, ctype)
        local h = header[name]
        if not h then
            return nil
        end
        assert(h.dtype == dtype, "m2v: unsupported dtype " .. h.dtype .. " for " .. name)
        return ffi.cast(ctype, data + 8 + header_len + h.data_offsets[1])
    end
    local base = data + 8 + header_len + t.data_offsets[1]
    return setmetatable({
        -- keeps the mapping (or the fallback string) alive under the casted pointers
        data = data,
        keep = keep,
        dim = t.shape[2],
        f16 = t.dtype == "F16" and ffi.cast("const uint16_t*", base) or nil,
        f32 = t.dtype == "F32" and ffi.cast("const float*", base) or nil,
        half = t.dtype == "F16" and halves() or nil,
        mapping = tensor("mapping", "I64", "const int64_t*"),
        weights = tensor("weights", "F64", "const double*"),
        tok = tokenizer.load(dir .. "/tokenizer.json"),
        max_tokens = max_tokens or 512,
    }, M)
end

-- writes the embedding of text into out (float[dim]); false when no token is known
function M:embed(text, out)
    local dim, ids = self.dim, self.tok:encode(text, self.max_tokens)
    ffi.fill(out, dim * 4)
    if #ids == 0 then
        return false
    end
    local f16, f32, half, mapping, weights = self.f16, self.f32, self.half, self.mapping, self.weights
    for _, id in ipairs(ids) do
        local row = (mapping and tonumber(mapping[id]) or id) * dim
        local w = weights and weights[id] or 1
        if f16 then
            for j = 0, dim - 1 do
                out[j] = out[j] + w * half[f16[row + j]]
            end
        else
            for j = 0, dim - 1 do
                out[j] = out[j] + w * f32[row + j]
            end
        end
    end
    local norm = 0
    for j = 0, dim - 1 do
        norm = norm + out[j] * out[j]
    end
    norm = math.sqrt(norm)
    if norm == 0 then
        return false
    end
    for j = 0, dim - 1 do
        out[j] = out[j] / norm
    end
    return true
end

return M
