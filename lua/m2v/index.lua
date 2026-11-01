-- On-disk index per root: meta.json (files and chunk rows) + vectors.bin (float32 rows)
local ffi = require("ffi")
local chunk = require("m2v.chunk")

local M = {}

local VERSION = 2

local function read(path)
    local f = io.open(path, "rb")
    if not f then
        return
    end
    local data = f:read("*a")
    f:close()
    return data
end

local function list_files(root)
    for _, cmd in ipairs({ { "rg", "--files", "--no-messages" }, { "git", "ls-files" } }) do
        if vim.fn.executable(cmd[1]) == 1 then
            local res = vim.system(cmd, { cwd = root, text = true }):wait()
            if res.code == 0 then
                local files = vim.split(vim.trim(res.stdout), "\n", { trimempty = true })
                table.sort(files)
                return files
            end
        end
    end
    return {}
end

local function stamp(stat)
    return ("%d.%09d:%d"):format(stat.mtime.sec, stat.mtime.nsec, stat.size)
end

-- meta.chunks is flat: file index, first row, last row per chunk
function M.load(dir)
    local meta_raw, vectors = read(dir .. "/meta.json"), read(dir .. "/vectors.bin")
    if not meta_raw or not vectors then
        return
    end
    local ok, meta = pcall(vim.json.decode, meta_raw)
    if not ok or meta.version ~= VERSION or #vectors ~= #meta.chunks / 3 * meta.dim * 4 then
        return
    end
    local by_path = {}
    for i, f in ipairs(meta.files) do
        by_path[f.path] = i
    end
    return {
        meta = meta,
        dim = meta.dim,
        n = #meta.chunks / 3,
        data = vectors,
        vectors = ffi.cast("const float*", vectors),
        by_path = by_path,
    }
end

-- 0-based chunk indices of a file, in row order
function M.file_chunks(idx, rel)
    local i = idx.by_path[rel]
    local f = i and idx.meta.files[i]
    return f and f.first or 0, f and f.count or 0
end

function M.chunk(idx, c)
    local ch = idx.meta.chunks
    return idx.meta.files[ch[c * 3 + 1]].path, ch[c * 3 + 2], ch[c * 3 + 3]
end

local function binary(data)
    return data:sub(1, 8000):find("\0", 1, true) ~= nil
end

local script = vim.fs.joinpath(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)), "..", "..", "indexer.lua")

-- embeds every chunk of one file: vectors appended to out, start/end rows appended flat to rows
local function embed_file(root, rel, model, opts, vec, out, rows)
    local abs = root .. "/" .. rel
    local data = read(abs)
    if not data or binary(data) then
        return 0
    end
    local lines = vim.split(data, "\n", { plain = true })
    -- content sniffing is slow; only shebang scripts need it
    local ft = vim.filetype.match({ filename = abs })
        or lines[1]:find("^#!") and vim.filetype.match({ filename = abs, contents = lines })
        or nil
    -- help files are only told apart from text by their modeline
    local modeline = ft == "text" and table.concat(lines, "\n", math.max(1, #lines - 4)) or ""
    if modeline:find("%f[%w]ft=help%f[%W]") or modeline:find("filetype=help%f[%W]") then
        ft = "help"
    end
    local lang = ft and vim.treesitter.language.get_lang(ft)
    local count = 0
    for _, r in ipairs(chunk.split(lines, lang, opts.chunk)) do
        local text = rel .. "\n" .. (r[3] and r[3] .. "\n" or "") .. table.concat(lines, "\n", r[1] + 1, r[2] + 1)
        if model:embed(text, vec) then
            out:write(ffi.string(vec, model.dim * 4))
            rows[#rows + 1], rows[#rows + 2] = r[1], r[2]
            count = count + 1
        end
    end
    return count
end

-- worker half of a parallel build: embeds the files listed in <prefix>.files into <prefix>.bin,
-- with the rows of every file (in list order) in <prefix>.json
function M.embed_shard(root, model, opts, prefix, progress)
    local files = vim.json.decode(read(prefix .. ".files"))
    local out = assert(io.open(prefix .. ".bin", "wb"))
    local vec, rows = ffi.new("float[?]", model.dim), {}
    for i, rel in ipairs(files) do
        rows[i] = {}
        embed_file(root, rel, model, opts, vec, out, rows[i])
        if progress and (i % 50 == 0 or i == #files) then
            progress(i, #files)
        end
    end
    out:close()
    local f = assert(io.open(prefix .. ".json", "wb"))
    f:write(vim.json.encode({ dim = model.dim, rows = rows }))
    f:close()
end

-- largest files first onto the least loaded shard; each shard keeps the global (sorted) file order
local function shard(pending, n)
    table.sort(pending, function(a, b)
        return a.size > b.size
    end)
    local shards, load = {}, {}
    for i = 1, n do
        shards[i], load[i] = {}, 0
    end
    for _, e in ipairs(pending) do
        local least = 1
        for i = 2, n do
            if load[i] < load[least] then
                least = i
            end
        end
        table.insert(shards[least], e.path)
        load[least] = load[least] + e.size
    end
    for _, files in ipairs(shards) do
        table.sort(files)
    end
    return shards
end

-- runs one indexer worker per shard; returns per shard { files, rows, bin } with a cursor for merging.
-- progress counts the reused files as already done.
local function run_workers(root, dir, model_dir, opts, shards, reused, total, progress)
    local jobs, done = {}, {}
    for i, files in ipairs(shards) do
        local prefix = dir .. "/shard" .. i
        local f = assert(io.open(prefix .. ".files", "wb"))
        f:write(vim.json.encode(files))
        f:close()
        done[i] = 0
        jobs[i] = vim.system({ vim.v.progpath, "-l", script, "--worker", root, model_dir, vim.json.encode(opts), prefix }, {
            stdout = function(_, data)
                local n = data and data:match("(%d+) %d+\n[^\n]*$")
                if n and progress then
                    done[i] = tonumber(n)
                    local sum = reused
                    for _, d in ipairs(done) do
                        sum = sum + d
                    end
                    progress(sum, total)
                end
            end,
        })
    end
    local results = {}
    for i, job in ipairs(jobs) do
        local res = job:wait()
        assert(res.code == 0, "m2v: indexer worker failed\n" .. (res.stderr or ""))
        local prefix = dir .. "/shard" .. i
        local res_json = vim.json.decode(read(prefix .. ".json"))
        results[i] = { files = shards[i], dim = res_json.dim, rows = res_json.rows, bin = read(prefix .. ".bin"), cursor = 1, offset = 0 }
        for _, ext in ipairs({ ".files", ".json", ".bin" }) do
            vim.fn.delete(prefix .. ext)
        end
    end
    return results
end

-- opts.workers > 1 shards the files that need embedding across that many `nvim -l` workers;
-- below that, or when few files changed, this process loads the model and embeds them itself
function M.build(root, dir, model_dir, opts, progress)
    vim.fn.mkdir(dir, "p")
    local old = M.load(dir)
    if old and old.meta.model ~= opts.model then
        old = nil
    end
    local entries, pending = {}, {}
    for _, rel in ipairs(list_files(root)) do
        local stat = vim.uv.fs_stat(root .. "/" .. rel)
        if stat and stat.type == "file" and stat.size <= opts.max_file_bytes then
            local e = { path = rel, stamp = stamp(stat), size = stat.size }
            local prev = old and old.by_path[rel] and old.meta.files[old.by_path[rel]]
            if prev and prev.stamp == e.stamp then
                e.prev = prev
            else
                pending[#pending + 1] = e
            end
            entries[#entries + 1] = e
        end
    end
    local n_workers = math.min(opts.workers or 1, math.ceil(#pending / 32))
    local shard_of, results = {}, nil
    if n_workers > 1 then
        local shards = shard(pending, n_workers)
        for i, files in ipairs(shards) do
            for _, rel in ipairs(files) do
                shard_of[rel] = i
            end
        end
        results = run_workers(root, dir, model_dir, opts, shards, #entries - #pending, #entries, progress)
    end
    local dim, model = results and results[1].dim or old and old.dim, nil
    if not dim or (#pending > 0 and not results) then
        model = require("m2v.model").load(model_dir, opts.max_tokens)
        dim = model.dim
    end
    local meta = { version = VERSION, model = opts.model, dim = dim, files = {}, chunks = {} }
    local tmp = dir .. "/vectors.bin.tmp"
    local out = assert(io.open(tmp, "wb"))
    local vec = model and ffi.new("float[?]", dim)
    local n = 0
    for i, e in ipairs(entries) do
        local entry = { path = e.path, stamp = e.stamp, first = n, count = 0 }
        if e.prev then
            out:write(ffi.string(old.vectors + e.prev.first * dim, e.prev.count * dim * 4))
            for c = e.prev.first, e.prev.first + e.prev.count - 1 do
                local _, s, en = M.chunk(old, c)
                vim.list_extend(meta.chunks, { #meta.files + 1, s, en })
            end
            entry.count = e.prev.count
        elseif model then
            local rows = {}
            entry.count = embed_file(root, e.path, model, opts, vec, out, rows)
            for r = 1, #rows, 2 do
                vim.list_extend(meta.chunks, { #meta.files + 1, rows[r], rows[r + 1] })
            end
        else
            local res = results[shard_of[e.path]]
            assert(res.files[res.cursor] == e.path)
            local rows = res.rows[res.cursor]
            entry.count = #rows / 2
            out:write(res.bin:sub(res.offset + 1, res.offset + entry.count * dim * 4))
            res.offset, res.cursor = res.offset + entry.count * dim * 4, res.cursor + 1
            for r = 1, #rows, 2 do
                vim.list_extend(meta.chunks, { #meta.files + 1, rows[r], rows[r + 1] })
            end
        end
        if entry.count > 0 then
            meta.files[#meta.files + 1] = entry
            n = n + entry.count
        end
        if model and progress and (i % 200 == 0 or i == #entries) then
            progress(i, #entries)
        end
    end
    out:close()
    local f = assert(io.open(dir .. "/meta.json.tmp", "wb"))
    f:write(vim.json.encode(meta))
    f:close()
    assert(vim.uv.fs_rename(tmp, dir .. "/vectors.bin"))
    assert(vim.uv.fs_rename(dir .. "/meta.json.tmp", dir .. "/meta.json"))
end

return M
